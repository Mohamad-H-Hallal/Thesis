import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'paginated_result.dart';

class PaginatedListState<T> {
  const PaginatedListState({
    required this.items,
    required this.page,
    required this.pageSize,
    required this.total,
    required this.hasMore,
    required this.isLoadingMore,
    required this.isRefreshing,
  });

  const PaginatedListState.initial({this.pageSize = 20})
    : items = const [],
      page = 0,
      total = 0,
      hasMore = true,
      isLoadingMore = false,
      isRefreshing = false;

  final List<T> items;
  final int page;
  final int pageSize;
  final int total;
  final bool hasMore;
  final bool isLoadingMore;
  final bool isRefreshing;

  PaginatedListState<T> copyWith({
    List<T>? items,
    int? page,
    int? pageSize,
    int? total,
    bool? hasMore,
    bool? isLoadingMore,
    bool? isRefreshing,
  }) {
    return PaginatedListState<T>(
      items: items ?? this.items,
      page: page ?? this.page,
      pageSize: pageSize ?? this.pageSize,
      total: total ?? this.total,
      hasMore: hasMore ?? this.hasMore,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      isRefreshing: isRefreshing ?? this.isRefreshing,
    );
  }
}

typedef PaginatedPageLoader<T> =
    Future<PaginatedResult<T>> Function({
      required int page,
      required int limit,
    });

class PaginatedListController<T>
    extends StateNotifier<AsyncValue<PaginatedListState<T>>> {
  PaginatedListController({
    required PaginatedPageLoader<T> loadPage,
    int pageSize = 20,
    bool autoLoad = true,
  }) : _loadPage = loadPage,
       _pageSize = pageSize,
       super(const AsyncLoading()) {
    if (autoLoad) {
      load();
    } else {
      state = AsyncData(PaginatedListState<T>.initial(pageSize: pageSize));
    }
  }

  final PaginatedPageLoader<T> _loadPage;
  final int _pageSize;

  Future<void> load({bool silently = false}) async {
    final current = state.valueOrNull;
    if (silently && current != null) {
      state = AsyncData(current.copyWith(isRefreshing: true));
      try {
        final page = await _loadPage(page: 1, limit: current.pageSize);
        state = AsyncData(
          PaginatedListState<T>(
            items: page.items,
            page: page.page,
            pageSize: page.limit,
            total: page.total,
            hasMore: page.hasMore,
            isLoadingMore: false,
            isRefreshing: false,
          ),
        );
      } catch (_) {
        state = AsyncData(current.copyWith(isRefreshing: false));
      }
      return;
    }

    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final page = await _loadPage(page: 1, limit: _pageSize);
      return PaginatedListState<T>(
        items: page.items,
        page: page.page,
        pageSize: page.limit,
        total: page.total,
        hasMore: page.hasMore,
        isLoadingMore: false,
        isRefreshing: false,
      );
    });
  }

  Future<void> refresh() => load();

  Future<void> refreshSilently() => load(silently: true);

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.isLoadingMore || !current.hasMore) {
      return;
    }

    state = AsyncData(current.copyWith(isLoadingMore: true));
    try {
      final nextPageNumber = current.page + 1;
      final page = await _loadPage(
        page: nextPageNumber,
        limit: current.pageSize,
      );
      state = AsyncData(
        current.copyWith(
          items: <T>[...current.items, ...page.items],
          page: page.page,
          pageSize: page.limit,
          total: page.total,
          hasMore: page.hasMore,
          isLoadingMore: false,
          isRefreshing: false,
        ),
      );
    } catch (_) {
      state = AsyncData(current.copyWith(isLoadingMore: false));
    }
  }
}
