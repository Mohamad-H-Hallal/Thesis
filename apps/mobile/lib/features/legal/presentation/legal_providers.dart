import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/providers.dart';
import '../../../core/pagination/paginated_list_controller.dart';
import '../data/api_legal_repository.dart';
import '../domain/legal_models.dart';
import '../domain/legal_repository.dart';

final legalRepositoryProvider = Provider<LegalRepository>(
  (ref) => ApiLegalRepository(
    ref.watch(apiClientProvider),
    ref.watch(secureStorageProvider),
  ),
);

final legalDocumentProvider = FutureProvider.family<LegalDocument, String>(
  (ref, slug) => ref.watch(legalRepositoryProvider).fetchDocument(slug),
);

final legalAcceptanceStatusProvider = FutureProvider<LegalAcceptanceStatus>(
  (ref) => ref.watch(legalRepositoryProvider).fetchAcceptanceStatus(),
);

final privacyRequestsProvider = FutureProvider<List<PrivacyRequestRecord>>((
  ref,
) {
  final userId = ref.watch(
    authControllerProvider.select((state) => state.session?.user.id ?? ''),
  );
  if (userId.isNotEmpty) {
    watchRealtimeScope(ref, RealtimeScope('privacy_requests', userId));
  }
  return ref.watch(legalRepositoryProvider).fetchMyPrivacyRequests();
});

final personalDataExportLocalPathProvider = FutureProvider.autoDispose
    .family<String?, String>(
      (ref, requestId) => ref
          .watch(legalRepositoryProvider)
          .fetchPersonalDataExportLocalPath(requestId),
    );

final myContentReportsProvider = FutureProvider<List<ContentReportRecord>>((
  ref,
) {
  final userId = ref.watch(
    authControllerProvider.select((state) => state.session?.user.id ?? ''),
  );
  if (userId.isNotEmpty) {
    watchRealtimeScope(ref, RealtimeScope('content_reports', userId));
  }
  return ref.watch(legalRepositoryProvider).fetchMyContentReports();
});

class PrivacyAdminQuery {
  const PrivacyAdminQuery({this.status, this.requestType, this.query});

  final String? status;
  final String? requestType;
  final String? query;

  @override
  bool operator ==(Object other) =>
      other is PrivacyAdminQuery &&
      other.status == status &&
      other.requestType == requestType &&
      other.query == query;

  @override
  int get hashCode => Object.hash(status, requestType, query);
}

class ContentReportAdminQuery {
  const ContentReportAdminQuery({this.status, this.entityType, this.query});

  final String? status;
  final String? entityType;
  final String? query;

  @override
  bool operator ==(Object other) =>
      other is ContentReportAdminQuery &&
      other.status == status &&
      other.entityType == entityType &&
      other.query == query;

  @override
  int get hashCode => Object.hash(status, entityType, query);
}

final paginatedPrivacyAdminRequestsProvider = StateNotifierProvider.autoDispose
    .family<
      PaginatedListController<PrivacyAdminRequest>,
      AsyncValue<PaginatedListState<PrivacyAdminRequest>>,
      PrivacyAdminQuery
    >((ref, filter) {
      ref.watch(
        authControllerProvider.select((state) => state.session?.user.id),
      );
      const scope = RealtimeScope('privacy_admin_queue', 'all');
      return bindRealtimePaginated(
        ref,
        scope,
        PaginatedListController<PrivacyAdminRequest>(
          loadPage: ({required page, required limit}) => ref
              .read(legalRepositoryProvider)
              .fetchPrivacyAdminRequests(
                page: page,
                limit: limit,
                status: filter.status,
                requestType: filter.requestType,
                query: filter.query,
              ),
        ),
      );
    });

final paginatedContentReportsAdminProvider = StateNotifierProvider.autoDispose
    .family<
      PaginatedListController<ContentReportRecord>,
      AsyncValue<PaginatedListState<ContentReportRecord>>,
      ContentReportAdminQuery
    >((ref, filter) {
      ref.watch(
        authControllerProvider.select((state) => state.session?.user.id),
      );
      const scope = RealtimeScope('moderation_admin_queue', 'all');
      return bindRealtimePaginated(
        ref,
        scope,
        PaginatedListController<ContentReportRecord>(
          loadPage: ({required page, required limit}) => ref
              .read(legalRepositoryProvider)
              .fetchContentReportsForAdmin(
                page: page,
                limit: limit,
                status: filter.status,
                entityType: filter.entityType,
                query: filter.query,
              ),
        ),
      );
    });

final privacyQueueCountsProvider = FutureProvider<PrivacyQueueCounts>((ref) {
  watchRealtimeScope(ref, const RealtimeScope('privacy_admin_queue', 'all'));
  watchRealtimeScope(ref, const RealtimeScope('moderation_admin_queue', 'all'));
  return ref.watch(legalRepositoryProvider).fetchPrivacyQueueCounts();
});
