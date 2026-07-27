import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/features/map/presentation/widgets/feature_photo_gallery.dart';

void main() {
  test('reopened offline photo uses a local file image provider', () async {
    final directory = await Directory.systemTemp.createTemp('offline-gallery-');
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final photo = File('${directory.path}${Platform.pathSeparator}photo.jpg');
    await photo.writeAsBytes(const <int>[0xff]);

    final imageProvider = featurePhotoImageProvider(
      FeaturePhotoGalleryItem(
        id: 'local-photo',
        imagePath: photo.path,
        label: 'Offline photo',
        isLocalFile: true,
      ),
    );

    expect(imageProvider, isA<FileImage>());
    expect((imageProvider as FileImage).file.path, photo.path);
  });
}
