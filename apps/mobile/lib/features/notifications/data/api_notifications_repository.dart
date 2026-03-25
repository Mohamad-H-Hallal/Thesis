import '../../../core/config/app_env.dart';
import '../../../core/network/api_client.dart';
import '../domain/app_notification.dart';
import '../domain/notifications_repository.dart';

class ApiNotificationsRepository implements NotificationsRepository {
  ApiNotificationsRepository(this._apiClient);

  final ApiClient _apiClient;

  String get _notificationsBasePath => '${AppEnv.apiVersionPrefix}/notifications';

  @override
  Future<List<AppNotification>> fetchNotifications() async {
    final response = await _apiClient.dio.get<Map<String, dynamic>>(_notificationsBasePath);
    final payload = response.data ?? const <String, dynamic>{};
    final rows = (payload['data'] as List? ?? const <dynamic>[]);

    return rows.map((row) {
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
    }).toList(growable: false);
  }

  @override
  Future<void> markAsRead(String notificationId) async {
    await _apiClient.dio.put<void>('$_notificationsBasePath/$notificationId/read');
  }

  @override
  Future<void> markAllAsRead() async {
    await _apiClient.dio.put<void>('$_notificationsBasePath/read-all');
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
    return '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
  }
}
