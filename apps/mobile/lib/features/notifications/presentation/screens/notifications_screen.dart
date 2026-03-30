import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/widgets/animated_reveal.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/section_header.dart';
import '../../domain/app_notification.dart';

enum _NotificationFilter { all, unread }

class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  _NotificationFilter _filter = _NotificationFilter.all;

  @override
  Widget build(BuildContext context) {
    final notificationsAsync = ref.watch(notificationsControllerProvider);

    return notificationsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'Notifications unavailable',
        message: '$error',
        actionLabel: 'Retry',
        onAction: () =>
            ref.read(notificationsControllerProvider.notifier).load(),
      ),
      data: (notifications) {
        final unreadCount = notifications.where((n) => !n.isRead).length;
        final filtered = _filter == _NotificationFilter.unread
            ? notifications.where((item) => !item.isRead).toList(growable: false)
            : notifications;

        return ListView(
          children: [
            SectionHeader(
              title: 'Notifications',
              subtitle: unreadCount == 0
                  ? 'No unread updates'
                  : '$unreadCount unread update${unreadCount == 1 ? '' : 's'}',
            ),
            const SizedBox(height: AppSpacing.sm),
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
                        onSelected: (_) =>
                            setState(() => _filter = _NotificationFilter.all),
                      ),
                      ChoiceChip(
                        label: const Text('Unread'),
                        selected: _filter == _NotificationFilter.unread,
                        onSelected: (_) =>
                            setState(() => _filter = _NotificationFilter.unread),
                      ),
                    ],
                  );

                  final Widget? markAll = unreadCount > 0
                      ? OutlinedButton.icon(
                          onPressed: () => ref
                              .read(notificationsControllerProvider.notifier)
                              .markAllAsRead(),
                          icon: const Icon(Icons.done_all_outlined),
                          label: const Text('Mark all read'),
                        )
                      : null;
                  final trailingActions = markAll == null
                      ? const <Widget>[]
                      : <Widget>[markAll];

                  if (constraints.maxWidth < 520) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        filters,
                        if (trailingActions.isNotEmpty) ...[
                          const SizedBox(height: AppSpacing.sm),
                          ...trailingActions,
                        ],
                      ],
                    );
                  }

                  return Row(
                    children: [
                      Expanded(child: filters),
                      ...trailingActions,
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (filtered.isEmpty)
              AppEmptyState(
                icon: _filter == _NotificationFilter.unread
                    ? Icons.mark_email_read_outlined
                    : Icons.notifications_off_outlined,
                title: _filter == _NotificationFilter.unread
                    ? 'No unread notifications'
                    : 'No notifications',
                message: _filter == _NotificationFilter.unread
                    ? 'You have no unread updates right now.'
                    : 'Contributor requests, project requests, review outcomes, and export updates will appear here.',
              )
            else
              ...List<Widget>.generate(filtered.length, (index) {
                final item = filtered[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: AnimatedReveal(
                    delay: Duration(milliseconds: index * 45),
                    child: _NotificationCard(item: item),
                  ),
                );
              }),
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
                        fontWeight:
                            item.isRead ? FontWeight.w600 : FontWeight.w700,
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
