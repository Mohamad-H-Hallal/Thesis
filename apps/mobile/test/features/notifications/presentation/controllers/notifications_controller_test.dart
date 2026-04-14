import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lebanese_gis_mobile/features/notifications/domain/app_notification.dart';
import 'package:lebanese_gis_mobile/features/notifications/domain/notifications_repository.dart';
import 'package:lebanese_gis_mobile/features/notifications/presentation/controllers/notifications_controller.dart';

class _FakeNotificationsRepository implements NotificationsRepository {
  _FakeNotificationsRepository(this._items);

  final List<AppNotification> _items;
  final List<String> readIds = <String>[];
  final List<String> unreadIds = <String>[];
  bool markAllInvoked = false;

  @override
  Future<NotificationPage> fetchNotifications({
    int page = 1,
    int limit = 20,
  }) async {
    final start = (page - 1) * limit;
    final end = start + limit > _items.length ? _items.length : start + limit;
    final items = start >= _items.length
        ? const <AppNotification>[]
        : _items.sublist(start, end);
    return NotificationPage(
      items: items,
      page: page,
      limit: limit,
      total: _items.length,
      hasMore: end < _items.length,
    );
  }

  @override
  Future<void> markAllAsRead() async {
    markAllInvoked = true;
  }

  @override
  Future<void> markAsRead(String notificationId) async {
    readIds.add(notificationId);
  }

  @override
  Future<void> markAsUnread(String notificationId) async {
    unreadIds.add(notificationId);
  }
}

List<AppNotification> _buildNotifications(int count) {
  return List<AppNotification>.generate(
    count,
    (index) => AppNotification(
      id: 'n$index',
      title: 'Notification $index',
      message: 'Message $index',
      timestamp: '${index + 1}m ago',
      isRead: index.isEven,
    ),
    growable: false,
  );
}

NotificationsViewState _currentValue(NotificationsController controller) {
  final state = controller.state;
  expect(state, isA<AsyncData<NotificationsViewState>>());
  return (state as AsyncData<NotificationsViewState>).value;
}

void main() {
  test('loads the first notification page and appends the next one', () async {
    final repository = _FakeNotificationsRepository(_buildNotifications(45));
    final controller = NotificationsController.empty(repository);

    await controller.load();
    expect(_currentValue(controller).items, hasLength(20));
    expect(_currentValue(controller).hasMore, isTrue);
    expect(_currentValue(controller).page, 1);

    await controller.loadMore();
    expect(_currentValue(controller).items, hasLength(40));
    expect(_currentValue(controller).page, 2);
    expect(_currentValue(controller).hasMore, isTrue);

    await controller.loadMore();
    expect(_currentValue(controller).items, hasLength(45));
    expect(_currentValue(controller).page, 3);
    expect(_currentValue(controller).hasMore, isFalse);
  });

  test('marks notifications as read and unread in local state', () async {
    final repository = _FakeNotificationsRepository(_buildNotifications(5));
    final controller = NotificationsController.empty(repository);

    await controller.load();
    await controller.markAsUnread('n0');
    expect(_currentValue(controller).items.first.isRead, isFalse);
    expect(repository.unreadIds, contains('n0'));

    await controller.markAsRead('n1');
    expect(
      _currentValue(
        controller,
      ).items.firstWhere((item) => item.id == 'n1').isRead,
      isTrue,
    );
    expect(repository.readIds, contains('n1'));

    await controller.markAllAsRead();
    expect(
      _currentValue(controller).items.every((item) => item.isRead),
      isTrue,
    );
    expect(repository.markAllInvoked, isTrue);
  });
}
