import 'package:flutter/material.dart';

import '../constants/design_tokens.dart';

class AppSearchActionBar extends StatelessWidget {
  const AppSearchActionBar({
    this.searchBar,
    this.actions = const <Widget>[],
    this.compactBreakpoint = 560,
    this.searchMinWidth = 280,
    this.searchMaxWidth = 460,
    this.actionWidth = 148,
    this.actionHeight = 48,
    super.key,
  });

  final Widget? searchBar;
  final List<Widget> actions;
  final double compactBreakpoint;
  final double searchMinWidth;
  final double searchMaxWidth;
  final double actionWidth;
  final double actionHeight;

  @override
  Widget build(BuildContext context) {
    final hasSearch = searchBar != null;
    if (!hasSearch && actions.isEmpty) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        if (!maxWidth.isFinite) {
          return Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              if (hasSearch) SizedBox(width: searchMaxWidth, child: searchBar),
              for (final action in actions)
                SizedBox(
                  width: actionWidth,
                  height: actionHeight,
                  child: action,
                ),
            ],
          );
        }

        final actionSpacing = actions.length > 1
            ? AppSpacing.sm * (actions.length - 1)
            : 0.0;
        final actionsWidth = (actions.length * actionWidth) + actionSpacing;
        final searchActionSpacing = hasSearch && actions.isNotEmpty
            ? AppSpacing.sm
            : 0.0;
        final minimumRowWidth =
            (hasSearch ? searchMinWidth : 0.0) +
            searchActionSpacing +
            actionsWidth;
        final shouldStack =
            maxWidth < compactBreakpoint || maxWidth < minimumRowWidth;

        if (shouldStack) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (hasSearch) SizedBox(height: actionHeight, child: searchBar),
              for (var index = 0; index < actions.length; index += 1) ...[
                if (index > 0 || hasSearch)
                  const SizedBox(height: AppSpacing.sm),
                SizedBox(height: actionHeight, child: actions[index]),
              ],
            ],
          );
        }

        return Row(
          children: [
            if (hasSearch)
              Expanded(
                child: SizedBox(height: actionHeight, child: searchBar),
              ),
            if (hasSearch && actions.isNotEmpty)
              const SizedBox(width: AppSpacing.sm),
            for (var index = 0; index < actions.length; index += 1) ...[
              if (index > 0) const SizedBox(width: AppSpacing.sm),
              SizedBox(
                width: actionWidth,
                height: actionHeight,
                child: actions[index],
              ),
            ],
          ],
        );
      },
    );
  }
}
