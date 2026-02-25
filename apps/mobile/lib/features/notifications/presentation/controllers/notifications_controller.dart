import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../domain/app_notification.dart';
import '../../domain/notifications_repository.dart';

class NotificationsController
    extends StateNotifier<AsyncValue<List<AppNotification>>> {
  NotificationsController(this._repository) : super(const AsyncLoading()) {
    load();
  }

  final NotificationsRepository _repository;
  final Uuid _uuid = const Uuid();

  Future<void> load() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_repository.fetchNotifications);
  }

  void toggleRead(String id) {
    state.whenData((items) {
      state = AsyncData(
        items
            .map(
              (item) =>
                  item.id == id ? item.copyWith(isRead: !item.isRead) : item,
            )
            .toList(growable: false),
      );
    });
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
