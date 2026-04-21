import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/constants/design_tokens.dart';

class AuthViewport extends StatelessWidget {
  const AuthViewport({required this.child, this.maxWidth = 460, super.key});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontalPadding = constraints.maxWidth < 420
            ? AppSpacing.sm
            : AppSpacing.md;
        final verticalPadding = constraints.maxHeight < 720
            ? AppSpacing.sm
            : AppSpacing.lg;
        final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
        final minHeight = math
            .max(0, constraints.maxHeight - (verticalPadding * 2) - bottomInset)
            .toDouble();

        return SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            verticalPadding,
            horizontalPadding,
            verticalPadding + bottomInset,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight),
            child: Align(
              alignment: minHeight >= 640
                  ? Alignment.center
                  : Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}
