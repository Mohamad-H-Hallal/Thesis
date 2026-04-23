import 'package:file_picker/file_picker.dart';

import 'import_models.dart';

abstract class ImportsRepository {
  Future<List<GisImportJob>> fetchImports({
    String? status,
    String? projectId,
  });

  Future<GisImportJob> uploadImport({
    required String projectId,
    required PlatformFile file,
  });

  Future<GisImportDetails> fetchImportDetails(String importId);

  Future<List<ImportedFeature>> fetchImportFeatures({
    required String importId,
    String? status,
    int page = 1,
    int limit = 100,
  });

  Future<GisImportJob> reviewImport({
    required String importId,
    required String status,
    String? reason,
    List<String>? featureIds,
  });
}
