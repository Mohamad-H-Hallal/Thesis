import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/section_header.dart';

class AssignmentsScreen extends ConsumerWidget {
  const AssignmentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final assignmentsAsync = ref.watch(managedAssignmentsProvider);

    return assignmentsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'Assignments unavailable',
        message: '$error',
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(managedAssignmentsProvider),
      ),
      data: (assignments) {
        return ListView(
          children: [
            const SectionHeader(
              title: 'Assignments',
              subtitle: 'Project assignment workload across pending, approved, and rejected states.',
            ),
            const SizedBox(height: AppSpacing.sm),
            if (assignments.isEmpty)
              const AppEmptyState(
                icon: Icons.assignment_outlined,
                title: 'No assignments found',
                message: 'Assignments will appear here when admins assign users to projects.',
              )
            else
              ...assignments.map(
                (assignment) => Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: AppCard(
                      onTap: () => context.push(
                        AppRoutes.projectAssignments(assignment.projectId),
                      ),
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(assignment.projectName),
                        subtitle: Text(
                          '${assignment.fullName} • ${assignment.email}\n${assignment.role} • ${assignment.status}',
                        ),
                        isThreeLine: true,
                        trailing: Chip(label: Text(assignment.projectStatus)),
                      ),
                    ),
                  ),
                ),
          ],
        );
      },
    );
  }
}
