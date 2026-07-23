import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/features/map/presentation/widgets/feature_photo_gallery.dart';

void main() {
  testWidgets('reopened offline photo uses a local file image provider', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp('offline-gallery-');
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final photo = File('${directory.path}${Platform.pathSeparator}photo.jpg');
    await photo.writeAsBytes(const <int>[0xff, 0xd8, 0xff, 0xd9]);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeaturePhotoGallery(
            items: <FeaturePhotoGalleryItem>[
              FeaturePhotoGalleryItem(
                id: 'local-photo',
                imagePath: photo.path,
                label: 'Offline photo',
                isLocalFile: true,
              ),
            ],
          ),
        ),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<FileImage>());
    expect((image.image as FileImage).file.path, photo.path);
  });
}
