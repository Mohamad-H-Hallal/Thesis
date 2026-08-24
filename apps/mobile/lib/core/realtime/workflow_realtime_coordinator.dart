import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/domain/auth_models.dart';
import '../config/app_env.dart';
import '../providers/providers.dart';
import 'realtime_edit_guard.dart';
import 'realtime_models.dart';
import 'realtime_scope_coalescer.dart';
import 'realtime_scope_registry.dart';
import 'workflow_realtime_service.dart';

class WorkflowRealtimeCoordinator extends ConsumerStatefulWidget {
  const WorkflowRealtimeCoordinator({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<WorkflowRealtimeCoordinator> createState() =>
      _WorkflowRealtimeCoordinatorState();
}

class _WorkflowRealtimeCoordinatorState
    extends ConsumerState<WorkflowRealtimeCoordinator>
    with WidgetsBindingObserver {
  String? _connectedRealtimeToken;
  String? _registeredUserId;
  late final WorkflowRealtimeService _workflowRealtimeService;
  late final RealtimeScopeRegistry _scopeRegistry;
  late final RealtimeEditGuardRegistry _editGuardRegistry;
  final Set<RealtimeScope> _baseScopes = <RealtimeScope>{};
  final Set<String> _handledRealtimeEvents = <String>{};
  late final RealtimeScopeCoalescer _scopeCoalescer;
  AuthSession? _desiredSession;
  bool? _desiredOnline;
  bool _syncScheduled = false;
  bool _disposing = false;

  @override
  void initState() {
    super.initState();
    _workflowRealtimeService = ref.read(workflowRealtimeServiceProvider);
    ref.read(deletedAccountApiBindingProvider);
    _scopeRegistry = ref.read(realtimeScopeRegistryProvider);
    _editGuardRegistry = ref.read(realtimeEditGuardRegistryProvider);
    _scopeCoalescer = RealtimeScopeCoalescer(onRefresh: _refreshScope);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_resumeDeletedAccountCleanup());
  }

  @override
  void dispose() {
    _disposing = true;
    WidgetsBinding.instance.removeObserver(this);
    _unregisterBaseScopes();
    _scopeCoalescer.dispose();
    _workflowRealtimeService.disconnect();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncRealtime(
        ref.read(authControllerProvider).session,
        isOnline: ref.read(networkOnlineProvider).valueOrNull,
      );
      return;
    }

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _workflowRealtimeService.disconnect();
      _connectedRealtimeToken = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(
      authControllerProvider.select((state) => state.session),
    );
    final isOnline = ref.watch(networkOnlineProvider).valueOrNull;
    _scheduleRealtimeSync(session, isOnline: isOnline);
    return widget.child;
  }

