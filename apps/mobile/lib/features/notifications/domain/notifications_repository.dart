import 'app_notification.dart';

abstract class NotificationsRepository {
  Future<List<AppNotification>> fetchNotifications();
}
