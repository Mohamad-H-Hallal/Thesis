import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/providers.dart';
import '../domain/import_models.dart';

final importJobsProvider =
    FutureProvider.family<List<GisImportJob>, GisImportListQuery>((
      ref,
      query,
    ) async {
      ref.watch(workflowRefreshTickProvider);
      return ref
          .read(importsRepositoryProvider)
          .fetchImports(status: query.status, projectId: query.projectId);
    });

final importDetailsProvider = FutureProvider.family<GisImportDetails, String>((
  ref,
  importId,
) async {
  ref.watch(workflowRefreshTickProvider);
  return ref.read(importsRepositoryProvider).fetchImportDetails(importId);
});
