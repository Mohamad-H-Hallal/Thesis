import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/pagination/paginated_list_controller.dart';
import '../../../core/providers/providers.dart';
import '../../auth/domain/auth_models.dart';
import '../domain/import_models.dart';

RealtimeScope importsListRealtimeScope(AuthSession? session) {
  return RealtimeScope(
    'imports',
    session?.user.role == UserRole.admin ? 'all' : (session?.user.id ?? 'none'),
  );
}

final importJobsProvider =
    FutureProvider.family<List<GisImportJob>, GisImportListQuery>((
      ref,
      query,
    ) async {
      watchRealtimeScope(
        ref,
        importsListRealtimeScope(ref.watch(authControllerProvider).session),
      );
      return ref
          .read(importsRepositoryProvider)
          .fetchImports(status: query.status, projectId: query.projectId);
    });

final importDetailsProvider = FutureProvider.autoDispose
    .family<GisImportDetails, String>((ref, importId) async {
      watchRealtimeScope(ref, RealtimeScope('import', importId));
      return ref.read(importsRepositoryProvider).fetchImportDetails(importId);
    });

final paginatedImportJobsProvider = StateNotifierProvider.autoDispose
    .family<
      PaginatedListController<GisImportJob>,
      AsyncValue<PaginatedListState<GisImportJob>>,
      GisImportListQuery
    >((ref, query) {
      final scope = importsListRealtimeScope(
        ref.watch(authControllerProvider).session,
      );
      return bindRealtimePaginated(
        ref,
        scope,
        PaginatedListController<GisImportJob>(
          loadPage: ({required page, required limit}) {
            return ref
                .read(importsRepositoryProvider)
                .fetchImportsPage(
                  status: query.status,
                  projectId: query.projectId,
                  categoryId: query.categoryId,
                  page: page,
                  limit: limit,
                );
          },
        ),
      );
    });

final paginatedImportFeaturesProvider = StateNotifierProvider.autoDispose
    .family<
      PaginatedListController<ImportedFeature>,
      AsyncValue<PaginatedListState<ImportedFeature>>,
      ImportedFeatureListQuery
    >((ref, query) {
      final scope = RealtimeScope('import', query.importId);
      return bindRealtimePaginated(
        ref,
        scope,
        PaginatedListController<ImportedFeature>(
          loadPage: ({required page, required limit}) {
            return ref
                .read(importsRepositoryProvider)
                .fetchImportFeaturesPage(
                  importId: query.importId,
                  status: query.status,
                  issue: query.issue,
                  search: query.search,
                  geometryType: query.geometryType,
                  featureType: query.featureType,
                  page: page,
                  limit: limit,
                );
          },
        ),
      );
    });

final importMapDataProvider = FutureProvider.autoDispose
    .family<ImportMapData, ImportMapQuery>((ref, query) async {
      final scope = RealtimeScope('import', query.importId);
      watchRealtimeScope(ref, scope);
      final refreshTick = ref.watch(realtimeScopeRevisionProvider(scope));
      return ref
          .read(importsRepositoryProvider)
          .fetchImportMapData(
            importId: query.importId,
            projectId: query.projectId,
            minLon: query.minLon,
            minLat: query.minLat,
            maxLon: query.maxLon,
            maxLat: query.maxLat,
            zoom: query.zoom,
            cacheRevision: refreshTick,
          );
    });

final importQuickMapPreviewProvider = FutureProvider.autoDispose
    .family<ImportQuickMapPreview, String>((ref, importId) async {
      watchRealtimeScope(ref, RealtimeScope('import', importId));
      return ref
          .read(importsRepositoryProvider)
          .fetchImportQuickMapPreview(importId: importId);
    });

final importFeatureProvider = FutureProvider.autoDispose
    .family<ImportedFeature, ImportFeatureQuery>((ref, query) async {
      watchRealtimeScope(ref, RealtimeScope('import', query.importId));
      return ref
          .read(importsRepositoryProvider)
          .fetchImportFeatureById(
            importId: query.importId,
            featureId: query.featureId,
          );
    });
