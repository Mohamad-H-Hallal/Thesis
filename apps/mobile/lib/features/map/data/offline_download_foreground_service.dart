import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

@pragma('vm:entry-point')
void startOfflineDownloadForegroundTask() {
  DartPluginRegistrant.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(OfflineDownloadForegroundTaskHandler());
}

class OfflineDownloadForegroundTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationButtonPressed(String id) {
    if (id != OfflineDownloadForegroundService.cancelButtonId) {
      return;
    }
    FlutterForegroundTask.sendDataToMain(const <String, Object>{
      'type': OfflineDownloadForegroundService.cancelRequestedEvent,
    });
  }
}

class OfflineDownloadForegroundService {
  OfflineDownloadForegroundService._();

  static const int _serviceId = 42115;
  static const String cancelButtonId = 'offline_download_cancel';
  static const String cancelRequestedEvent =
      'offline_download_cancel_requested';
  static bool _initialized = false;
  static bool _startedByOfflineDownload = false;

  @visibleForTesting
  static bool isAvailableOnPlatform({required bool isWeb}) => !isWeb;

  static bool get _isAvailable => isAvailableOnPlatform(isWeb: kIsWeb);

  static void initializeCommunication() {
    if (!_isAvailable) {
      return;
    }
    FlutterForegroundTask.initCommunicationPort();
  }

  static void addTaskDataCallback(void Function(Object data) callback) {
    if (!_isAvailable) {
      return;
    }
    FlutterForegroundTask.addTaskDataCallback(callback);
  }

  static void removeTaskDataCallback(void Function(Object data) callback) {
    if (!_isAvailable) {
      return;
    }
    FlutterForegroundTask.removeTaskDataCallback(callback);
  }

  static Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    if (!_isAvailable) {
      _initialized = true;
      return;
    }
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'offline_downloads',
        channelName: 'Offline downloads',
        channelDescription:
            'Keeps offline map downloads running while TerraLeb is in the background.',
        onlyAlertOnce: true,
        showWhen: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
        allowAutoRestart: true,
        stopWithTask: false,
      ),
    );
    _initialized = true;
  }

  static Future<void> start({
    required String projectName,
    required bool refreshOnly,
  }) async {
    if (!_isAvailable) {
      return;
    }
    await initialize();
    await _requestRequiredPermissions();

    final title = refreshOnly
        ? 'Refreshing offline resources'
        : 'Downloading offline resources';
    final text =
        '${_trimProjectName(projectName)} - keep Wi-Fi on until this finishes.';
    final buttons = const <NotificationButton>[
      NotificationButton(id: cancelButtonId, text: 'Cancel'),
    ];

    final ServiceRequestResult result;
    if (await FlutterForegroundTask.isRunningService) {
      result = await FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: text,
        notificationButtons: buttons,
        callback: startOfflineDownloadForegroundTask,
      );
    } else {
      result = await FlutterForegroundTask.startService(
        serviceId: _serviceId,
        serviceTypes: const <ForegroundServiceTypes>[
          ForegroundServiceTypes.dataSync,
        ],
        notificationTitle: title,
        notificationText: text,
        notificationButtons: buttons,
        notificationInitialRoute: '/',
        callback: startOfflineDownloadForegroundTask,
      );
    }

    if (result is ServiceRequestFailure) {
      throw StateError(
        'Unable to keep the offline download running in the background: ${result.error}',
      );
    }
    _startedByOfflineDownload = true;
  }

  static Future<void> updateProgress(String label) async {
    if (!_isAvailable ||
        !_startedByOfflineDownload ||
        !await FlutterForegroundTask.isRunningService) {
      return;
    }
    final text = label.length <= 120 ? label : '${label.substring(0, 117)}...';
    await FlutterForegroundTask.updateService(
      notificationTitle: 'Offline resources downloading',
      notificationText: text,
      notificationButtons: const <NotificationButton>[
        NotificationButton(id: cancelButtonId, text: 'Cancel'),
      ],
    );
  }

  static Future<void> stop() async {
    if (!_isAvailable || !_startedByOfflineDownload) {
      return;
    }
    _startedByOfflineDownload = false;
    if (!await FlutterForegroundTask.isRunningService) {
      return;
    }
    await FlutterForegroundTask.stopService();
  }

  static Future<void> _requestRequiredPermissions() async {
    if (!_isAvailable) {
      return;
    }
    final notificationPermission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (notificationPermission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
  }

  static String _trimProjectName(String projectName) {
    final trimmed = projectName.trim();
    if (trimmed.isEmpty) {
      return 'Offline project';
    }
    return trimmed.length <= 42 ? trimmed : '${trimmed.substring(0, 39)}...';
  }
}
