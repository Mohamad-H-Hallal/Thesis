import 'package:dio/dio.dart';

import '../../../core/config/app_env.dart';
import '../../../core/network/api_error_message.dart';
import '../../../core/network/api_client.dart';
import '../../../core/utils/lebanon_time.dart';
import '../domain/app_notification.dart';
import '../domain/notifications_repository.dart';

class ApiNotificationsRepository implements NotificationsRepository {
  ApiNotificationsRepository(this._apiClient);

  final ApiClient _apiClient;

  String get _notificationsBasePath =>
      '${AppEnv.apiVersionPrefix}/notifications';

  @override
  Future<NotificationPage> fetchNotifications({
    int page = 1,
    int limit = 20,
    bool? isRead,
  }) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        _notificationsBasePath,
        queryParameters: <String, dynamic>{
          'page': page,
          'limit': limit,
          ...?isRead == null ? null : <String, dynamic>{'is_read': isRead},
        },
      );
      final payload = response.data ?? const <String, dynamic>{};
      final rows = (payload['data'] as List? ?? const <dynamic>[]);
      final pagination = Map<String, dynamic>.from(
        payload['pagination'] as Map? ?? const <String, dynamic>{},
      );

      final items = rows
          .map((row) {
            final map = Map<String, dynamic>.from(row as Map);
            final createdAtRaw = map['created_at'] as String?;
            final timestamp = createdAtRaw == null
                ? 'just now'
                : _relativeTimestamp(DateTime.tryParse(createdAtRaw));

            return AppNotification(
              id: (map['id'] as String?) ?? '',
              title: (map['title'] as String?) ?? 'Notification',
              message: (map['message'] as String?) ?? '',
              timestamp: timestamp,
              isRead: (map['is_read'] as bool?) ?? false,
            );
          })
          .toList(growable: false);

      final total = (pagination['total'] as num?)?.toInt() ?? items.length;
      final hasMore =
          (pagination['has_more'] as bool?) ??
          ((page * limit) < total && items.isNotEmpty);

      return NotificationPage(
        items: items,
        page: (pagination['page'] as num?)?.toInt() ?? page,
        limit: (pagination['limit'] as num?)?.toInt() ?? limit,
        total: total,
        hasMore: hasMore,
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load notifications right now. Please try again.',
      );
    }
  }

  @override
  Future<int> fetchUnreadCount() async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_notificationsBasePath/unread/count',
      );
      final data = Map<String, dynamic>.from(
        response.data?['data'] as Map? ?? const <String, dynamic>{},
      );
      final raw = data['unread_count'] ?? data['count'];
      if (raw is int) {
        return raw;
      }
      if (raw is num) {
        return raw.toInt();
      }
      if (raw is String) {
        return int.tryParse(raw) ?? 0;
      }
      return 0;
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load unread notification count right now.',
      );
    }
  }

  @override
  Future<void> markAsRead(String notificationId) async {
    try {
      await _apiClient.dio.put<void>(
        '$_notificationsBasePath/$notificationId/read',
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to update this notification right now.',
      );
    }
  }

  @override
  Future<void> markAsUnread(String notificationId) async {
    try {
      await _apiClient.dio.put<void>(
        '$_notificationsBasePath/$notificationId/unread',
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to update this notification right now.',
      );
    }
  }

  @override
  Future<void> markAllAsRead() async {
    try {
      await _apiClient.dio.put<void>('$_notificationsBasePath/read-all');
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to update notifications right now.',
      );
    }
  }

  @override
  Future<void> registerDeviceToken({
    required String token,
    required String platform,
    String? deviceLabel,
    String? appVersion,
    bool showSensitivePreview = false,
  }) async {
    try {
      await _apiClient.dio.post<void>(
        '$_notificationsBasePath/devices/register',
        data: <String, dynamic>{
          'token': token,
          'platform': platform,
          if (deviceLabel != null && deviceLabel.trim().isNotEmpty)
            'device_label': deviceLabel.trim(),
          if (appVersion != null && appVersion.trim().isNotEmpty)
            'app_version': appVersion.trim(),
          'show_sensitive_preview': showSensitivePreview,
        },
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback:
            'Unable to enable push notifications on this device right now.',
      );
    }
  }

  @override
  Future<void> unregisterDeviceToken(String token) async {
    try {
      await _apiClient.dio.post<void>(
        '$_notificationsBasePath/devices/unregister',
        data: <String, dynamic>{'token': token},
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback:
            'Unable to disable push notifications on this device right now.',
      );
    }
  }

  String _relativeTimestamp(DateTime? value) {
    if (value == null) {
      return 'just now';
    }
    final now = DateTime.now().toUtc();
    final diff = now.difference(value.toUtc());
    if (diff.inMinutes < 1) {
      return 'just now';
    }
    if (diff.inHours < 1) {
      return '${diff.inMinutes}m ago';
    }
    if (diff.inDays < 1) {
      return '${diff.inHours}h ago';
    }
    if (diff.inDays < 7) {
      return '${diff.inDays}d ago';
    }
    return formatLebanonDate(value);
  }
}
