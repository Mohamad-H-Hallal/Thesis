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
    required this.unreadCount,
    required this.isReadFilter,
    required this.hasMore,
    required this.isLoadingMore,
  });

  const NotificationsViewState.initial()
    : items = const <AppNotification>[],
      page = 0,
      pageSize = 20,
      total = 0,
      unreadCount = 0,
      isReadFilter = null,
      hasMore = true,
      isLoadingMore = false;

  final List<AppNotification> items;
  final int page;
  final int pageSize;
  final int total;
  final int unreadCount;
  final bool? isReadFilter;
  final bool hasMore;
  final bool isLoadingMore;

  NotificationsViewState copyWith({
    List<AppNotification>? items,
    int? page,
    int? pageSize,
    int? total,
    int? unreadCount,
    bool? isReadFilter,
    bool? hasMore,
    bool? isLoadingMore,
  }) {
    return NotificationsViewState(
      items: items ?? this.items,
      page: page ?? this.page,
      pageSize: pageSize ?? this.pageSize,
      total: total ?? this.total,
      unreadCount: unreadCount ?? this.unreadCount,
      isReadFilter: isReadFilter ?? this.isReadFilter,
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
  bool? _currentIsReadFilter;
  int _loadGeneration = 0;

  bool _canPublish(int generation) => mounted && generation == _loadGeneration;

  Future<void> load({bool? isReadFilter}) async {
    final generation = ++_loadGeneration;
    _currentIsReadFilter = isReadFilter;
    state = const AsyncLoading();
    try {
      final results = await Future.wait<dynamic>([
        _repository.fetchNotifications(limit: _pageSize, isRead: isReadFilter),
        _repository.fetchUnreadCount(),
      ]);
      if (!_canPublish(generation)) {
        return;
      }
      final page = results[0] as NotificationPage;
      final unreadCount = results[1] as int;
      state = AsyncData(
        NotificationsViewState(
          items: page.items,
          page: page.page,
          pageSize: page.limit,
          total: page.total,
          unreadCount: unreadCount,
          isReadFilter: isReadFilter,
          hasMore: page.hasMore,
          isLoadingMore: false,
        ),
      );
    } catch (error, stackTrace) {
      if (!_canPublish(generation)) {
        return;
      }
      state = AsyncError(error, stackTrace);
    }
  }

  Future<void> loadMore() async {
    final generation = ++_loadGeneration;
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
        isRead: _currentIsReadFilter,
      );
      if (!_canPublish(generation)) {
        return;
      }
      state = AsyncData(
        current.copyWith(
          items: <AppNotification>[...current.items, ...page.items],
          page: page.page,
          pageSize: page.limit,
          total: page.total,
          isReadFilter: _currentIsReadFilter,
          hasMore: page.hasMore,
          isLoadingMore: false,
        ),
      );
    } catch (_) {
      if (!_canPublish(generation)) {
        return;
      }
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

    final nextItems = current.isReadFilter == false
        ? current.items.where((item) => item.id != id).toList(growable: false)
        : current.items
              .map((item) => item.id == id ? item.copyWith(isRead: true) : item)
              .toList(growable: false);

    state = AsyncData(
      current.copyWith(
        items: nextItems,
        total: current.isReadFilter == false
            ? (current.total > 0 ? current.total - 1 : 0)
            : current.total,
        unreadCount: current.unreadCount > 0 ? current.unreadCount - 1 : 0,
        hasMore: current.isReadFilter == false
            ? nextItems.length < (current.total > 0 ? current.total - 1 : 0)
            : current.hasMore,
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

    final nextItems = current.isReadFilter == true
        ? current.items.where((item) => item.id != id).toList(growable: false)
        : current.items
              .map(
                (item) => item.id == id ? item.copyWith(isRead: false) : item,
              )
              .toList(growable: false);

    state = AsyncData(
      current.copyWith(
        items: nextItems,
        total: current.isReadFilter == true
            ? (current.total > 0 ? current.total - 1 : 0)
            : current.total,
        unreadCount: current.unreadCount + 1,
        hasMore: current.isReadFilter == true
            ? nextItems.length < (current.total > 0 ? current.total - 1 : 0)
            : current.hasMore,
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

    final clearingUnreadFilter = current.isReadFilter == false;
    state = AsyncData(
      current.copyWith(
        items: clearingUnreadFilter
            ? const <AppNotification>[]
            : current.items
                  .map((item) => item.copyWith(isRead: true))
                  .toList(growable: false),
        total: clearingUnreadFilter ? 0 : current.total,
        unreadCount: 0,
        hasMore: clearingUnreadFilter ? false : current.hasMore,
      ),
    );

    try {
      await _repository.markAllAsRead();
    } catch (_) {
      await load();
    }
  }

  void pushNotification({required String title, required String message}) {
    if (!mounted) {
      return;
    }
    final notification = AppNotification(
      id: _uuid.v4(),
      title: title,
      message: message,
      timestamp: 'just now',
      isRead: false,
    );

    state = state.when(
      data: (value) {
        final shouldShowInCurrentFilter = value.isReadFilter != true;
        return AsyncData(
          value.copyWith(
            items: shouldShowInCurrentFilter
                ? <AppNotification>[notification, ...value.items]
                : value.items,
            total: shouldShowInCurrentFilter ? value.total + 1 : value.total,
            unreadCount: value.unreadCount + 1,
          ),
        );
      },
      loading: () => AsyncData(
        const NotificationsViewState.initial().copyWith(
          items: <AppNotification>[notification],
          page: 1,
          pageSize: _pageSize,
          total: 1,
          unreadCount: 1,
          hasMore: false,
        ),
      ),
      error: (_, stackTrace) => AsyncData(
        const NotificationsViewState.initial().copyWith(
          items: <AppNotification>[notification],
          page: 1,
          pageSize: _pageSize,
          total: 1,
          unreadCount: 1,
          hasMore: false,
        ),
      ),
    );
  }
}
