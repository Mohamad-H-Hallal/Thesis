import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

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
}
