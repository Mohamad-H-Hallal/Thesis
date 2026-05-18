import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../constants/design_tokens.dart';

class AppActionButtons extends StatelessWidget {
  const AppActionButtons({
    required this.children,
    this.maxColumns = 2,
    this.maxItemWidth,
    this.spacing = AppSpacing.sm,
    this.runSpacing = AppSpacing.sm,
    this.compactBreakpoint = 360,
    this.alignment = WrapAlignment.start,
    this.fillRows = false,
    super.key,
  });

  final List<Widget> children;
  final int maxColumns;
  final double? maxItemWidth;
  final double spacing;
  final double runSpacing;
  final double compactBreakpoint;
  final WrapAlignment alignment;
  final bool fillRows;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        if (!maxWidth.isFinite) {
          return Wrap(
            alignment: alignment,
            spacing: spacing,
            runSpacing: runSpacing,
            children: children,
          );
        }

        final columns = maxWidth < compactBreakpoint
            ? 1
            : math.min(math.max(maxColumns, 1), children.length);
        if (fillRows) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < children.length; index += columns)
                Padding(
                  padding: EdgeInsets.only(
                    bottom: index + columns < children.length ? runSpacing : 0,
                  ),
                  child: Row(
                    children: [
                      for (
                        var column = 0;
                        column < columns && index + column < children.length;
                        column += 1
                      ) ...[
                        if (column > 0) SizedBox(width: spacing),
                        Expanded(child: children[index + column]),
                      ],
                    ],
                  ),
                ),
            ],
          );
        }

        final naturalItemWidth =
            (maxWidth - (spacing * (columns - 1))) / columns;
        final itemWidth = maxWidth < compactBreakpoint
            ? maxWidth
            : math.min(naturalItemWidth, maxItemWidth ?? naturalItemWidth);

        return Wrap(
          alignment: alignment,
          spacing: spacing,
          runSpacing: runSpacing,
          children: [
            for (final child in children)
              SizedBox(width: itemWidth, child: child),
          ],
        );
      },
    );
  }
}
