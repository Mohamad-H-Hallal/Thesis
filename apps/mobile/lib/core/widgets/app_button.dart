import 'package:flutter/material.dart';

import '../constants/design_tokens.dart';

enum AppButtonVariant { filled, outlined }

class AppButton extends StatelessWidget {
  const AppButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.isLoading = false,
    this.expand = true,
    this.variant = AppButtonVariant.filled,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool isLoading;
  final bool expand;
  final AppButtonVariant variant;

  @override
  Widget build(BuildContext context) {
    final hasIcon = icon != null || isLoading;

    final labelText = Text(
      label,
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );

    final content = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (hasIcon)
          SizedBox(
            width: 20,
            height: 20,
            child: Center(
              child: isLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(icon, size: 18),
            ),
          ),
        if (hasIcon) const SizedBox(width: 8),
        if (expand) Flexible(child: labelText) else labelText,
      ],
    );

    final effectiveOnPressed = isLoading ? null : onPressed;
    final button = switch (variant) {
      AppButtonVariant.filled => FilledButton(
        onPressed: effectiveOnPressed,
        child: content,
      ),
      AppButtonVariant.outlined => OutlinedButton(
        onPressed: effectiveOnPressed,
        child: content,
      ),
    };

    if (!expand) {
      return button;
    }

    return SizedBox(width: double.infinity, child: button);
  }
}

class AppButtonRow extends StatelessWidget {
  const AppButtonRow({
    required this.children,
    this.stackBelowWidth = 520,
    super.key,
  });

  final List<Widget> children;
  final double stackBelowWidth;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final stack = constraints.maxWidth < stackBelowWidth;
        if (stack || children.length == 1) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var index = 0; index < children.length; index += 1) ...[
                if (index > 0) const SizedBox(height: AppSpacing.xs),
                children[index],
              ],
            ],
          );
        }
        return Row(
          children: [
            for (var index = 0; index < children.length; index += 1) ...[
              if (index > 0) const SizedBox(width: AppSpacing.sm),
              Expanded(child: children[index]),
            ],
          ],
        );
      },
    );
  }
}
