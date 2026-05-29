import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/design_tokens.dart';
import '../providers/providers.dart';
import '../sync/sync_controller.dart';
import '../utils/lebanon_time.dart';

class OfflineBanner extends ConsumerWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncState = ref.watch(syncControllerProvider);
    final scheme = Theme.of(context).colorScheme;
    final appearance = _appearanceFor(syncState);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: appearance.background),
      child: Wrap(
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Icon(appearance.icon, size: 16, color: appearance.foreground),
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
            softWrap: true,
          ),
          if (syncState.isReady && syncState.lastSyncAt != null)
            _SyncMetaChip(
              label: 'Last sync ${_formatTime(syncState.lastSyncAt!)}',
              background: scheme.surface.withValues(alpha: 0.7),
            ),
          if (syncState.isReady && syncState.pendingCount > 0)
            _SyncMetaChip(
              label: '${syncState.pendingCount} to sync',
              background: scheme.surface.withValues(alpha: 0.7),
            ),
          if (syncState.isReady && syncState.conflictCount > 0)
            _SyncMetaChip(
              label: '${syncState.conflictCount} to review',
              background: scheme.errorContainer,
            ),
          if (syncState.isReady && syncState.deadLetterCount > 0)
            _SyncMetaChip(
              label: '${syncState.deadLetterCount} blocked',
              background: scheme.errorContainer,
            ),
        ],
      ),
    );
  }

  _BannerAppearance _appearanceFor(SyncState state) {
    if (state.isInitializing) {
      return const _BannerAppearance(
        icon: Icons.sync,
        title: 'Preparing offline access',
        message: 'Checking saved projects and queued changes.',
        backgroundSeed: _BannerSeed.info,
      );
    }

    if (!state.isReady) {
      return _BannerAppearance(
        icon: Icons.cloud_off_outlined,
        title: 'Offline access unavailable',
        message: state.lastError?.trim().isNotEmpty == true
            ? state.lastError!.trim()
            : 'Saved projects and queued changes are not ready on this device.',
        backgroundSeed: _BannerSeed.warning,
      );
    }

    if (state.isSyncing) {
      return const _BannerAppearance(
        icon: Icons.sync,
        title: 'Syncing saved changes',
        message: 'Sending saved field changes now.',
        backgroundSeed: _BannerSeed.info,
      );
    }

    if (state.conflictCount > 0 || state.deadLetterCount > 0) {
      return const _BannerAppearance(
        icon: Icons.error_outline,
        title: 'Sync needs review',
        message: 'Some saved changes need review before they can sync.',
        backgroundSeed: _BannerSeed.error,
      );
    }

    if (state.pendingCount > 0) {
      return const _BannerAppearance(
        icon: Icons.cloud_upload_outlined,
        title: 'Saved offline',
        message: 'Your changes will sync when you are back online.',
        backgroundSeed: _BannerSeed.warning,
      );
    }

    return const _BannerAppearance(
      icon: Icons.cloud_done_outlined,
      title: 'All changes synced',
      message: 'No saved changes are waiting to sync.',
      backgroundSeed: _BannerSeed.success,
    );
  }

  static String _formatTime(DateTime value) {
    return formatLebanonTime(value);
  }
}

class _SyncMetaChip extends StatelessWidget {
  const _SyncMetaChip({required this.label, required this.background});

  final String label;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: Theme.of(context).textTheme.bodySmall),
    );
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