  void _scheduleRealtimeSync(AuthSession? session, {bool? isOnline}) {
    _desiredSession = session;
    _desiredOnline = isOnline;
    if (_syncScheduled) return;

    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (!mounted || _disposing) return;
      _syncRealtime(_desiredSession, isOnline: _desiredOnline);
    });
  }

  void _syncRealtime(AuthSession? session, {bool? isOnline}) {
    if (!AppEnv.realtimeV2Enabled || AppEnv.useMockData || session == null) {
      _connectedRealtimeToken = null;
      _unregisterBaseScopes();
      _workflowRealtimeService.disconnect();
      return;
    }
    _registerBaseScopes(session);
    if (isOnline != true) {
      _connectedRealtimeToken = null;
      _workflowRealtimeService.disconnect(offline: true);
      return;
    }

    final token = session.accessToken.trim();
    if (_connectedRealtimeToken == token &&
        _workflowRealtimeService.state !=
            RealtimeConnectionState.disconnected &&
        _workflowRealtimeService.state != RealtimeConnectionState.offline) {
      return;
    }

    _connectedRealtimeToken = token;
    _workflowRealtimeService.connect(
      accessToken: token,
      accessTokenProvider: (forceRefresh) async {
        final currentSession = ref.read(authControllerProvider).session;
        if (currentSession == null) {
          return '';
        }
        final apiClient = ref.read(apiClientProvider);
        if (forceRefresh) {
          return await apiClient.refreshAccessTokenForOwner(
                currentSession.user.id,
              ) ??
              '';
        }
        return apiClient
                .captureSessionForOwner(currentSession.user.id)
                ?.accessToken ??
            currentSession.accessToken;
      },
      scopeRegistry: _scopeRegistry,
      onDomainChanged: _handleDomainChange,
      onStaleScopes: _handleStaleScopes,
      onLegacyWorkflowChanged: _handleLegacyWorkflowChange,
      onStateChanged: (state) {
        if (mounted && !_disposing) {
          ref.read(realtimeConnectionStateProvider.notifier).state = state;
        }
      },
    );
  }

  void _registerBaseScopes(AuthSession session) {
    if (_registeredUserId == session.user.id) {
      return;
    }
    _unregisterBaseScopes();
    _registeredUserId = session.user.id;
    final scopes = <RealtimeScope>{
      const RealtimeScope('projects', 'all'),
      const RealtimeScope('categories', 'all'),
      const RealtimeScope('offline_map', 'all'),
      const RealtimeScope('settings', 'support'),
      RealtimeScope('notifications', session.user.id),
      RealtimeScope('user', session.user.id),
      RealtimeScope('assignments', session.user.id),
      RealtimeScope('imports', session.user.id),
      RealtimeScope('exports', session.user.id),
      RealtimeScope('privacy_requests', session.user.id),
      RealtimeScope('content_reports', session.user.id),
      if (session.user.role == UserRole.admin) ...<RealtimeScope>{
        const RealtimeScope('users', 'all'),
        const RealtimeScope('assignments', 'all'),
        const RealtimeScope('imports', 'all'),
        const RealtimeScope('exports', 'all'),
        const RealtimeScope('reviews', 'all'),
        if (session.user.isSuperAdmin) ...<RealtimeScope>{
          const RealtimeScope('privacy_admin_queue', 'all'),
          const RealtimeScope('moderation_admin_queue', 'all'),
        },
      },
    };
    for (final scope in scopes) {
      _scopeRegistry.register(scope);
      _baseScopes.add(scope);
    }
  }

  void _unregisterBaseScopes() {
    if (_baseScopes.isEmpty) {
      _registeredUserId = null;
      return;
    }
    for (final scope in _baseScopes) {
      _scopeRegistry.unregister(scope);
    }
    _baseScopes.clear();
    _registeredUserId = null;
  }

  void _handleDomainChange(RealtimeDomainEvent event) {
    if (!mounted || !_handledRealtimeEvents.add(event.eventId)) {
      return;
    }
    unawaited(
      Future<void>.delayed(const Duration(minutes: 1), () {
        _handledRealtimeEvents.remove(event.eventId);
      }),
    );

    final session = ref.read(authControllerProvider).session;
    if (event.entityType == 'user' &&
        event.entityId == session?.user.id &&
        event.action == 'account_deletion_completed') {
      unawaited(_handleDeletedAccount(session!.user.id));
      return;
    }
    if (event.entityType == 'user' &&
        event.entityId == session?.user.id &&
        (event.action == 'blocked' ||
            event.action == 'deactivated' ||
            event.action == 'role_changed' ||
            (event.action == 'session_revoked' &&
                !event.originatedByCurrentSession))) {
      ref
          .read(authControllerProvider.notifier)
          .forceLogout(
            message: event.action == 'blocked'
                ? 'Your account has been blocked.'
                : event.action == 'deactivated'
                ? 'Your account has been deactivated.'
                : 'Your account access changed. Please sign in again.',
            code: event.action == 'blocked'
                ? 'account_blocked'
                : event.action == 'deactivated'
                ? 'self_deactivated'
                : 'session_changed',
          );
      return;
    }

    if (event.originatedByCurrentSession) {
      return;
    }
    final entityId = event.entityId;
    if (entityId != null &&
        _editGuardRegistry.isEditing(event.entityType, entityId)) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: const Text(
              'This item was updated elsewhere. Your unsaved changes are preserved.',
            ),
            action: SnackBarAction(
              label: 'Review',
              onPressed: () => _scheduleScopeRefresh(event.scope),
            ),
          ),
        );
      return;
    }
    _scheduleScopeRefresh(event.scope);
  }

  Future<void> _handleDeletedAccount(String ownerUserId) async {
    final cleanup = ref.read(deletedAccountLocalCleanupProvider);
    final authController = ref.read(authControllerProvider.notifier);
    try {
      await cleanup.markAndPurge(ownerUserId);
    } catch (_) {
      // The durable marker remains and cleanup resumes on the next launch.
    } finally {
      await authController.forceLogout(
        message: 'Your TerraLeb account has been deleted.',
        code: 'account_deleted',
      );
    }
  }

  Future<void> _resumeDeletedAccountCleanup() async {
    final cleanup = ref.read(deletedAccountLocalCleanupProvider);
    final authController = ref.read(authControllerProvider.notifier);
    final currentOwner = ref.read(authControllerProvider).session?.user.id;
    final completed = await cleanup.resumePending();
    if (currentOwner != null && completed.contains(currentOwner)) {
      await authController.forceLogout(
        message: 'Your TerraLeb account has been deleted.',
        code: 'account_deleted',
      );
    }
  }

  void _handleStaleScopes(List<RealtimeKnownRevision> staleScopes) {
    for (final stale in staleScopes) {
      _scheduleScopeRefresh(stale.scope);
    }
  }

  void _scheduleScopeRefresh(RealtimeScope scope) {
    _scopeCoalescer.schedule(scope);
  }

  void _refreshScope(RealtimeScope scope) {
    if (!mounted) {
      return;
    }
    ref.read(realtimeScopeRevisionProvider(scope).notifier).state++;
    if (scope.scopeType == 'notifications') {
      unawaited(
        ref.read(notificationsControllerProvider.notifier).refreshSilently(),
      );
    }
  }

  void _handleLegacyWorkflowChange(WorkflowRealtimeEvent event) {
    if (!AppEnv.realtimeLegacyBroadcastEnabled ||
        !_handledRealtimeEvents.add(event.id)) {
      return;
    }
    final path = event.path.toLowerCase();
    if (path.contains('/notifications')) {
      final userId = ref.read(authControllerProvider).session?.user.id;
      if (userId != null) {
        _scheduleScopeRefresh(RealtimeScope('notifications', userId));
      }
    } else if (path.contains('/categories')) {
      _scheduleScopeRefresh(const RealtimeScope('categories', 'all'));
    } else if (path.contains('/projects')) {
      _scheduleScopeRefresh(const RealtimeScope('projects', 'all'));
    } else if (path.contains('/users')) {
      _scheduleScopeRefresh(const RealtimeScope('users', 'all'));
    } else if (path.contains('/assignments')) {
      _scheduleScopeRefresh(const RealtimeScope('assignments', 'all'));
    } else if (path.contains('/imports')) {
      _scheduleScopeRefresh(const RealtimeScope('imports', 'all'));
    } else if (path.contains('/exports')) {
      _scheduleScopeRefresh(const RealtimeScope('exports', 'all'));
    } else if (path.contains('/settings')) {
      _scheduleScopeRefresh(const RealtimeScope('settings', 'support'));
    } else if (path.contains('/offline-map')) {
      _scheduleScopeRefresh(const RealtimeScope('offline_map', 'all'));
    }
  }
}
