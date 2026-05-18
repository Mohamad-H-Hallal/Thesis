import 'dart:io';

import 'package:flutter/services.dart';

class ExportFileActions {
  static const MethodChannel _channel = MethodChannel(
    'lb.gov.gis_collector/export_files',
  );

  static Future<void> openFile(String path) async {
    await _invoke('openFile', <String, dynamic>{'path': path});
  }

  static Future<void> shareFile({
    required String path,
    String? subject,
    String? text,
  }) async {
    await _invoke('shareFile', <String, dynamic>{
      'path': path,
      'subject': subject,
      'text': text,
    });
  }

  static Future<void> _invoke(
    String method,
    Map<String, dynamic> arguments,
  ) async {
    if (!Platform.isAndroid) {
      throw PlatformException(
        code: 'UNSUPPORTED_PLATFORM',
        message: 'File actions are currently available on Android only.',
      );
    }

    await _channel.invokeMethod<void>(method, arguments);
  }
}
