import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/section_header.dart';

class MapScreen extends ConsumerWidget {
  const MapScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncState = ref.watch(syncControllerProvider);
    final blockedCount = syncState.conflictCount + syncState.deadLetterCount;
    final syncLabel = syncState.isSyncing
        ? 'Sync: running'
        : blockedCount > 0
        ? 'Sync: ${syncState.pendingCount} pending • $blockedCount blocked'
        : 'Sync: ${syncState.pendingCount} pending';

    final gpsLabel = 'GPS: Good (3m)';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'Map Workspace',
          subtitle: 'GPS and sync indicators with add-feature action',
        ),
        const SizedBox(height: AppSpacing.sm),
        Expanded(
          child: Stack(
            children: [
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                      Theme.of(context).colorScheme.surfaceContainerLow,
                    ],
                  ),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.map, size: 52),
                      SizedBox(height: 8),
                      Text(
                        'Map placeholder (PostGIS tile integration in Phase 6).',
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                top: 14,
                left: 14,
                right: 14,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Chip(
                      avatar: Icon(Icons.gps_fixed, size: 18),
                      label: Text(gpsLabel),
                    ),
                    Chip(
                      avatar: Icon(
                        syncState.isSyncing
                            ? Icons.sync
                            : blockedCount > 0
                            ? Icons.error_outline
                            : Icons.sync_problem,
                        size: 18,
                      ),
                      label: Text(syncLabel),
                    ),
                  ],
                ),
              ),
              Positioned(
                right: 18,
                bottom: 18,
                child: FloatingActionButton.extended(
                  onPressed: () => context.go(AppRoutes.addFeature),
                  icon: const Icon(Icons.add_location_alt),
                  label: const Text('Add Feature'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
