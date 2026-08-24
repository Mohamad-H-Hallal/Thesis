import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/app_env.dart';
import 'realtime_models.dart';
import 'realtime_scope_registry.dart';

typedef ValueChanged<T> = void Function(T value);
typedef RealtimeAccessTokenProvider =
    Future<String> Function(bool forceRefresh);

Duration realtimeReconnectDelay({
  required int attempt,
  required double randomValue,
}) {
  final cappedAttempt = attempt.clamp(0, 5);
  final baseMilliseconds = min(30000, 1000 * (1 << cappedAttempt));
  final jitter = 0.75 + (randomValue.clamp(0.0, 1.0) * 0.5);
  return Duration(milliseconds: max(500, (baseMilliseconds * jitter).round()));
}

class WorkflowRealtimeEvent {
  const WorkflowRealtimeEvent({
    required this.id,
    required this.method,
    required this.path,
    this.actorUserId,
    this.targetUserId,
    this.targetAction,
  });

  final String id;
  final String method;
  final String path;
  final String? actorUserId;
  final String? targetUserId;
  final String? targetAction;
}

class WorkflowRealtimeService {
  WorkflowRealtimeService({Random? random}) : _random = random ?? Random();

  final Random _random;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _socketSubscription;
  StreamSubscription<void>? _scopeSubscription;
  Timer? _reconnectTimer;
  Timer? _scopeDebounce;
  bool _stopped = true;
  bool _forceTokenRefresh = false;
  int _connectionGeneration = 0;
  int _reconnectAttempt = 0;
  String? _accessToken;
  RealtimeAccessTokenProvider? _accessTokenProvider;
  RealtimeScopeRegistry? _scopeRegistry;
  ValueChanged<RealtimeDomainEvent>? _onDomainChanged;
  ValueChanged<List<RealtimeKnownRevision>>? _onStaleScopes;
  ValueChanged<WorkflowRealtimeEvent>? _onLegacyWorkflowChanged;
  ValueChanged<RealtimeConnectionState>? _onStateChanged;
  RealtimeConnectionState _state = RealtimeConnectionState.disconnected;

  RealtimeConnectionState get state => _state;

  void connect({
    required String accessToken,
    required RealtimeAccessTokenProvider accessTokenProvider,
    required RealtimeScopeRegistry scopeRegistry,
    required ValueChanged<RealtimeDomainEvent> onDomainChanged,
    required ValueChanged<List<RealtimeKnownRevision>> onStaleScopes,
    ValueChanged<WorkflowRealtimeEvent>? onLegacyWorkflowChanged,
    ValueChanged<RealtimeConnectionState>? onStateChanged,
  }) {
    final normalizedToken = accessToken.trim();
    if (normalizedToken.isEmpty) {
      disconnect();
      return;
    }

    _accessToken = normalizedToken;
    _accessTokenProvider = accessTokenProvider;
    _scopeRegistry = scopeRegistry;
    _onDomainChanged = onDomainChanged;
    _onStaleScopes = onStaleScopes;
    _onLegacyWorkflowChanged = onLegacyWorkflowChanged;
    _onStateChanged = onStateChanged;
    _stopped = false;
    _scopeSubscription ??= scopeRegistry.changes.listen((_) {
      _scopeDebounce?.cancel();
      _scopeDebounce = Timer(
        const Duration(milliseconds: 150),
        _sendSubscriptionUpdate,
      );
    });
    if (_channel == null) {
      unawaited(_openSocket());
    }
  }

  void disconnect({bool offline = false}) {
    _stopped = true;
    _connectionGeneration += 1;
    _forceTokenRefresh = false;
    _accessToken = null;
    _accessTokenProvider = null;
    _onDomainChanged = null;
    _onStaleScopes = null;
    _onLegacyWorkflowChanged = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _scopeDebounce?.cancel();
    _scopeDebounce = null;
    unawaited(_scopeSubscription?.cancel());
    _scopeSubscription = null;
    unawaited(_socketSubscription?.cancel());
    _socketSubscription = null;
    _channel?.sink.close();
    _channel = null;
    _setState(
      offline
          ? RealtimeConnectionState.offline
          : RealtimeConnectionState.disconnected,
    );
  }

  void dispose() {
    disconnect();
    _onStateChanged = null;
  }

