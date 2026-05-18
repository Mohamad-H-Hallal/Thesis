// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;
import 'dart:typed_data';

Future<String> saveDownloadedBytes({
  required List<int> bytes,
  required String fileName,
  required String directoryName,
}) async {
  final blob = html.Blob(<Object>[Uint8List.fromList(bytes)]);
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)
    ..download = fileName
    ..style.display = 'none';

  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  html.Url.revokeObjectUrl(url);

  // Browser downloads are handled by the browser download shelf/folder, so
  // there is no local filesystem path that the app can later open or share.
  return '';
}
