import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

class FirebasePushOptions {
  const FirebasePushOptions._();

  static const String _apiKey = String.fromEnvironment(
    'FIREBASE_API_KEY',
    defaultValue: '',
  );
  static const String _projectId = String.fromEnvironment(
    'FIREBASE_PROJECT_ID',
    defaultValue: '',
  );
  static const String _messagingSenderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
    defaultValue: '',
  );
  static const String _androidAppId = String.fromEnvironment(
    'FIREBASE_ANDROID_APP_ID',
    defaultValue: '',
  );
  static const String _iosAppId = String.fromEnvironment(
    'FIREBASE_IOS_APP_ID',
    defaultValue: '',
  );
  static const String _storageBucket = String.fromEnvironment(
    'FIREBASE_STORAGE_BUCKET',
    defaultValue: '',
  );

  static bool get isConfigured {
    if (_apiKey.isEmpty ||
        _projectId.isEmpty ||
        _messagingSenderId.isEmpty) {
      return false;
    }

    if (kIsWeb) {
      return false;
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return _androidAppId.isNotEmpty;
      case TargetPlatform.iOS:
        return _iosAppId.isNotEmpty;
      default:
        return false;
    }
  }

  static FirebaseOptions? get currentPlatform {
    if (!isConfigured) {
      return null;
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return FirebaseOptions(
          apiKey: _apiKey,
          appId: _androidAppId,
          messagingSenderId: _messagingSenderId,
          projectId: _projectId,
          storageBucket: _storageBucket.isEmpty ? null : _storageBucket,
        );
      case TargetPlatform.iOS:
        return FirebaseOptions(
          apiKey: _apiKey,
          appId: _iosAppId,
          messagingSenderId: _messagingSenderId,
          projectId: _projectId,
          storageBucket: _storageBucket.isEmpty ? null : _storageBucket,
          iosBundleId: 'com.example.lebaneseGisMobile',
        );
      default:
        return null;
    }
  }
}
