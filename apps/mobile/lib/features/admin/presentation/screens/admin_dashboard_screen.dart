import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';

class AdminDashboardScreen extends ConsumerWidget {
  const AdminDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dashboardAsync = ref.watch(adminDashboardProvider);

    return dashboardAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'Dashboard unavailable',
        message: userFacingErrorMessage(
          error,
          fallback:
              'Unable to load the admin dashboard right now. Please try again.',
        ),
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(adminDashboardProvider),
      ),
      data: (summary) {
        final metrics = <({String label, String value, IconData icon})>[
          (
            label: 'Users',
            value: '${summary.totalUsers}',
            icon: Icons.groups_outlined,
          ),
          (
            label: 'Admins',
            value: '${summary.adminCount}',
            icon: Icons.admin_panel_settings_outlined,
          ),
          (
            label: 'Viewers',
            value: '${summary.viewerCount}',
            icon: Icons.visibility_outlined,
          ),
          (
            label: 'Active contributors',
            value: '${summary.activeContributorCount}',
            icon: Icons.edit_location_alt_outlined,
          ),
          (
            label: 'Blocked accounts',
            value: '${summary.blockedCount}',
            icon: Icons.block_outlined,
          ),
          (
            label: 'Pending contributor requests',
            value: '${summary.pendingContributorRequests}',
            icon: Icons.person_add_alt_1_outlined,
          ),
          (
            label: 'Rejected requests',
            value: '${summary.rejectedContributorRequests}',
            icon: Icons.person_off_outlined,
          ),
          (
            label: 'Projects',
            value: '${summary.totalProjects}',
            icon: Icons.folder_outlined,
          ),
          (
            label: 'Pending assignments',
            value: '${summary.pendingAssignments}',
            icon: Icons.assignment_late_outlined,
          ),
        ];

        return ListView(
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final cardWidth = switch (constraints.maxWidth) {
                  >= 1100 => (constraints.maxWidth - (AppSpacing.sm * 2)) / 3,
                  >= 680 => (constraints.maxWidth - AppSpacing.sm) / 2,
                  _ => constraints.maxWidth,
                };

                return Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: metrics
                      .map(
                        (metric) => _MetricCard(
                          width: cardWidth,
                          label: metric.label,
                          value: metric.value,
                          icon: metric.icon,
                        ),
                      )
                      .toList(growable: false),
                );
              },
            ),
          ],
        );
      },
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.width,
    required this.label,
    required this.value,
    required this.icon,
  });

  final double width;
  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: AppCard(
        child: Row(
          children: [
            Icon(icon, size: 28),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Theme.of(context).textTheme.bodySmall),
                  Text(value, style: Theme.of(context).textTheme.headlineSmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
