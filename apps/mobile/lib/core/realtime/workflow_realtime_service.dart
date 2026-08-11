import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/app_env.dart';

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
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  bool _stopped = true;
  String? _accessToken;
  AccessTokenProvider? _accessTokenProvider;
  ValueChanged<WorkflowRealtimeEvent>? _onWorkflowChanged;
  int _reconnectAttempt = 0;

  void connect({
    required String accessToken,
    AccessTokenProvider? accessTokenProvider,
    required ValueChanged<WorkflowRealtimeEvent> onWorkflowChanged,
  }) {
    final normalizedToken = accessToken.trim();
    if (normalizedToken.isEmpty) {
      disconnect();
      return;
    }

    _onWorkflowChanged = onWorkflowChanged;
    _accessTokenProvider = accessTokenProvider;
    if (!_stopped && _accessToken == normalizedToken && _channel != null) {
      return;
    }

    _stopped = false;
    _accessToken = normalizedToken;
    _openSocket();
  }

  void disconnect() {
    _stopped = true;
    _accessToken = null;
    _accessTokenProvider = null;
    _onWorkflowChanged = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
  }

  void dispose() {
    disconnect();
  }

  void _openSocket() {
    final token = (_accessTokenProvider?.call() ?? _accessToken ?? '').trim();
    if (_stopped || token.isEmpty) {
      return;
    }
    _accessToken = token;

    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _subscription?.cancel();
    _channel?.sink.close();

    try {
      final channel = WebSocketChannel.connect(_workflowRealtimeUri());
      _channel = channel;
      _subscription = channel.stream.listen(
        _handleMessage,
        onError: (_) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
        cancelOnError: true,
      );
      unawaited(
        channel.ready
            .then<void>((_) {
              if (_channel == channel && !_stopped) {
                channel.sink.add(
                  jsonEncode(<String, String>{
                    'type': 'authenticate',
                    'token': token,
                  }),
                );
                _reconnectAttempt = 0;
              }
            })
            .catchError((_) {
              if (_channel == channel && !_stopped) {
                _scheduleReconnect();
              }
            }),
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _handleMessage(dynamic message) {
    if (message is! String) {
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

    if (decoded['type'] == 'workflow_changed') {
      final id = decoded['id']?.toString() ?? '';
      final path = decoded['path']?.toString() ?? '';
      if (id.isEmpty || path.isEmpty) {
        return;
      }
      _onWorkflowChanged?.call(
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

  void _scheduleReconnect() {
    if (_stopped || _accessToken == null) {
      return;
    }

    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;

    _reconnectTimer?.cancel();
    final seconds = (1 << _reconnectAttempt).clamp(2, 30);
    _reconnectAttempt = (_reconnectAttempt + 1).clamp(0, 5);
    _reconnectTimer = Timer(Duration(seconds: seconds), _openSocket);
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

typedef ValueChanged<T> = void Function(T value);
typedef AccessTokenProvider = String Function();
