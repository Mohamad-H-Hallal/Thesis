import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/design_tokens.dart';
import '../providers/providers.dart';
import '../sync/sync_controller.dart';

class OfflineBanner extends ConsumerWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncState = ref.watch(syncControllerProvider);
    final scheme = Theme.of(context).colorScheme;
    final appearance = _appearanceFor(syncState);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: appearance.background),
      child: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Icon(appearance.icon, size: 18, color: appearance.foreground),
          Text(
            appearance.title,
            style: TextStyle(
              color: appearance.foreground,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            appearance.message,
            style: TextStyle(color: appearance.foreground),
          ),
          if (syncState.isReady && syncState.lastSyncAt != null)
            Chip(
              label: Text('Last sync ${_formatTime(syncState.lastSyncAt!)}'),
              backgroundColor: scheme.surface.withValues(alpha: 0.7),
            ),
          if (syncState.isReady && syncState.pendingCount > 0)
            Chip(
              label: Text('${syncState.pendingCount} queued'),
              backgroundColor: scheme.surface.withValues(alpha: 0.7),
            ),
          if (syncState.isReady && syncState.conflictCount > 0)
            Chip(
              label: Text('${syncState.conflictCount} conflicts'),
              backgroundColor: scheme.errorContainer,
            ),
          if (syncState.isReady && syncState.deadLetterCount > 0)
            Chip(
              label: Text('${syncState.deadLetterCount} blocked'),
              backgroundColor: scheme.errorContainer,
            ),
        ],
      ),
    );
  }

  _BannerAppearance _appearanceFor(SyncState state) {
    if (state.isInitializing) {
      return const _BannerAppearance(
        icon: Icons.sync,
        title: 'Preparing sync',
        message:
            'Local sync storage is starting.',
        backgroundSeed: _BannerSeed.info,
      );
    }

    if (!state.isReady) {
      return _BannerAppearance(
        icon: Icons.cloud_off_outlined,
        title: 'Sync unavailable',
        message: state.lastError?.trim().isNotEmpty == true
            ? state.lastError!
            : 'Offline sync is unavailable right now.',
        backgroundSeed: _BannerSeed.warning,
      );
    }

    if (state.isSyncing) {
      return const _BannerAppearance(
        icon: Icons.sync,
        title: 'Syncing',
        message: 'Queued updates are syncing now.',
        backgroundSeed: _BannerSeed.info,
      );
    }

    if (state.conflictCount > 0 || state.deadLetterCount > 0) {
      return const _BannerAppearance(
        icon: Icons.error_outline,
        title: 'Sync attention needed',
        message: 'Some queued items need review before they can sync cleanly.',
        backgroundSeed: _BannerSeed.error,
      );
    }

    if (state.pendingCount > 0) {
      return const _BannerAppearance(
        icon: Icons.cloud_upload_outlined,
        title: 'Queue active',
        message: 'Queued offline work is waiting for the next sync run.',
        backgroundSeed: _BannerSeed.warning,
      );
    }

    return const _BannerAppearance(
      icon: Icons.cloud_done_outlined,
      title: 'Sync healthy',
      message: 'No queued collection changes need syncing.',
      backgroundSeed: _BannerSeed.success,
    );
  }

  static String _formatTime(DateTime value) {
    final local = value.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

enum _BannerSeed { info, warning, success, error }

class _BannerAppearance {
  const _BannerAppearance({
    required this.icon,
    required this.title,
    required this.message,
    required this.backgroundSeed,
  });

  final IconData icon;
  final String title;
  final String message;
  final _BannerSeed backgroundSeed;

  Color get background {
    switch (backgroundSeed) {
      case _BannerSeed.info:
        return Colors.blue.withValues(alpha: 0.12);
      case _BannerSeed.warning:
        return Colors.amber.withValues(alpha: 0.18);
      case _BannerSeed.success:
        return Colors.green.withValues(alpha: 0.14);
      case _BannerSeed.error:
        return Colors.red.withValues(alpha: 0.14);
    }
  }

  Color get foreground {
    switch (backgroundSeed) {
      case _BannerSeed.info:
        return const Color(0xFF0F3D91);
      case _BannerSeed.warning:
        return const Color(0xFF7A4A00);
      case _BannerSeed.success:
        return const Color(0xFF0C5B3D);
      case _BannerSeed.error:
        return const Color(0xFF8A1C1C);
    }
  }
}
