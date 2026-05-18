import 'package:flutter/material.dart';

import '../constants/design_tokens.dart';

class AppDialogActions extends StatelessWidget {
  const AppDialogActions({
    required this.cancel,
    required this.confirm,
    this.buttonWidth = 156,
    super.key,
  });

  final Widget cancel;
  final Widget confirm;
  final double buttonWidth;

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final preferredWidth = (buttonWidth * 2) + AppSpacing.sm;
    final availableWidth = (screenWidth - 48)
        .clamp(220.0, preferredWidth)
        .toDouble();

    return SizedBox(
      width: availableWidth,
      child: Row(
        children: [
          Expanded(child: cancel),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: confirm),
        ],
      ),
    );
  }
}
