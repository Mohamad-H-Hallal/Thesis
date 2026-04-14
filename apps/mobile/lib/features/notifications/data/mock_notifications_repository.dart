import '../domain/app_notification.dart';
import '../domain/notifications_repository.dart';

class MockNotificationsRepository implements NotificationsRepository {
  static const List<AppNotification> _items = <AppNotification>[
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
      message: 'Feature #D-208 was approved by admin review.',
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
    AppNotification(
      id: 'n4',
      title: 'Export ready',
      message: 'Fruit trees export is ready to download.',
      timestamp: '2026-04-11',
      isRead: true,
    ),
    AppNotification(
      id: 'n5',
      title: 'Project starts tomorrow',
      message: 'Spring census starts tomorrow.',
      timestamp: '2026-04-10',
      isRead: false,
    ),
  ];

  @override
  Future<NotificationPage> fetchNotifications({
    int page = 1,
    int limit = 20,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 480));

    final start = (page - 1) * limit;
    final end = (start + limit).clamp(0, _items.length);
    final pageItems = start >= _items.length
        ? const <AppNotification>[]
        : _items.sublist(start, end);

    return NotificationPage(
      items: pageItems,
      page: page,
      limit: limit,
      total: _items.length,
      hasMore: end < _items.length,
    );
  }

  @override
  Future<void> markAsRead(String notificationId) async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }

  @override
  Future<void> markAsUnread(String notificationId) async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }

  @override
  Future<void> markAllAsRead() async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }
}
