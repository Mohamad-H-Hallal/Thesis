import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../domain/app_notification.dart';
import '../../domain/notifications_repository.dart';

class NotificationsViewState {
  const NotificationsViewState({
    required this.items,
    required this.page,
    required this.pageSize,
    required this.total,
    required this.hasMore,
    required this.isLoadingMore,
  });

  const NotificationsViewState.initial()
    : items = const <AppNotification>[],
      page = 0,
      pageSize = 20,
      total = 0,
      hasMore = true,
      isLoadingMore = false;

  final List<AppNotification> items;
  final int page;
  final int pageSize;
  final int total;
  final bool hasMore;
  final bool isLoadingMore;

  NotificationsViewState copyWith({
    List<AppNotification>? items,
    int? page,
    int? pageSize,
    int? total,
    bool? hasMore,
    bool? isLoadingMore,
  }) {
    return NotificationsViewState(
      items: items ?? this.items,
      page: page ?? this.page,
      pageSize: pageSize ?? this.pageSize,
      total: total ?? this.total,
      hasMore: hasMore ?? this.hasMore,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
    );
  }
}

class NotificationsController
    extends StateNotifier<AsyncValue<NotificationsViewState>> {
  NotificationsController(this._repository) : super(const AsyncLoading()) {
    load();
  }

  NotificationsController.empty(this._repository)
    : super(const AsyncData(NotificationsViewState.initial()));

  final NotificationsRepository _repository;
  final Uuid _uuid = const Uuid();
  static const int _pageSize = 20;

  Future<void> load() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final page = await _repository.fetchNotifications(limit: _pageSize);
      return NotificationsViewState(
        items: page.items,
        page: page.page,
        pageSize: page.limit,
        total: page.total,
        hasMore: page.hasMore,
        isLoadingMore: false,
      );
    });
  }

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.isLoadingMore || !current.hasMore) {
      return;
    }

    state = AsyncData(current.copyWith(isLoadingMore: true));

    try {
      final nextPage = current.page + 1;
      final page = await _repository.fetchNotifications(
        page: nextPage,
        limit: current.pageSize,
      );
      state = AsyncData(
        current.copyWith(
          items: <AppNotification>[...current.items, ...page.items],
          page: page.page,
          pageSize: page.limit,
          total: page.total,
          hasMore: page.hasMore,
          isLoadingMore: false,
        ),
      );
    } catch (_) {
      state = AsyncData(current.copyWith(isLoadingMore: false));
    }
  }

  Future<void> markAsRead(String id) async {
    final current = state.valueOrNull;
    if (current == null) {
      await load();
      return;
    }

    final alreadyRead = current.items.any(
      (item) => item.id == id && item.isRead,
    );
    if (alreadyRead) {
      return;
    }

    state = AsyncData(
      current.copyWith(
        items: current.items
            .map((item) => item.id == id ? item.copyWith(isRead: true) : item)
            .toList(growable: false),
      ),
    );

    try {
      await _repository.markAsRead(id);
    } catch (_) {
      await load();
    }
  }

  Future<void> markAsUnread(String id) async {
    final current = state.valueOrNull;
    if (current == null) {
      await load();
      return;
    }

    final alreadyUnread = current.items.any(
      (item) => item.id == id && !item.isRead,
    );
    if (alreadyUnread) {
      return;
    }

    state = AsyncData(
      current.copyWith(
        items: current.items
            .map((item) => item.id == id ? item.copyWith(isRead: false) : item)
            .toList(growable: false),
      ),
    );

    try {
      await _repository.markAsUnread(id);
    } catch (_) {
      await load();
    }
  }

  Future<void> markAllAsRead() async {
    final current = state.valueOrNull;
    if (current == null || current.items.every((item) => item.isRead)) {
      return;
    }

    state = AsyncData(
      current.copyWith(
        items: current.items
            .map((item) => item.copyWith(isRead: true))
            .toList(growable: false),
      ),
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
      data: (value) => AsyncData(
        value.copyWith(
          items: <AppNotification>[notification, ...value.items],
          total: value.total + 1,
        ),
      ),
      loading: () => AsyncData(
        const NotificationsViewState.initial().copyWith(
          items: <AppNotification>[notification],
          page: 1,
          pageSize: _pageSize,
          total: 1,
          hasMore: false,
        ),
      ),
      error: (_, stackTrace) => AsyncData(
        const NotificationsViewState.initial().copyWith(
          items: <AppNotification>[notification],
          page: 1,
          pageSize: _pageSize,
          total: 1,
          hasMore: false,
        ),
      ),
    );
  }
}
