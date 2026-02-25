import 'package:flutter/material.dart';

class StatusChip extends StatelessWidget {
  const StatusChip({required this.status, super.key});

  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final normalized = status.trim().toLowerCase();

    late final Color bg;
    late final Color fg;
    switch (normalized) {
      case 'active':
      case 'approved':
      case 'completed':
        bg = Colors.green.withValues(alpha: 0.14);
        fg = Colors.green.shade800;
        break;
      case 'processing':
        bg = Colors.blue.withValues(alpha: 0.14);
        fg = Colors.blue.shade800;
        break;
      case 'pending_review':
      case 'pending':
      case 'submitted':
      case 'under_review':
      case 'paused':
        bg = Colors.orange.withValues(alpha: 0.18);
        fg = Colors.orange.shade900;
        break;
      case 'rejected':
      case 'failed':
        bg = Colors.red.withValues(alpha: 0.16);
        fg = Colors.red.shade800;
        break;
      default:
        bg = theme.colorScheme.surfaceContainerHighest;
        fg = theme.colorScheme.onSurfaceVariant;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status.replaceAll('_', ' '),
        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: fg),
      ),
    );
  }
}
