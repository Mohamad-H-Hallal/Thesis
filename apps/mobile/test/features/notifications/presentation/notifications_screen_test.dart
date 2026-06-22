import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/providers/providers.dart';
import 'package:lebanese_gis_mobile/features/notifications/domain/app_notification.dart';
import 'package:lebanese_gis_mobile/features/notifications/domain/notifications_repository.dart';
import 'package:lebanese_gis_mobile/features/notifications/presentation/controllers/notifications_controller.dart';
import 'package:lebanese_gis_mobile/features/notifications/presentation/screens/notifications_screen.dart';

class _FakeNotificationsRepository implements NotificationsRepository {
  _FakeNotificationsRepository(this._items);

  final List<AppNotification> _items;

  @override
  Future<NotificationPage> fetchNotifications({
    int page = 1,
    int limit = 20,
    bool? isRead,
  }) async {
    final filtered = isRead == null
        ? _items
        : _items.where((item) => item.isRead == isRead).toList();
    return NotificationPage(
      items: filtered,
      page: page,
      limit: limit,
      total: filtered.length,
      hasMore: false,
    );
  }

  @override
  Future<int> fetchUnreadCount() async =>
      _items.where((item) => !item.isRead).length;

  @override
  Future<void> markAllAsRead() async {}

  @override
  Future<void> markAsRead(String notificationId) async {}

  @override
  Future<void> markAsUnread(String notificationId) async {}

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

void main() {
  testWidgets('notification action buttons align across card content lengths', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final repository = _FakeNotificationsRepository(const <AppNotification>[
      AppNotification(
        id: 'n1',
        title: 'Export ready for download',
        message: 'Rivers export (SHAPEFILE) is ready for download.',
        timestamp: '6h ago',
        isRead: false,
      ),
      AppNotification(
        id: 'n2',
        title: 'GIS import submitted',
        message:
            'Ali Ali submitted LUC_ROI_Raw_v2.zip for South Lebanon Fruit Trees Training Dataset. The file is processing before review.',
        timestamp: '2026-06-01',
        isRead: false,
      ),
    ]);
    final controller = NotificationsController.empty(repository);
    await controller.load();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notificationsControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(home: Scaffold(body: NotificationsScreen())),
      ),
    );
    await tester.pumpAndSettle();

    final buttons = find.widgetWithText(OutlinedButton, 'Mark read');
    expect(buttons, findsNWidgets(2));

    final firstX = tester.getTopLeft(buttons.at(0)).dx;
    final secondX = tester.getTopLeft(buttons.at(1)).dx;
    expect(secondX, closeTo(firstX, 0.5));
  });
}
