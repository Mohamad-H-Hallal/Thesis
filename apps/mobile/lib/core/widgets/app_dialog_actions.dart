import 'package:flutter/material.dart';

import '../constants/design_tokens.dart';

class AppDialogActions extends StatelessWidget {
  const AppDialogActions({
    required this.cancel,
    required this.confirm,
    this.buttonWidth = 160,
    super.key,
  });

  const AppDialogActions.single({
    required this.confirm,
    this.buttonWidth = 160,
    super.key,
  }) : cancel = null;

  final Widget? cancel;
  final Widget confirm;
  final double buttonWidth;

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final textScale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
    final scaledButtonWidth = buttonWidth * textScale;
    final buttonHeight = 52 * textScale.clamp(1.0, 1.5);
    final preferredWidth = cancel == null
        ? scaledButtonWidth
        : (scaledButtonWidth * 2) + AppSpacing.sm;
    final outerPreferredWidth = preferredWidth < 272 ? 272.0 : preferredWidth;
    final availableWidth = (screenWidth - 48).clamp(0.0, outerPreferredWidth);
    final cancelButton = cancel == null
        ? null
        : TextButtonTheme(
            data: TextButtonThemeData(
              style: TextButton.styleFrom(
                alignment: Alignment.center,
                minimumSize: Size.fromHeight(buttonHeight),
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                side: BorderSide(color: Theme.of(context).colorScheme.outline),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
            child: SizedBox.expand(
              child: DefaultTextStyle.merge(
                textAlign: TextAlign.center,
                child: cancel!,
              ),
            ),
          );
    final confirmButton = SizedBox.expand(
      child: FilledButtonTheme(
        data: FilledButtonThemeData(
          style:
              FilledButtonTheme.of(context).style?.merge(
                FilledButton.styleFrom(
                  alignment: Alignment.center,
                  minimumSize: Size.fromHeight(buttonHeight),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xs,
                  ),
                ),
              ) ??
              FilledButton.styleFrom(
                alignment: Alignment.center,
                minimumSize: Size.fromHeight(buttonHeight),
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
              ),
        ),
        child: DefaultTextStyle.merge(
          textAlign: TextAlign.center,
          child: confirm,
        ),
      ),
    );

    if (cancel == null) {
      return SizedBox(
        width: availableWidth,
        height: buttonHeight,
        child: confirmButton,
      );
    }

    return SizedBox(
      width: availableWidth,
      child: Row(
        children: [
          Expanded(
            child: SizedBox(height: buttonHeight, child: cancelButton!),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: SizedBox(height: buttonHeight, child: confirmButton),
          ),
        ],
      ),
    );
  }
}

class AppDialogActionLabel extends StatelessWidget {
  const AppDialogActionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.center,
    child: Text(
      text,
      maxLines: 1,
      softWrap: false,
      textAlign: TextAlign.center,
    ),
  );
}
