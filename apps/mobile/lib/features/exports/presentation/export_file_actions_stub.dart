import 'package:flutter/services.dart';

class ExportFileActions {
  static Future<void> openFile(String path) async {
    throw PlatformException(
      code: 'UNSUPPORTED_PLATFORM',
      message: 'Use the browser downloads list to open this file.',
    );
  }

  static Future<void> shareFile({
    required String path,
    String? subject,
    String? text,
  }) async {
    throw PlatformException(
      code: 'UNSUPPORTED_PLATFORM',
      message: 'Use the browser downloads list to share this file.',
    );
  }
}
