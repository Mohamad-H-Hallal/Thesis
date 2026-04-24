import 'package:file_picker/file_picker.dart';

import '../../../core/pagination/paginated_result.dart';
import 'import_models.dart';

abstract class ImportsRepository {
  Future<List<GisImportJob>> fetchImports({
    String? status,
    String? projectId,
    String? categoryId,
  });

  Future<PaginatedResult<GisImportJob>> fetchImportsPage({
    String? status,
    String? projectId,
    String? categoryId,
    int page = 1,
    int limit = 20,
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

  Future<PaginatedResult<ImportedFeature>> fetchImportFeaturesPage({
    required String importId,
    String? status,
    int page = 1,
    int limit = 20,
  });

  Future<GisImportJob> reviewImport({
    required String importId,
    required String status,
    String? reason,
    List<String>? featureIds,
  });
}
