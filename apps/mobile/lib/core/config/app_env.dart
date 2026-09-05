import 'package:flutter/foundation.dart';

enum AppFlavor { dev, staging, prod }

class AppEnv {
  const AppEnv._();

  static bool _parseBool(String raw, {required bool fallback}) {
    final normalized = raw.trim().toLowerCase();
    if (normalized.isEmpty) {
      return fallback;
    }
    if (normalized == '1' || normalized == 'true' || normalized == 'yes') {
      return true;
    }
    if (normalized == '0' || normalized == 'false' || normalized == 'no') {
      return false;
    }
    return fallback;
  }

  static AppFlavor get flavor {
    const value = String.fromEnvironment('APP_FLAVOR', defaultValue: 'dev');
    switch (value) {
      case 'staging':
        return AppFlavor.staging;
      case 'prod':
        return AppFlavor.prod;
      default:
        return AppFlavor.dev;
    }
  }

  static String get apiBaseUrl {
    const fromDefine = String.fromEnvironment('API_BASE_URL', defaultValue: '');
    if (fromDefine.isNotEmpty) {
      return fromDefine;
    }

    switch (flavor) {
      case AppFlavor.dev:
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
          return 'http://10.0.2.2:3000';
        }
        return 'http://localhost:3000';
      case AppFlavor.staging:
        return 'https://staging-api.example.gov.lb';
      case AppFlavor.prod:
        return 'https://api.example.gov.lb';
    }
  }

  static String get apiVersionPrefix {
    const value = String.fromEnvironment(
      'API_VERSION_PREFIX',
      defaultValue: '/api/v1',
    );
    if (value.isEmpty) {
      return '/api/v1';
    }
    if (value.startsWith('/')) {
      return value;
    }
    return '/$value';
  }

  static String get appLogLevel {
    const value = String.fromEnvironment('APP_LOG_LEVEL', defaultValue: '');
    final normalized = value.trim().toLowerCase();
    if (normalized == 'debug' ||
        normalized == 'info' ||
        normalized == 'warning' ||
        normalized == 'warn' ||
        normalized == 'error') {
      return normalized;
    }
    return flavor == AppFlavor.dev ? 'debug' : 'info';
  }

  static bool get useMockAuth {
    const raw = String.fromEnvironment('USE_MOCK_AUTH', defaultValue: '');
    final enabled = _parseBool(raw, fallback: false);
    if (flavor == AppFlavor.prod && enabled) {
      throw StateError('Mock authentication cannot be enabled in production.');
    }
    return enabled;
  }

  static bool get useMockData {
    const raw = String.fromEnvironment('USE_MOCK_DATA', defaultValue: '');
    return _parseBool(raw, fallback: false);
  }

  static bool get realtimeV2Enabled {
    const raw = String.fromEnvironment('REALTIME_V2_ENABLED', defaultValue: '');
    return _parseBool(raw, fallback: true);
  }

  static bool get realtimeLegacyBroadcastEnabled {
    const raw = String.fromEnvironment(
      'REALTIME_LEGACY_BROADCAST_ENABLED',
      defaultValue: '',
    );
    return _parseBool(raw, fallback: true);
  }

  static bool get realtimePollingFallbackEnabled {
    const raw = String.fromEnvironment(
      'REALTIME_POLLING_FALLBACK_ENABLED',
      defaultValue: '',
    );
    return _parseBool(raw, fallback: false);
  }

  static bool get pushNotificationsRequested {
    const raw = String.fromEnvironment(
      'PUSH_NOTIFICATIONS_ENABLED',
      defaultValue: '',
    );
    return _parseBool(raw, fallback: true);
  }

  static bool get androidPushNotificationsRequested {
    const raw = String.fromEnvironment(
      'ANDROID_PUSH_NOTIFICATIONS_ENABLED',
      defaultValue: '',
    );
    return _parseBool(raw, fallback: pushNotificationsRequested);
  }

  static bool get iosPushNotificationsRequested {
    const raw = String.fromEnvironment(
      'IOS_PUSH_NOTIFICATIONS_ENABLED',
      defaultValue: '',
    );
    return _parseBool(raw, fallback: false);
  }

  static bool get licensedEsriOfflineBasemapEnabled {
    const raw = String.fromEnvironment(
      'LICENSED_ESRI_OFFLINE_BASEMAP_ENABLED',
      defaultValue: '',
    );
    return _parseBool(raw, fallback: false);
  }

  static bool get hybridMapUsesApiProxy {
    const raw = String.fromEnvironment(
      'MAP_HYBRID_USE_API_PROXY',
      defaultValue: '',
    );
    return _parseBool(raw, fallback: flavor != AppFlavor.dev);
  }

  static String get mapApiBaseUrl {
    final base = apiBaseUrl.replaceFirst(RegExp(r'/+$'), '');
    return '$base$apiVersionPrefix/maps';
  }

  static String get mapProviderUserAgent {
    const value = String.fromEnvironment(
      'MAP_PROVIDER_USER_AGENT',
      defaultValue: 'TerraLeb-development (privacy contact not configured)',
    );
    return value.trim();
  }

  static String get streetTileUrlTemplate {
    const fallback = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
    const value = String.fromEnvironment(
      'MAP_STREET_TILE_URL',
      defaultValue: fallback,
    );
    return value.trim().isEmpty ? fallback : value.trim();
  }

  static String get flavorName => flavor.name;
}
