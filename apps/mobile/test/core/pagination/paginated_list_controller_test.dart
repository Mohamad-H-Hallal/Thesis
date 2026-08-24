import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:lebanese_gis_mobile/core/pagination/paginated_list_controller.dart';
import 'package:lebanese_gis_mobile/core/pagination/paginated_result.dart';

void main() {
  test('ignores async page results after dispose', () async {
    final completer = Completer<PaginatedResult<int>>();
    final controller = PaginatedListController<int>(
      autoLoad: false,
      loadPage: ({required page, required limit}) => completer.future,
    );

    final loadFuture = controller.load();
    controller.dispose();

    completer.complete(
      const PaginatedResult<int>(
        items: <int>[1, 2, 3],
        page: 1,
        limit: 20,
        total: 3,
        hasMore: false,
      ),
    );

    await loadFuture;
  });

  test(
    'silent refresh keeps the loaded window and logical page position',
    () async {
      final calls = <({int page, int limit})>[];
      final controller = PaginatedListController<int>(
        autoLoad: false,
        pageSize: 2,
        loadPage: ({required page, required limit}) async {
          calls.add((page: page, limit: limit));
          return PaginatedResult<int>(
            items: List<int>.generate(limit, (index) => index + 10),
            page: page,
            limit: limit,
            total: 8,
            hasMore: limit < 8,
          );
        },
      );

      controller.state = const AsyncData(
        PaginatedListState<int>(
          items: <int>[1, 2, 3, 4],
          page: 2,
          pageSize: 2,
          total: 8,
          hasMore: true,
          isLoadingMore: false,
          isRefreshing: false,
        ),
      );
      await controller.refreshSilently();

      expect(calls, <({int page, int limit})>[(page: 1, limit: 4)]);
      expect(controller.state.valueOrNull?.items, <int>[10, 11, 12, 13]);
      expect(controller.state.valueOrNull?.page, 2);
      expect(controller.state.valueOrNull?.pageSize, 2);
      controller.dispose();
    },
  );
}
