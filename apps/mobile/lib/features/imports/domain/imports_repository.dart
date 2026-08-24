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
    ImportSourceProvenance? provenance,
  });

  Future<GisImportDetails> fetchImportDetails(String importId);

  Future<GisImportJob> updateImportProvenance({
    required String importId,
    required ImportSourceProvenance provenance,
  });

  Future<ImportMapData> fetchImportMapData({
    required String importId,
    required String projectId,
    required double minLon,
    required double minLat,
    required double maxLon,
    required double maxLat,
    required double zoom,
    int cacheRevision = 0,
  });

  Future<ImportQuickMapPreview> fetchImportQuickMapPreview({
    required String importId,
  });

  Future<ImportedFeature> fetchImportFeatureById({
    required String importId,
    required String featureId,
  });

  Future<List<ImportComment>> fetchImportComments(String importId);

  Future<List<ImportedFeature>> fetchImportFeatures({
    required String importId,
    String? status,
    String? issue,
    int page = 1,
    int limit = 100,
  });

  Future<PaginatedResult<ImportedFeature>> fetchImportFeaturesPage({
    required String importId,
    String? status,
    String? issue,
    String? search,
    String? geometryType,
    String? featureType,
    int page = 1,
    int limit = 20,
  });

  Future<GisImportJob> reviewImport({
    required String importId,
    required String status,
    String? reason,
    List<String>? featureIds,
    String? filterStatus,
    String? filterIssue,
    String? filterSearch,
    String? filterGeometryType,
    String? filterFeatureType,
  });

  Future<ImportComment> addImportComment({
    required String importId,
    required String comment,
    String? featureId,
  });

  Future<String> downloadImport(String importId);
}
