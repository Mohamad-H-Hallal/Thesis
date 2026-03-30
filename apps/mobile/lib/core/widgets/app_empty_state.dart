import 'package:flutter/material.dart';

import '../constants/design_tokens.dart';

class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    required this.title,
    required this.message,
    this.icon = Icons.inbox_outlined,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  final String title;
  final String message;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mediaQuery = MediaQuery.maybeOf(context);
    final compact = (mediaQuery?.size.height ?? 0) > 0 &&
        (mediaQuery!.size.height < 760 || mediaQuery.size.width < 380);
    final illustrationWidth = compact ? 96.0 : 124.0;
    final illustrationHeight = compact ? 84.0 : 104.0;
    final primaryCircleSize = compact ? 42.0 : 54.0;
    final secondaryCircleSize = compact ? 34.0 : 44.0;
    final iconCircleSize = compact ? 60.0 : 72.0;
    final iconSize = compact ? 28.0 : 32.0;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(
        vertical: AppSpacing.sm,
        horizontal: AppSpacing.xs,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: illustrationWidth,
                height: illustrationHeight,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    Positioned(
                      left: 8,
                      top: compact ? 16 : 18,
                      child: Container(
                        width: primaryCircleSize,
                        height: primaryCircleSize,
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer.withValues(alpha: 0.55),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    Positioned(
                      right: 4,
                      top: compact ? 8 : 6,
                      child: Container(
                        width: secondaryCircleSize,
                        height: secondaryCircleSize,
                        decoration: BoxDecoration(
                          color: scheme.tertiaryContainer.withValues(alpha: 0.6),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    Container(
                      width: iconCircleSize,
                      height: iconCircleSize,
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: scheme.outlineVariant.withValues(alpha: 0.4),
                        ),
                      ),
                      child: Icon(icon, size: iconSize, color: scheme.primary),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
                softWrap: true,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
                softWrap: true,
              ),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: AppSpacing.md),
                FilledButton.icon(
                  onPressed: onAction,
                  icon: const Icon(Icons.refresh),
                  label: Text(actionLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
