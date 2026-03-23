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
            message: 'Assignment, review, and export updates will appear here.',
          );
        }

        return ListView(
          children: [
            SectionHeader(
              title: 'Notifications',
              subtitle:
                  '${notifications.where((n) => !n.isRead).length} unread updates',
            ),
            const SizedBox(height: AppSpacing.md),
            ...List<Widget>.generate(notifications.length, (index) {
              final item = notifications[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: AnimatedReveal(
                  delay: Duration(milliseconds: index * 55),
                  child: AppCard(
                    onTap: () => ref
                        .read(notificationsControllerProvider.notifier)
                        .toggleRead(item.id),
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        radius: 18,
                        child: Icon(
                          item.isRead
                              ? Icons.mark_email_read
                              : Icons.mark_email_unread,
                          size: 18,
                        ),
                      ),
                      title: Text(
                        item.title,
                        style: TextStyle(
                          fontWeight: item.isRead
                              ? FontWeight.w500
                              : FontWeight.w700,
                        ),
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.xs),
                        child: Text(item.message),
                      ),
                      trailing: Text(item.timestamp),
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
