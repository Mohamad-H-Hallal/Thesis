import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/config/app_env.dart';
import '../../../core/config/firebase_push_options.dart';
import '../../auth/domain/auth_models.dart';
import '../domain/notifications_repository.dart';
import '../domain/push_notification_constants.dart';

const AndroidNotificationChannel _fieldAlertsChannel =
    AndroidNotificationChannel(
      'fieldops_alerts',
      'Field alerts',
      description:
          'AI, project, review, import, export, and workflow notifications.',
      importance: Importance.high,
    );

enum PushNotificationEventType { received, opened }

class PushNotificationEvent {
  const PushNotificationEvent({
    required this.type,
    required this.notificationId,
  });

  final PushNotificationEventType type;
  final String? notificationId;
}

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (!FirebasePushOptions.isConfigured) {
    return;
  }

  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
  } catch (_) {
    return;
  }
}

class PushNotificationService {
  PushNotificationService({
    required NotificationsRepository repository,
    required FlutterSecureStorage storage,
  }) : _repository = repository,
       _storage = storage;

  final NotificationsRepository _repository;
  final FlutterSecureStorage _storage;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  final StreamController<PushNotificationEvent> _events =
      StreamController<PushNotificationEvent>.broadcast();

  StreamSubscription<String>? _tokenRefreshSubscription;
  StreamSubscription<RemoteMessage>? _foregroundSubscription;
  StreamSubscription<RemoteMessage>? _openSubscription;
  AuthSession? _session;
  bool _initialized = false;
  bool _runtimeUnavailable = false;
  bool _showSensitivePreview = false;
  bool _notificationsEnabled = false;

  static const _previewPreferenceKey = 'push_sensitive_preview_enabled';
  static const _enabledPreferenceKey = 'push_notifications_enabled';

  Stream<PushNotificationEvent> get events => _events.stream;

  bool get isAvailable =>
      !_runtimeUnavailable &&
      _platformPushRequested &&
      FirebasePushOptions.isConfigured;

  bool get showSensitivePreview => _showSensitivePreview;
  bool get notificationsEnabled => _notificationsEnabled;