  Future<void> _openSocket() async {
    if (_stopped) {
      return;
    }
    final generation = ++_connectionGeneration;
    _setState(
      _reconnectAttempt == 0
          ? RealtimeConnectionState.connecting
          : RealtimeConnectionState.reconnecting,
    );
    String token;
    try {
      token =
          (await _accessTokenProvider?.call(_forceTokenRefresh) ??
                  _accessToken ??
                  '')
              .trim();
    } catch (_) {
      _scheduleReconnect();
      return;
    }
    _forceTokenRefresh = false;
    if (_stopped || generation != _connectionGeneration || token.isEmpty) {
      return;
    }
    _accessToken = token;

    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _socketSubscription?.cancel();
    _channel?.sink.close();

    try {
      final channel = WebSocketChannel.connect(_workflowRealtimeUri());
      _channel = channel;
      _socketSubscription = channel.stream.listen(
        (message) => _handleMessage(channel, message),
        onError: (_) => _scheduleReconnect(),
        onDone: () {
          if (channel.closeReason == 'token_expired') {
            _forceTokenRefresh = true;
          }
          _scheduleReconnect();
        },
        cancelOnError: true,
      );
      await channel.ready;
      if (_stopped ||
          generation != _connectionGeneration ||
          _channel != channel) {
        channel.sink.close();
        return;
      }
      channel.sink.add(
        jsonEncode(<String, Object>{
          'type': 'authenticate',
          'token': token,
          ..._subscriptionPayload(),
        }),
      );
    } catch (_) {
      if (generation == _connectionGeneration) {
        _scheduleReconnect();
      }
    }
  }

  void _handleMessage(WebSocketChannel channel, dynamic message) {
    if (message is! String || message.length > 4096) {
      return;
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(message);
    } catch (_) {
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      return;
    }

    final type = decoded['type']?.toString();
    if (type == 'workflow_realtime_ready' &&
        int.tryParse(decoded['protocolVersion']?.toString() ?? '') == 1) {
      if (_channel == channel && !_stopped) {
        _reconnectAttempt = 0;
        _setState(RealtimeConnectionState.connected);
      }
      return;
    }
    if (type == 'realtime_scopes_ready') {
      final revisions = _parseRevisions(decoded['revisions']);
      for (final known in revisions) {
        _scopeRegistry?.setRevision(known.scope, known.revision);
      }
      final stale = _parseRevisions(decoded['staleScopes']);
      if (stale.isNotEmpty) {
        _setState(RealtimeConnectionState.resyncing);
        _onStaleScopes?.call(stale);
        _setState(RealtimeConnectionState.connected);
      }
      return;
    }

    final event = RealtimeDomainEvent.tryParse(decoded);
    if (event != null) {
      if (_scopeRegistry?.setRevision(event.scope, event.revision) ?? false) {
        _onDomainChanged?.call(event);
      }
      return;
    }

    if (AppEnv.realtimeLegacyBroadcastEnabled && type == 'workflow_changed') {
      final id = decoded['id']?.toString() ?? '';
      final path = decoded['path']?.toString() ?? '';
      if (id.isEmpty || path.isEmpty) {
        return;
      }
      _onLegacyWorkflowChanged?.call(
        WorkflowRealtimeEvent(
          id: id,
          method: decoded['method']?.toString() ?? '',
          path: path,
          actorUserId: decoded['actorUserId']?.toString(),
          targetUserId: decoded['targetUserId']?.toString(),
          targetAction: decoded['targetAction']?.toString(),
        ),
      );
    }
  }

  List<RealtimeKnownRevision> _parseRevisions(Object? value) {
    if (value is! List) {
      return const <RealtimeKnownRevision>[];
    }
    return value
        .map(RealtimeKnownRevision.tryParse)
        .whereType<RealtimeKnownRevision>()
        .toList(growable: false);
  }

  Map<String, Object> _subscriptionPayload() {
    final registry = _scopeRegistry;
    return <String, Object>{
      'scopes':
          registry?.scopes.map((scope) => scope.toJson()).toList() ??
          const <Object>[],
      'knownRevisions':
          registry?.knownRevisions
              .map((revision) => revision.toJson())
              .toList() ??
          const <Object>[],
    };
  }

  void _sendSubscriptionUpdate() {
    if (_state != RealtimeConnectionState.connected || _channel == null) {
      return;
    }
    _channel!.sink.add(
      jsonEncode(<String, Object>{
        'type': 'subscribe',
        ..._subscriptionPayload(),
      }),
    );
  }

  void _scheduleReconnect() {
    if (_stopped || _accessToken == null) {
      return;
    }
    _connectionGeneration += 1;
    unawaited(_socketSubscription?.cancel());
    _socketSubscription = null;
    _channel?.sink.close();
    _channel = null;
    _reconnectTimer?.cancel();
    _setState(RealtimeConnectionState.reconnecting);
    final delay = realtimeReconnectDelay(
      attempt: _reconnectAttempt,
      randomValue: _random.nextDouble(),
    );
    _reconnectAttempt = (_reconnectAttempt + 1).clamp(0, 6);
    _reconnectTimer = Timer(delay, () => unawaited(_openSocket()));
  }

  void _setState(RealtimeConnectionState next) {
    if (_state == next) {
      return;
    }
    _state = next;
    _onStateChanged?.call(next);
  }

  Uri _workflowRealtimeUri() {
    final base = Uri.parse(AppEnv.apiBaseUrl);
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    final versionPrefix = AppEnv.apiVersionPrefix.startsWith('/')
        ? AppEnv.apiVersionPrefix
        : '/${AppEnv.apiVersionPrefix}';

    return base.replace(
      scheme: scheme,
      path: '$basePath$versionPrefix/realtime/workflow',
    );
  }
}
