import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../domain/app_notification.dart';
import '../../domain/notifications_repository.dart';

class NotificationsController
    extends StateNotifier<AsyncValue<List<AppNotification>>> {
  NotificationsController(this._repository) : super(const AsyncLoading()) {
    load();
  }

  NotificationsController.empty(this._repository)
    : super(const AsyncData(<AppNotification>[]));

  final NotificationsRepository _repository;
  final Uuid _uuid = const Uuid();

  Future<void> load() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_repository.fetchNotifications);
  }

  Future<void> markAsRead(String id) async {
    final currentItems = state.valueOrNull;
    if (currentItems == null) {
      await load();
      return;
    }

    final alreadyRead = currentItems.any(
      (item) => item.id == id && item.isRead,
    );
    if (alreadyRead) {
      return;
    }

    state = AsyncData(
      currentItems
          .map(
            (item) => item.id == id ? item.copyWith(isRead: true) : item,
          )
          .toList(growable: false),
    );

    try {
      await _repository.markAsRead(id);
    } catch (_) {
      await load();
    }
  }

  Future<void> markAsUnread(String id) async {
    final currentItems = state.valueOrNull;
    if (currentItems == null) {
      await load();
      return;
    }

    final alreadyUnread = currentItems.any(
      (item) => item.id == id && !item.isRead,
    );
    if (alreadyUnread) {
      return;
    }

    state = AsyncData(
      currentItems
          .map(
            (item) => item.id == id ? item.copyWith(isRead: false) : item,
          )
          .toList(growable: false),
    );

    try {
      await _repository.markAsUnread(id);
    } catch (_) {
      await load();
    }
  }

  Future<void> markAllAsRead() async {
    final currentItems = state.valueOrNull;
    if (currentItems == null || currentItems.every((item) => item.isRead)) {
      return;
    }

    state = AsyncData(
      currentItems
          .map((item) => item.copyWith(isRead: true))
          .toList(growable: false),
    );

    try {
      await _repository.markAllAsRead();
    } catch (_) {
      await load();
    }
  }

  void pushNotification({required String title, required String message}) {
    final notification = AppNotification(
      id: _uuid.v4(),
      title: title,
      message: message,
      timestamp: 'just now',
      isRead: false,
    );

    state = state.when(
      data: (items) => AsyncData(<AppNotification>[notification, ...items]),
      loading: () => AsyncData(<AppNotification>[notification]),
      error: (_, stackTrace) => AsyncData(<AppNotification>[notification]),
    );
  }
}
