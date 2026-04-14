import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config/app_branding.dart';
import 'core/providers/providers.dart';
import 'core/theme/theme.dart';
import 'features/notifications/presentation/widgets/push_notification_coordinator.dart';

void main() {
  runApp(const ProviderScope(child: LebanonGisCollectorApp()));
}

class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

class LebanonGisCollectorApp extends ConsumerWidget {
  const LebanonGisCollectorApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: AppBranding.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      scrollBehavior: const AppScrollBehavior(),
      routerConfig: router,
      builder: (context, child) => PushNotificationCoordinator(
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }
}
