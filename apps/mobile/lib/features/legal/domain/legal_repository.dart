import 'legal_models.dart';
import '../../../core/pagination/paginated_result.dart';

abstract class LegalRepository {
  Future<List<LegalDocument>> fetchDocuments({String locale = 'en'});

  Future<LegalDocument> fetchDocument(
    String slug, {
    String locale = 'en',
    String? version,
  });

  Future<LegalAcceptanceStatus> fetchAcceptanceStatus();

  Future<void> acceptCurrentDocuments(List<LegalDocument> documents);

  Future<void> reportContent({
    required String projectId,
    required String entityType,
    required String entityId,
    required String reasonCode,
    String? description,
  });

  Future<List<PrivacyRequestRecord>> fetchMyPrivacyRequests();

  Future<AccountDeletionEligibility> fetchAccountDeletionEligibility();

  Future<PrivacyRequestRecord> createPrivacyRequest({
    required PrivacyRequestType type,
    String? currentPassword,
    Map<String, dynamic>? details,
  });

  Future<PrivacyRequestRecord> cancelPrivacyRequest(String requestId);

  Future<String> downloadPersonalDataExport({
    required String requestId,
    required String currentPassword,
  }) => throw UnsupportedError('Personal-data download is not available.');

  Future<String?> fetchPersonalDataExportLocalPath(String requestId) async =>
      null;

  Future<PaginatedResult<PrivacyAdminRequest>> fetchPrivacyAdminRequests({
    required int page,
    required int limit,
    String? status,
    String? requestType,
    String? query,
  }) => throw UnsupportedError('Privacy administration is not available.');

  Future<PrivacyAdminRequestDetail> fetchPrivacyAdminRequest(
    String requestId,
  ) => throw UnsupportedError('Privacy administration is not available.');

  Future<PrivacyAdminRequest> updatePrivacyAdminRequest({
    required String requestId,
    required String status,
    String? userMessage,
    String? unfinishedWorkDecision,
    String? responsibilityDecision,
  }) => throw UnsupportedError('Privacy administration is not available.');

  Future<PaginatedResult<ContentReportRecord>> fetchContentReportsForAdmin({
    required int page,
    required int limit,
    String? status,
    String? entityType,
    String? query,
  }) => throw UnsupportedError('Moderation administration is not available.');

  Future<ContentReportDetail> fetchContentReportForAdmin(String reportId) =>
      throw UnsupportedError('Moderation administration is not available.');

  Future<ContentReportRecord> updateContentReportForAdmin({
    required String reportId,
    required String status,
    String? outcomeCode,
    String? userMessage,
  }) => throw UnsupportedError('Moderation administration is not available.');

  Future<PrivacyQueueCounts> fetchPrivacyQueueCounts() =>
      throw UnsupportedError('Privacy administration is not available.');

  Future<List<ContentReportRecord>> fetchMyContentReports() =>
      Future<List<ContentReportRecord>>.value(const <ContentReportRecord>[]);
}
