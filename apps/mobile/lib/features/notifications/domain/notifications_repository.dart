import 'app_notification.dart';

class NotificationPage {
  const NotificationPage({
    required this.items,
    required this.page,
    required this.limit,
    required this.total,
    required this.hasMore,
  });

  final List<AppNotification> items;
  final int page;
  final int limit;
  final int total;
  final bool hasMore;
}

abstract class NotificationsRepository {
  Future<NotificationPage> fetchNotifications({int page = 1, int limit = 20});

  Future<void> markAsRead(String notificationId);

  Future<void> markAsUnread(String notificationId);

  Future<void> markAllAsRead();
}
