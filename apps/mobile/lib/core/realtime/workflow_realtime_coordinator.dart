import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/domain/auth_models.dart';
import '../../features/imports/presentation/import_providers.dart';
import '../config/app_env.dart';
import '../providers/providers.dart';
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
  late final WorkflowRealtimeService _workflowRealtimeService;
  final Set<String> _handledRealtimeEvents = <String>{};

  @override
  void initState() {
    super.initState();
    _workflowRealtimeService = ref.read(workflowRealtimeServiceProvider);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _workflowRealtimeService.disconnect();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Reconnect only. Foreground updates are delivered as targeted socket
      // events; unsolicited refreshes make active screens feel unstable.
      _syncRealtime(ref.read(authControllerProvider).session);
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
    _syncRealtime(session);
    return widget.child;
  }

  void _syncRealtime(AuthSession? session) {
    if (AppEnv.useMockData || session == null) {
      _connectedRealtimeToken = null;
      _workflowRealtimeService.disconnect();
      return;
    }

    final token = session.accessToken.trim();
    if (_connectedRealtimeToken == token) {
      return;
    }

    _connectedRealtimeToken = token;
    _workflowRealtimeService.connect(
      accessToken: token,
      onWorkflowChanged: _handleWorkflowChange,
    );
  }

  void _handleWorkflowChange(WorkflowRealtimeEvent event) {
    if (!mounted) {
      return;
    }
    if (!_handledRealtimeEvents.add(event.id)) {
      return;
    }
    unawaited(
      Future<void>.delayed(const Duration(minutes: 1), () {
        _handledRealtimeEvents.remove(event.id);
      }),
    );

    final session = ref.read(authControllerProvider).session;
    if (event.targetUserId == session?.user.id &&
        (event.targetAction == 'block' || event.targetAction == 'deactivate')) {
      ref
          .read(authControllerProvider.notifier)
          .forceLogout(
            message: event.targetAction == 'block'
                ? 'Your account has been blocked.'
                : 'Your account has been deactivated.',
            code: event.targetAction == 'block'
                ? 'account_blocked'
                : 'self_deactivated',
          );
      return;
    }

    if (event.actorUserId == session?.user.id) {
      return;
    }

    _invalidateForWorkflowPath(event.path);
  }

  void _invalidateForWorkflowPath(String rawPath) {
    final path = rawPath.toLowerCase();
    if (kIsWeb) {
      // Flutter web can assert if an EditableText is removed while its DOM
      // input is still active. Remote workflow updates rebuild list/filter
      // screens, so clear focus first and then invalidate providers.
      FocusManager.instance.primaryFocus?.unfocus();
    }

    if (path.contains('/notifications')) {
      ref.invalidate(notificationsControllerProvider);
      unawaited(ref.read(notificationsControllerProvider.notifier).load());
      return;
    }

    if (path.contains('/categories')) {
      ref.invalidate(projectCategoriesProvider);
      ref.invalidate(paginatedProjectCategoriesProvider);
      ref.invalidate(projectsProvider);
      ref.invalidate(projectListProvider);
      ref.invalidate(mapProjectsProvider);
      ref.invalidate(paginatedProjectListProvider);
      ref.invalidate(paginatedProjectsProvider);
      return;
    }

    if (path.contains('/projects') || path.contains('/assignments')) {
      ref.invalidate(projectsProvider);
      ref.invalidate(projectListProvider);
      ref.invalidate(mapProjectsProvider);
      ref.invalidate(projectByIdProvider);
      ref.invalidate(paginatedProjectListProvider);
      ref.invalidate(paginatedProjectsProvider);
      ref.invalidate(projectAssignmentsProvider);
      ref.invalidate(paginatedProjectAssignmentsProvider);
      ref.invalidate(paginatedAvailableContributorsProvider);
      ref.invalidate(paginatedManagedAssignmentsProvider);
      ref.invalidate(managedAssignmentsProvider);
      return;
    }

    if (path.contains('/users')) {
      ref.invalidate(managedUsersProvider);
      ref.invalidate(paginatedManagedUsersProvider);
      ref.invalidate(contributorRequestsProvider);
      ref.invalidate(paginatedContributorRequestsProvider);
      ref.invalidate(projectAssignmentsProvider);
      ref.invalidate(paginatedProjectAssignmentsProvider);
      ref.invalidate(paginatedAvailableContributorsProvider);
      return;
    }

    if (path.contains('/imports')) {
      ref.invalidate(importJobsProvider);
      ref.invalidate(importDetailsProvider);
      ref.invalidate(paginatedImportJobsProvider);
      ref.invalidate(paginatedImportFeaturesProvider);
      ref.invalidate(importMapDataProvider);
      ref.invalidate(importFeatureProvider);
      ref.invalidate(projectMapFeaturesProvider);
      ref.invalidate(projectMapViewportFeaturesProvider);
      return;
    }

    if (path.contains('/exports')) {
      ref.invalidate(paginatedExportJobsProvider);
      ref.invalidate(exportJobsSummaryProvider);
      return;
    }

    if (path.contains('/features') || path.contains('/photos')) {
      ref.invalidate(projectMapFeaturesProvider);
      ref.invalidate(projectMapViewportFeaturesProvider);
      ref.invalidate(projectFeatureDetailsProvider);
      ref.invalidate(paginatedProjectFeatureBrowserProvider);
      ref.invalidate(reviewQueueProvider);
      ref.invalidate(rejectedReviewQueueProvider);
      ref.invalidate(projectReviewQueueProvider);
      ref.invalidate(projectRejectedReviewQueueProvider);
      ref.invalidate(projectApprovedReviewQueueProvider);
      ref.invalidate(paginatedReviewQueueProvider);
      ref.invalidate(projectByIdProvider);
      return;
    }

    if (path.contains('/settings')) {
      ref.invalidate(supportSettingsProvider);
      return;
    }

    if (path.contains('/offline-map')) {
      ref.invalidate(offlineMapPackageProvider);
    }
  }
}
