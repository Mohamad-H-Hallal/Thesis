import 'package:flutter/foundation.dart';

class FirebasePushOptions {
  const FirebasePushOptions._();

  static const bool _isFlutterTest = bool.fromEnvironment('FLUTTER_TEST');
  static const String projectId = 'lebanese-gis-collector-df12b';
  static const String messagingSenderId = '1090841493472';
  static const String androidApplicationId = 'com.example.lebanese_gis_mobile';
  static const String iosBundleId = 'com.example.lebaneseGisMobile';

  static bool get isConfigured {
    if (kIsWeb || _isFlutterTest) {
      return false;
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return true;
      case TargetPlatform.iOS:
        return true;
      default:
        return false;
    }
  }
}
