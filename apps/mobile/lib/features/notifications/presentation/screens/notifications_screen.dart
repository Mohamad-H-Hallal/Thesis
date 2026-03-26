import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/widgets/animated_reveal.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/section_header.dart';

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
        if (notifications.isEmpty) {
          return const AppEmptyState(
            icon: Icons.notifications_off_outlined,
            title: 'No notifications',
            message:
                'Contributor requests, project requests, review outcomes, and export updates will appear here.',
          );
        }

        return ListView(
          children: [
            SectionHeader(
              title: 'Notifications',
              subtitle:
                  '${notifications.where((n) => !n.isRead).length} unread updates',
              trailing: notifications.any((item) => !item.isRead)
                  ? OutlinedButton.icon(
                      onPressed: () => ref
                          .read(notificationsControllerProvider.notifier)
                          .markAllAsRead(),
                      icon: const Icon(Icons.done_all_outlined),
                      label: const Text('Mark all read'),
                    )
                  : null,
            ),
            const SizedBox(height: AppSpacing.md),
            ...List<Widget>.generate(notifications.length, (index) {
              final item = notifications[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: AnimatedReveal(
                  delay: Duration(milliseconds: index * 45),
                  child: AppCard(
                    onTap: () => ref
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
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ],
        );
      },
    );
  }
}
