import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/widgets/animated_reveal.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../domain/app_notification.dart';

enum _NotificationFilter { all, read, unread }

class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  _NotificationFilter _filter = _NotificationFilter.all;

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final notificationsAsync = ref.watch(notificationsControllerProvider);

    return notificationsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'Notifications unavailable',
        message: userFacingErrorMessage(
          error,
          fallback: 'Unable to load notifications right now. Please try again.',
        ),
        actionLabel: 'Retry',
        onAction: () =>
            ref.read(notificationsControllerProvider.notifier).load(),
      ),
      data: (notifications) {
        final unreadCount = notifications.unreadCount;
        final filtered = notifications.items;

        return ListView(
          children: [
            if (unreadCount > 0) ...[
              AppCard(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final summary = Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.mark_email_unread_outlined),
                        const SizedBox(width: AppSpacing.sm),
                        Flexible(
                          child: Text(
                            '$unreadCount unread notification${unreadCount == 1 ? '' : 's'}',
                            style: Theme.of(context).textTheme.titleMedium,
                            softWrap: true,
                          ),
                        ),
                      ],
                    );
                    final action = OutlinedButton.icon(
                      onPressed: () => ref
                          .read(notificationsControllerProvider.notifier)
                          .markAllAsRead(),
                      icon: const Icon(Icons.done_all_outlined),
                      label: const Text('Mark all as read'),
                    );

                    if (constraints.maxWidth < 520) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          summary,
                          const SizedBox(height: AppSpacing.sm),
                          SizedBox(width: double.infinity, child: action),
                        ],
                      );
                    }

                    return Row(
                      children: [
                        Expanded(child: summary),
                        action,
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
            AppCard(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final filters = Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('All'),
                        selected: _filter == _NotificationFilter.all,
                        onSelected: (_) {
                          setState(() => _filter = _NotificationFilter.all);
                          ref
                              .read(notificationsControllerProvider.notifier)
                              .load();
                        },
                      ),
                      ChoiceChip(
                        label: const Text('Read'),
                        selected: _filter == _NotificationFilter.read,
                        onSelected: (_) {
                          setState(() => _filter = _NotificationFilter.read);
                          ref
                              .read(notificationsControllerProvider.notifier)
                              .load(isReadFilter: true);
                        },
                      ),
                      ChoiceChip(
                        label: const Text('Unread'),
                        selected: _filter == _NotificationFilter.unread,
                        onSelected: (_) {
                          setState(() => _filter = _NotificationFilter.unread);
                          ref
                              .read(notificationsControllerProvider.notifier)
                              .load(isReadFilter: false);
                        },
                      ),
                    ],
                  );

                  if (constraints.maxWidth < 520) {
                    return filters;
                  }

                  return filters;
                },
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (filtered.isEmpty)
              AppEmptyState(
                icon: _filter == _NotificationFilter.unread
                    ? Icons.mark_email_read_outlined
                    : _filter == _NotificationFilter.read
                    ? Icons.drafts_outlined
                    : Icons.notifications_off_outlined,
                title: _filter == _NotificationFilter.unread
                    ? 'No unread notifications'
                    : _filter == _NotificationFilter.read
                    ? 'No read notifications'
                    : 'No notifications',
                message: _filter == _NotificationFilter.unread
                    ? 'You have no unread updates right now.'
                    : _filter == _NotificationFilter.read
                  ? 'You have no read notifications right now.'
                  : 'Contributor requests, project requests, review outcomes, and export updates will appear here.',
              )
            else
              LayoutBuilder(
                builder: (context, constraints) {
                  final canGrid = constraints.maxWidth >= 760;
                  if (!canGrid) {
                    return Column(
                      children: List<Widget>.generate(filtered.length, (index) {
                        final item = filtered[index];
                        return Padding(
                          padding: const EdgeInsets.only(
                            bottom: AppSpacing.sm,
                          ),
                          child: AnimatedReveal(
                            delay: Duration(milliseconds: index * 45),
                            child: _NotificationCard(item: item),
                          ),
                        );
                      }),
                    );
                  }

                  const gap = AppSpacing.sm;
                  final columns = (constraints.maxWidth / 380)
                      .floor()
                      .clamp(2, 3);
                  final itemWidth =
                      (constraints.maxWidth - (gap * (columns - 1))) /
                      columns;
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: List<Widget>.generate(filtered.length, (index) {
                      final item = filtered[index];
                      return SizedBox(
                        width: itemWidth,
                        child: AnimatedReveal(
                          delay: Duration(milliseconds: index * 45),
                          child: _NotificationCard(item: item),
                        ),
                      );
                    }),
                  );
                },
              ),
            if (notifications.isLoadingMore) ...[
              const SizedBox(height: AppSpacing.sm),
              const Center(child: CircularProgressIndicator()),
            ] else if (notifications.hasMore &&
                notifications.items.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Center(
                child: OutlinedButton.icon(
                  onPressed: () => ref
                      .read(notificationsControllerProvider.notifier)
                      .loadMore(),
                  icon: const Icon(Icons.expand_more),
                  label: const Text('Show more'),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
          ],
        );
      },
    );
  }
}

class _NotificationCard extends ConsumerWidget {
  const _NotificationCard({required this.item});

  final AppNotification item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppCard(
      onTap: item.isRead
          ? null
          : () => ref
                .read(notificationsControllerProvider.notifier)
                .markAsRead(item.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 18,
                child: Icon(
                  item.isRead
                      ? Icons.mark_email_read_outlined
                      : Icons.mark_email_unread_outlined,
                  size: 18,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: TextStyle(
                        fontWeight: item.isRead
                            ? FontWeight.w600
                            : FontWeight.w700,
                      ),
                      softWrap: true,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(item.message, softWrap: true),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(label: Text(item.isRead ? 'Read' : 'Unread')),
              Chip(label: Text(item.timestamp)),
              if (!item.isRead)
                OutlinedButton.icon(
                  onPressed: () => ref
                      .read(notificationsControllerProvider.notifier)
                      .markAsRead(item.id),
                  icon: const Icon(Icons.done_outlined, size: 18),
                  label: const Text('Mark read'),
                ),
              if (item.isRead)
                OutlinedButton.icon(
                  onPressed: () => ref
                      .read(notificationsControllerProvider.notifier)
                      .markAsUnread(item.id),
                  icon: const Icon(Icons.mark_email_unread_outlined, size: 18),
                  label: const Text('Mark unread'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
