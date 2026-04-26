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
    bool? isRead,
  }) async {
    final filtered = isRead == null
        ? _items
        : _items.where((item) => item.isRead == isRead).toList(growable: false);
    final start = (page - 1) * limit;
    final end = start + limit > filtered.length ? filtered.length : start + limit;
    final items = start >= filtered.length
        ? const <AppNotification>[]
        : filtered.sublist(start, end);
    return NotificationPage(
      items: items,
      page: page,
      limit: limit,
      total: filtered.length,
      hasMore: end < filtered.length,
    );
  }

  @override
  Future<int> fetchUnreadCount() async =>
      _items.where((item) => !item.isRead).length;

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

  @override
  Future<void> registerDeviceToken({
    required String token,
    required String platform,
    String? deviceLabel,
    String? appVersion,
  }) async {}

  @override
  Future<void> unregisterDeviceToken(String token) async {}
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

  test('removes notifications from filtered views when read state changes', () async {
    final repository = _FakeNotificationsRepository(_buildNotifications(6));
    final controller = NotificationsController.empty(repository);

    await controller.load(isReadFilter: false);
    expect(_currentValue(controller).total, 3);

    await controller.markAsRead('n1');
    expect(_currentValue(controller).total, 2);
    expect(
      _currentValue(controller).items.any((item) => item.id == 'n1'),
      isFalse,
    );

    await controller.load(isReadFilter: true);
    expect(_currentValue(controller).total, 3);

    await controller.markAsUnread('n0');
    expect(_currentValue(controller).total, 2);
    expect(
      _currentValue(controller).items.any((item) => item.id == 'n0'),
      isFalse,
    );
  });

  test('mark all as read clears the unread filtered view', () async {
    final repository = _FakeNotificationsRepository(_buildNotifications(5));
    final controller = NotificationsController.empty(repository);

    await controller.load(isReadFilter: false);
    expect(_currentValue(controller).items, isNotEmpty);

    await controller.markAllAsRead();

    expect(_currentValue(controller).items, isEmpty);
    expect(_currentValue(controller).total, 0);
    expect(_currentValue(controller).unreadCount, 0);
    expect(repository.markAllInvoked, isTrue);
  });
}
