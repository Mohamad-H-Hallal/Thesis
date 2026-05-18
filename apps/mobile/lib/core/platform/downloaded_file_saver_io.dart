import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<String> saveDownloadedBytes({
  required List<int> bytes,
  required String fileName,
  required String directoryName,
}) async {
  final externalDir = await getExternalStorageDirectory();
  final baseDir = externalDir != null
      ? Directory(p.join(externalDir.path, directoryName))
      : Directory(
          p.join(
            (await getApplicationDocumentsDirectory()).path,
            directoryName,
          ),
        );
  await baseDir.create(recursive: true);

  final target = File(p.join(baseDir.path, fileName));
  await target.writeAsBytes(bytes, flush: true);
  return target.path;
}
