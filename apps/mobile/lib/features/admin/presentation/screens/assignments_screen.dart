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
              subtitle:
                  'Project assignment workload across pending, approved, and rejected states.',
            ),
            const SizedBox(height: AppSpacing.sm),
            if (assignments.isEmpty)
              const AppEmptyState(
                icon: Icons.assignment_outlined,
                title: 'No assignments found',
                message:
                    'Assignments will appear here when admins assign users to projects.',
              )
            else
              ...assignments.map(
                (assignment) => Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: AppCard(
                    onTap: () => context.push(
                      AppRoutes.projectAssignments(assignment.projectId),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          assignment.projectName,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          assignment.fullName,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        Text(
                          assignment.email,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            Chip(
                              label: Text(
                                'Project ${assignment.projectStatus}',
                              ),
                            ),
                            Chip(label: Text('Role: ${assignment.role}')),
                            Chip(label: Text('Status: ${assignment.status}')),
                          ],
                        ),
                      ],
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
