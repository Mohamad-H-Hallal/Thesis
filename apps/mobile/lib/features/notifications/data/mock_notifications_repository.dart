import '../domain/app_notification.dart';
import '../domain/notifications_repository.dart';

class MockNotificationsRepository implements NotificationsRepository {
  @override
  Future<List<AppNotification>> fetchNotifications() async {
    await Future<void>.delayed(const Duration(milliseconds: 480));

    return const [
      AppNotification(
        id: 'n1',
        title: 'Assignment approved',
        message: 'You were assigned to Bekaa Orchard Census 2026.',
        timestamp: '5m ago',
        isRead: false,
      ),
      AppNotification(
        id: 'n2',
        title: 'Review completed',
        message: 'Feature #D-208 was approved by reviewer.',
        timestamp: '2h ago',
        isRead: false,
      ),
      AppNotification(
        id: 'n3',
        title: 'Sync reminder',
        message: '3 offline drafts pending sync.',
        timestamp: 'Yesterday',
        isRead: true,
      ),
    ];
  }
}
