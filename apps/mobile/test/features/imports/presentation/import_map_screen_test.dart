import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/features/imports/domain/import_models.dart';
import 'package:lebanese_gis_mobile/features/imports/presentation/import_providers.dart';
import 'package:lebanese_gis_mobile/features/imports/presentation/screens/import_map_screen.dart';
import 'package:lebanese_gis_mobile/features/map/domain/map_feature.dart';
import 'package:flutter_map/flutter_map.dart';

GisImportJob _job() {
  return GisImportJob(
    id: 'import-1',
    projectId: 'project-1',
    projectName: 'Import Project',
    uploadedByUserId: 'contributor-1',
    uploadedByName: 'Field Contributor',
    possibleDuplicate: false,
    originalFilename: 'dataset.geojson',
    fileSizeBytes: 2048,
    fileChecksumSha256: 'a' * 64,
    fileType: 'geojson',
    status: 'pending_review',
    geometryCount: 2,
    pendingFeatureCount: 1,
    approvedFeatureCount: 1,
    rejectedFeatureCount: 0,
    failedFeatureCount: 0,
    warningCount: 0,
    errorCount: 0,
    geometryTypes: const <String>['Point'],
    fileMetadata: const <String, dynamic>{},
    validationSummary: const <String, dynamic>{},
    reviewScope: 'admin',
    uploadedAt: DateTime(2026, 4, 25),
    createdAt: DateTime(2026, 4, 25),
    updatedAt: DateTime(2026, 4, 25),
  );
}

ImportedFeature _importedFeature(String id, String status, double lon, double lat) {
  return ImportedFeature(
    id: id,
    importJobId: 'import-1',
    sourceIndex: id == 'feature-1' ? 0 : 1,
    displayTitle: 'Imported feature $id',
    geometryType: 'Point',
    geometry: <String, dynamic>{
      'type': 'Point',
      'coordinates': <double>[lon, lat],
    },
    attributes: <String, dynamic>{'name': 'Feature $id'},
    status: status,
    validationWarnings: const <String>[],
    validationErrors: const <String>[],
    validationReport: const <String, dynamic>{},
    createdAt: DateTime(2026, 4, 25),
    updatedAt: DateTime(2026, 4, 25),
  );
}

MapFeatureSummary _approvedFeature() {
  return const MapFeatureSummary(
    id: 'approved-1',
    status: 'approved',
    geometry: <String, dynamic>{
      'type': 'Point',
      'coordinates': <double>[35.52, 33.91],
    },
    attributes: <String, dynamic>{'name': 'Approved context feature'},
  );
}

void main() {
  testWidgets('import map shows staged and approved context layers separately', (
    tester,
  ) async {
    const query = ImportMapQuery(importId: 'import-1', projectId: 'project-1');
    final details = GisImportDetails(
      job: _job(),
      previewFeatures: const <ImportedFeature>[],
      previewSummary: const ImportPreviewSummary(
        geometryFeatureCount: 2,
        previewFeatureCount: 2,
        outsideWorkspaceFeatureCount: 0,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          importDetailsProvider('import-1').overrideWith((ref) async => details),
          importMapDataProvider(query).overrideWith(
            (ref) async => ImportMapData(
              stagedFeatures: <ImportedFeature>[
                _importedFeature('feature-1', 'pending_review', 35.5, 33.9),
                _importedFeature('feature-2', 'approved', 35.55, 33.95),
              ],
              approvedProjectFeatures: <MapFeatureSummary>[_approvedFeature()],
            ),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: ImportMapScreen(importId: 'import-1', projectId: 'project-1'),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Import map'), findsOneWidget);
    expect(find.textContaining('2 staged total'), findsOneWidget);
    expect(find.textContaining('1 approved project features'), findsOneWidget);
    expect(find.byType(FlutterMap), findsOneWidget);
  });
}