  Future<void> initialize() async {
    if (_initialized || !isAvailable) {
      return;
    }

    final enabledPreference = await _storage.read(key: _enabledPreferenceKey);
    final existingToken = await _storage.read(key: storedPushDeviceTokenKey);
    _notificationsEnabled =
        enabledPreference == 'true' ||
        (enabledPreference == null &&
            existingToken != null &&
            existingToken.trim().isNotEmpty);
    _showSensitivePreview =
        (await _storage.read(key: _previewPreferenceKey)) == 'true';

    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }
    } catch (_) {
      _runtimeUnavailable = true;
      return;
    }

    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    await _initializeLocalNotifications();

    _tokenRefreshSubscription = FirebaseMessaging.instance.onTokenRefresh
        .listen((token) async {
          if (!_notificationsEnabled) return;
          await _storage.write(key: storedPushDeviceTokenKey, value: token);
          await _registerCurrentSessionToken(token);
        });

    _foregroundSubscription = FirebaseMessaging.onMessage.listen((
      message,
    ) async {
      await _showForegroundNotification(message);
      _events.add(
        PushNotificationEvent(
          type: PushNotificationEventType.received,
          notificationId: message.data['notificationId'] as String?,
        ),
      );
    });

    _openSubscription = FirebaseMessaging.onMessageOpenedApp.listen((message) {
      _events.add(
        PushNotificationEvent(
          type: PushNotificationEventType.opened,
          notificationId: message.data['notificationId'] as String?,
        ),
      );
    });

    final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null) {
      _events.add(
        PushNotificationEvent(
          type: PushNotificationEventType.opened,
          notificationId: initialMessage.data['notificationId'] as String?,
        ),
      );
    }

    _initialized = true;
  }

  Future<AuthorizationStatus?> permissionStatus() async {
    await initialize();
    if (!_initialized) {
      return null;
    }
    return (await FirebaseMessaging.instance.getNotificationSettings())
        .authorizationStatus;
  }

  Future<bool> requestPermissionAndSync() async {
    await initialize();
    if (!_initialized) {
      return false;
    }
    final settings = await _requestPermissions();
    if (!_isPermissionGranted(settings)) {
      await _setNotificationsEnabled(false);
      await _unregisterStoredToken();
      return false;
    }
    await _setNotificationsEnabled(true);
    await syncSession(_session);
    return true;
  }

  Future<bool> notificationsEnabledForCurrentDevice() async {
    await initialize();
    if (!_initialized || !_notificationsEnabled) return false;
    final settings = await FirebaseMessaging.instance.getNotificationSettings();
    return _isPermissionGranted(settings);
  }

  Future<void> setShowSensitivePreview(bool enabled) async {
    _showSensitivePreview = enabled;
    await _storage.write(
      key: _previewPreferenceKey,
      value: enabled ? 'true' : 'false',
    );
    if (_session != null) {
      await syncSession(_session);
    }
  }

  Future<void> syncSession(AuthSession? session) async {
    _session = session;
    if (!_initialized || session == null) {
      return;
    }
    if (!_notificationsEnabled) {
      await _unregisterStoredToken();
      return;
    }

    final settings = await FirebaseMessaging.instance.getNotificationSettings();
    if (!_isPermissionGranted(settings)) {
      await _unregisterStoredToken();
      return;
    }

    final transportReady = await _ensurePlatformPushTransportReady();
    if (!transportReady) {
      return;
    }

    final token = await FirebaseMessaging.instance.getToken();
    if (token == null || token.trim().isEmpty) {
      return;
    }

    await _storage.write(key: storedPushDeviceTokenKey, value: token);
    await _registerCurrentSessionToken(token);
  }

  Future<void> unregisterCurrentDevice() async {
    await _setNotificationsEnabled(false);
    if (!_initialized) {
      await _storage.delete(key: storedPushDeviceTokenKey);
      return;
    }
    await _unregisterStoredToken();
  }

  Future<void> dispose() async {
    await _tokenRefreshSubscription?.cancel();
    await _foregroundSubscription?.cancel();
    await _openSubscription?.cancel();
    await _events.close();
  }

  Future<void> _initializeLocalNotifications() async {
    const initializationSettings = InitializationSettings(
      android: AndroidInitializationSettings('ic_stat_fieldops'),
      iOS: DarwinInitializationSettings(),
    );

    await _localNotifications.initialize(
      settings: initializationSettings,
      onDidReceiveNotificationResponse: (details) {
        _events.add(
          PushNotificationEvent(
            type: PushNotificationEventType.opened,
            notificationId: details.payload,
          ),
        );
      },
    );

    final androidImplementation = _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidImplementation?.createNotificationChannel(_fieldAlertsChannel);
  }

  Future<NotificationSettings> _requestPermissions() async {
    final messaging = FirebaseMessaging.instance;
    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );

    await messaging.setForegroundNotificationPresentationOptions(
      alert: defaultTargetPlatform == TargetPlatform.iOS,
      badge: true,
      sound: true,
    );

    final androidImplementation = _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidImplementation?.requestNotificationsPermission();

    return settings;
  }

  bool _isPermissionGranted(NotificationSettings settings) {
    return settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
  }

  Future<void> _registerCurrentSessionToken(String token) async {
    final session = _session;
    if (!_notificationsEnabled || session == null || token.trim().isEmpty) {
      return;
    }

    try {
      await _repository.registerDeviceToken(
        token: token,
        platform: _platformName,
        deviceLabel: '$_platformName-${AppEnv.flavorName}',
        showSensitivePreview: _showSensitivePreview,
      );
    } catch (_) {
      // Best effort. Notification delivery will succeed after the next token sync.
    }
  }

  Future<void> _unregisterStoredToken() async {
    final token = await _storage.read(key: storedPushDeviceTokenKey);
    if (token == null || token.trim().isEmpty) {
      return;
    }

    try {
      await _repository.unregisterDeviceToken(token.trim());
    } catch (_) {
      // Best effort. A later login will overwrite the device-token mapping.
    } finally {
      await _storage.delete(key: storedPushDeviceTokenKey);
    }
  }

  Future<void> _setNotificationsEnabled(bool enabled) async {
    _notificationsEnabled = enabled;
    await _storage.write(
      key: _enabledPreferenceKey,
      value: enabled ? 'true' : 'false',
    );
  }

  Future<void> _showForegroundNotification(RemoteMessage message) async {
    if (!_notificationsEnabled || defaultTargetPlatform == TargetPlatform.iOS) {
      return;
    }

    final notification = message.notification;
    if (notification == null) {
      return;
    }

    await _localNotifications.show(
      id: notification.hashCode,
      title: notification.title,
      body: notification.body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'fieldops_alerts',
          'Field alerts',
          channelDescription:
              'AI, project, review, import, export, and workflow notifications.',
          icon: 'ic_stat_fieldops',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      payload: message.data['notificationId'] as String?,
    );
  }

  Future<bool> _ensurePlatformPushTransportReady() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return true;
    }

    for (var attempt = 0; attempt < 10; attempt++) {
      final apnsToken = await FirebaseMessaging.instance.getAPNSToken();
      if (apnsToken != null && apnsToken.trim().isNotEmpty) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    return false;
  }

  String get _platformName {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 'ios';
      default:
        return 'android';
    }
  }

  bool get _platformPushRequested {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return AppEnv.iosPushNotificationsRequested;
      default:
        return AppEnv.androidPushNotificationsRequested;
    }
  }
}
