import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config/app_branding.dart';
import 'core/providers/providers.dart';
import 'core/realtime/workflow_realtime_coordinator.dart';
import 'core/theme/theme.dart';
import 'core/widgets/app_system_ui_scope.dart';
import 'features/map/data/offline_download_foreground_service.dart';
import 'features/notifications/presentation/widgets/push_notification_coordinator.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _disableDebugVisualOverlays();
  OfflineDownloadForegroundService.initializeCommunication();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const ProviderScope(child: LebanonGisCollectorApp()));
}

void _disableDebugVisualOverlays() {
  if (!kDebugMode) return;
  debugPaintSizeEnabled = false;
  debugPaintBaselinesEnabled = false;
  debugPaintPointersEnabled = false;
  debugPaintLayerBordersEnabled = false;
  debugRepaintRainbowEnabled = false;
}

@visibleForTesting
Widget wrapForegroundTaskForPlatform({
  required Widget child,
  required bool isWeb,
}) => isWeb ? child : WithForegroundTask(child: child);

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
      themeAnimationDuration: Duration.zero,
      scrollBehavior: const AppScrollBehavior(),
      routerConfig: router,
      builder: (context, child) {
        final coordinatedChild = WorkflowRealtimeCoordinator(
          child: PushNotificationCoordinator(
            child: child ?? const SizedBox.shrink(),
          ),
        );
        return AppSystemUiScope(
          child: wrapForegroundTaskForPlatform(
            child: coordinatedChild,
            isWeb: kIsWeb,
          ),
        );
      },
    );
  }
}
