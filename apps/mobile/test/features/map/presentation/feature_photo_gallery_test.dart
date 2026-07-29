import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
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

  testWidgets('loads protected local photo bytes instead of its file path', (
    tester,
  ) async {
    var loadCount = 0;
    final imageBytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
      '/w8AAusB9Y9Z3Z8AAAAASUVORK5CYII=',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeaturePhotoGallery(
            items: <FeaturePhotoGalleryItem>[
              FeaturePhotoGalleryItem(
                id: 'protected-photo',
                imagePath: 'must-not-be-opened.jpg.tlphoto',
                label: 'Protected photo',
                isLocalFile: true,
                loadImageBytes: () async {
                  loadCount += 1;
                  return imageBytes;
                },
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(loadCount, 1);
    expect(find.byType(Image), findsOneWidget);
  });
}
