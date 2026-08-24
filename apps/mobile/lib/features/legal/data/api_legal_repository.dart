import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;

import '../../../core/config/app_env.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_error_message.dart';
import '../../../core/pagination/paginated_result.dart';
import '../../../core/platform/downloaded_file_saver.dart';
import '../domain/legal_models.dart';
import '../domain/legal_repository.dart';

class ApiLegalRepository extends LegalRepository {
  ApiLegalRepository(this._apiClient, this._secureStorage);

  final ApiClient _apiClient;
  final FlutterSecureStorage _secureStorage;

  String get _legalPath => '${AppEnv.apiVersionPrefix}/legal';
  String get _privacyPath => '${AppEnv.apiVersionPrefix}/privacy';
  String _personalExportPathKey(String requestId) =>
      'privacy_export_local_path_$requestId';

  @override
  Future<List<LegalDocument>> fetchDocuments({String locale = 'en'}) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_legalPath/documents',
        queryParameters: <String, dynamic>{'format': 'json', 'locale': locale},
        options: Options(
          headers: const <String, dynamic>{'Authorization': null},
        ),
      );
      final data = Map<String, dynamic>.from(
        response.data?['data'] as Map? ?? const <String, dynamic>{},
      );
      return (data['documents'] as List? ?? const <dynamic>[])
          .whereType<Map>()
          .map(
            (item) => LegalDocument.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(growable: false);
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Legal information is temporarily unavailable.',
      );
    }
  }

  @override
  Future<LegalDocument> fetchDocument(
    String slug, {
    String locale = 'en',
    String? version,
  }) async {
    try {
      final versionPath = version == null
          ? '$_legalPath/documents/$slug'
          : '$_legalPath/documents/$slug/versions/$version';
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        versionPath,
        queryParameters: <String, dynamic>{'format': 'json', 'locale': locale},
        options: Options(
          headers: const <String, dynamic>{'Authorization': null},
        ),
      );
      final data = Map<String, dynamic>.from(
        response.data?['data'] as Map? ?? const <String, dynamic>{},
      );
      return LegalDocument.fromJson(
        Map<String, dynamic>.from(
          data['document'] as Map? ?? const <String, dynamic>{},
        ),
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Legal information is temporarily unavailable.',
      );
    }
  }

  @override
  Future<LegalAcceptanceStatus> fetchAcceptanceStatus() async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_legalPath/acceptance/status',
      );
      return LegalAcceptanceStatus.fromJson(
        Map<String, dynamic>.from(
          response.data?['data'] as Map? ?? const <String, dynamic>{},
        ),
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to verify the current Terms acceptance.',
      );
    }
  }

  @override
  Future<void> acceptCurrentDocuments(List<LegalDocument> documents) async {
    try {
      await _apiClient.dio.post<Map<String, dynamic>>(
        '$_legalPath/acceptance',
        data: <String, dynamic>{
          'acceptances': documents
              .map(
                (document) => <String, dynamic>{
                  'document_type': document.type,
                  'version': document.version,
                  'locale': document.locale,
                  'affirmative': true,
                },
              )
              .toList(growable: false),
        },
      );
      await _secureStorage.write(
        key: 'legal_acceptance_required',
        value: 'false',
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to record the current Terms acceptance.',
      );
    }
  }

  @override
  Future<void> reportContent({
    required String projectId,
    required String entityType,
    required String entityId,
    required String reasonCode,
    String? description,
  }) async {
    try {
      await _apiClient.dio.post<Map<String, dynamic>>(
        '$_privacyPath/content-reports',
        data: <String, dynamic>{
          'project_id': projectId,
          'entity_type': entityType,
          'entity_id': entityId,
          'reason_code': reasonCode,
          if (description?.trim().isNotEmpty ?? false)
            'description': description!.trim(),
        },
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to submit this content report.',
      );
    }
  }

  @override
  Future<List<PrivacyRequestRecord>> fetchMyPrivacyRequests() async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_privacyPath/requests',
      );
      return (response.data?['data'] as List? ?? const <dynamic>[])
          .whereType<Map>()
          .map(
            (item) =>
                PrivacyRequestRecord.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(growable: false);
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load privacy requests.',
      );
    }
  }

  @override
  Future<AccountDeletionEligibility> fetchAccountDeletionEligibility() async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_privacyPath/account-deletion/eligibility',
      );
      return AccountDeletionEligibility.fromJson(
        Map<String, dynamic>.from(
          response.data?['data'] as Map? ?? const <String, dynamic>{},
        ),
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to check account-deletion requirements.',
      );
    }
  }

  @override
  Future<PrivacyRequestRecord> createPrivacyRequest({
    required PrivacyRequestType type,
    String? currentPassword,
    Map<String, dynamic>? details,
  }) async {
    try {
      final normalizedDetails = details?.isNotEmpty == true ? details : null;
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_privacyPath/requests',
        data: <String, dynamic>{
          'request_type': type.apiValue,
          'current_password': ?currentPassword,
          'details': ?normalizedDetails,
        },
      );
      return PrivacyRequestRecord.fromJson(
        Map<String, dynamic>.from(
          response.data?['data'] as Map? ?? const <String, dynamic>{},
        ),
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to submit the privacy request.',
      );
    }
  }

  @override
  Future<PrivacyRequestRecord> cancelPrivacyRequest(String requestId) async {
    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_privacyPath/requests/$requestId/cancel',
      );
      return PrivacyRequestRecord.fromJson(
        Map<String, dynamic>.from(
          response.data?['data'] as Map? ?? const <String, dynamic>{},
        ),
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to cancel the privacy request.',
      );
    }
  }

  @override
  Future<String> downloadPersonalDataExport({
    required String requestId,
    required String currentPassword,
  }) async {
    try {
      final grantResponse = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_privacyPath/requests/$requestId/export-grant',
        data: <String, dynamic>{'current_password': currentPassword},
      );
      final grant = Map<String, dynamic>.from(
        grantResponse.data?['data'] as Map? ?? const <String, dynamic>{},
      );
      final path = grant['download_path'] as String? ?? '';
      final token = grant['grant_token'] as String? ?? '';
      if (path.isEmpty || token.isEmpty) {
        throw StateError('The secure download link is unavailable.');
      }
      final response = await _apiClient.dio.get<List<int>>(
        path,
        options: Options(
          responseType: ResponseType.bytes,
          headers: <String, dynamic>{'X-Privacy-Export-Grant': token},
        ),
      );
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) {
        throw StateError('The downloaded export is empty.');
      }
      final contentType = response.headers.value('content-type') ?? '';
      final disposition = response.headers.value('content-disposition') ?? '';
      final headerName = RegExp(
        'filename="?([^";]+)"?',
        caseSensitive: false,
      ).firstMatch(disposition)?.group(1);
      final fallbackName =
          'terraleb-personal-data-$requestId.${contentType.contains('text/html') ? 'html' : 'json'}';
      final candidateName = p.basename(headerName?.trim() ?? fallbackName);
      final fileName = RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(candidateName)
          ? candidateName
          : fallbackName;
      final savedPath = await saveDownloadedBytes(
        bytes: bytes,
        fileName: fileName,
        directoryName: 'TerraLeb/Privacy exports',
      );
      if (savedPath.isNotEmpty) {
        await _secureStorage.write(
          key: _personalExportPathKey(requestId),
          value: savedPath,
        );
      }
      return savedPath;
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to download your personal-data export.',
      );
    }
  }

  @override
  Future<String?> fetchPersonalDataExportLocalPath(String requestId) =>
      _secureStorage.read(key: _personalExportPathKey(requestId));

  @override
  Future<PaginatedResult<PrivacyAdminRequest>> fetchPrivacyAdminRequests({
    required int page,
    required int limit,
    String? status,
    String? requestType,
    String? query,
  }) => _fetchAdminPage<PrivacyAdminRequest>(
    path: '$_privacyPath/admin/requests',
    page: page,
    limit: limit,
    queryParameters: <String, dynamic>{
      if (status?.isNotEmpty ?? false) 'status': status,
      if (requestType?.isNotEmpty ?? false) 'request_type': requestType,
      if (query?.isNotEmpty ?? false) 'q': query,
    },
    parser: PrivacyAdminRequest.fromJson,
    fallback: 'Unable to load privacy requests.',
  );

  @override
  Future<PrivacyAdminRequestDetail> fetchPrivacyAdminRequest(
    String requestId,
  ) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_privacyPath/admin/requests/$requestId',
      );
      final data = Map<String, dynamic>.from(
        response.data?['data'] as Map? ?? const <String, dynamic>{},
      );
      return PrivacyAdminRequestDetail(
        request: PrivacyAdminRequest.fromJson(
          Map<String, dynamic>.from(
            data['request'] as Map? ?? const <String, dynamic>{},
          ),
        ),
        history: _historyFrom(data['history']),
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load this privacy request.',
      );
    }
  }

  @override
  Future<PrivacyAdminRequest> updatePrivacyAdminRequest({
    required String requestId,
    required String status,
    String? userMessage,
  }) async {
    try {
      final response = await _apiClient.dio.patch<Map<String, dynamic>>(
        '$_privacyPath/admin/requests/$requestId',
        data: <String, dynamic>{
          'status': status,
          if (userMessage?.trim().isNotEmpty ?? false)
            'user_message': userMessage!.trim(),
        },
      );
      return PrivacyAdminRequest.fromJson(
        Map<String, dynamic>.from(
          response.data?['data'] as Map? ?? const <String, dynamic>{},
        ),
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to update this privacy request.',
      );
    }
  }

  @override
  Future<PaginatedResult<ContentReportRecord>> fetchContentReportsForAdmin({
    required int page,
    required int limit,
    String? status,
    String? entityType,
    String? query,
  }) => _fetchAdminPage<ContentReportRecord>(
    path: '$_privacyPath/admin/content-reports',
    page: page,
    limit: limit,
    queryParameters: <String, dynamic>{
      if (status?.isNotEmpty ?? false) 'status': status,
      if (entityType?.isNotEmpty ?? false) 'entity_type': entityType,
      if (query?.isNotEmpty ?? false) 'q': query,
    },
    parser: ContentReportRecord.fromJson,
    fallback: 'Unable to load content reports.',
  );

  @override
  Future<ContentReportDetail> fetchContentReportForAdmin(
    String reportId,
  ) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_privacyPath/admin/content-reports/$reportId',
      );
      final data = Map<String, dynamic>.from(
        response.data?['data'] as Map? ?? const <String, dynamic>{},
      );
      return ContentReportDetail(
        report: ContentReportRecord.fromJson(
          Map<String, dynamic>.from(
            data['report'] as Map? ?? const <String, dynamic>{},
          ),
        ),
        history: _historyFrom(data['history']),
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load this content report.',
      );
    }
  }

  @override
  Future<ContentReportRecord> updateContentReportForAdmin({
    required String reportId,
    required String status,
    String? outcomeCode,
    String? userMessage,
  }) async {
    try {
      final response = await _apiClient.dio.patch<Map<String, dynamic>>(
        '$_privacyPath/admin/content-reports/$reportId',
        data: <String, dynamic>{
          'status': status,
          if (outcomeCode?.trim().isNotEmpty ?? false)
            'outcome_code': outcomeCode!.trim(),
          if (userMessage?.trim().isNotEmpty ?? false)
            'user_message': userMessage!.trim(),
        },
      );
      return ContentReportRecord.fromJson(
        Map<String, dynamic>.from(
          response.data?['data'] as Map? ?? const <String, dynamic>{},
        ),
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to update this content report.',
      );
    }
  }

  @override
  Future<PrivacyQueueCounts> fetchPrivacyQueueCounts() async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_privacyPath/admin/queue-counts',
      );
      return PrivacyQueueCounts.fromJson(
        Map<String, dynamic>.from(
          response.data?['data'] as Map? ?? const <String, dynamic>{},
        ),
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load queue counts.',
      );
    }
  }

  @override
  Future<List<ContentReportRecord>> fetchMyContentReports() async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_privacyPath/content-reports',
      );
      return (response.data?['data'] as List? ?? const <dynamic>[])
          .whereType<Map>()
          .map(
            (item) =>
                ContentReportRecord.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(growable: false);
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load your content reports.',
      );
    }
  }

  Future<PaginatedResult<T>> _fetchAdminPage<T>({
    required String path,
    required int page,
    required int limit,
    required Map<String, dynamic> queryParameters,
    required T Function(Map<String, dynamic>) parser,
    required String fallback,
  }) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        path,
        queryParameters: <String, dynamic>{
          ...queryParameters,
          'page': page,
          'limit': limit,
        },
      );
      final pagination = Map<String, dynamic>.from(
        response.data?['pagination'] as Map? ?? const <String, dynamic>{},
      );
      return PaginatedResult<T>(
        items: (response.data?['data'] as List? ?? const <dynamic>[])
            .whereType<Map>()
            .map((item) => parser(Map<String, dynamic>.from(item)))
            .toList(growable: false),
        page: (pagination['page'] as num?)?.toInt() ?? page,
        limit: (pagination['limit'] as num?)?.toInt() ?? limit,
        total: (pagination['total'] as num?)?.toInt() ?? 0,
        hasMore: pagination['has_more'] == true,
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(error, fallback: fallback);
    }
  }

  List<WorkflowHistoryRecord> _historyFrom(Object? value) =>
      (value as List? ?? const <dynamic>[])
          .whereType<Map>()
          .map(
            (item) =>
                WorkflowHistoryRecord.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(growable: false);
}
