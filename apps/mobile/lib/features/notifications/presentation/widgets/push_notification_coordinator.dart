import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../auth/presentation/controllers/auth_controller.dart';
import '../../data/push_notification_service.dart';

class PushNotificationCoordinator extends ConsumerStatefulWidget {
  const PushNotificationCoordinator({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<PushNotificationCoordinator> createState() =>
      _PushNotificationCoordinatorState();
}

class _PushNotificationCoordinatorState
    extends ConsumerState<PushNotificationCoordinator> {
  ProviderSubscription<AuthState>? _authSubscription;
  StreamSubscription<PushNotificationEvent>? _pushSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bootstrap();
    });
  }

  Future<void> _bootstrap() async {
    final service = ref.read(pushNotificationServiceProvider);

    _authSubscription = ref.listenManual<AuthState>(authControllerProvider, (
      previous,
      next,
    ) async {
      final previousUserId = previous?.session?.user.id;
      final nextSession = next.session;
      if (nextSession == null) {
        return;
      }
      if (previousUserId != nextSession.user.id) {
        await service.initialize();
        await service.syncSession(nextSession);
      }
    });

    _pushSubscription = service.events.listen((event) {
      if (!mounted) {
        return;
      }
      final authState = ref.read(authControllerProvider);
      if (!authState.isAuthenticated) {
        return;
      }

      ref.read(notificationsControllerProvider.notifier).load();

      if (event.type == PushNotificationEventType.opened && context.mounted) {
        context.go(AppRoutes.notifications);
      }
    });

    final currentSession = ref.read(authControllerProvider).session;
    if (currentSession != null) {
      await service.initialize();
      await service.syncSession(currentSession);
    }
  }

  @override
  void dispose() {
    _authSubscription?.close();
    _pushSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
