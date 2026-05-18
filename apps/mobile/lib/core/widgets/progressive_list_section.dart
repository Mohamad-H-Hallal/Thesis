import 'package:flutter/material.dart';

import '../constants/design_tokens.dart';

class ProgressiveListSection<T> extends StatefulWidget {
  const ProgressiveListSection({
    required this.items,
    required this.itemBuilder,
    required this.resetKey,
    this.initialCount = 20,
    this.step = 20,
    this.padding = const EdgeInsets.only(bottom: AppSpacing.sm),
    this.hasMore,
    this.isLoadingMore = false,
    this.onLoadMore,
    this.gridMinItemWidth,
    super.key,
  });

  final List<T> items;
  final Widget Function(BuildContext context, T item, int index) itemBuilder;
  final Object resetKey;
  final int initialCount;
  final int step;
  final EdgeInsetsGeometry padding;
  final bool? hasMore;
  final bool isLoadingMore;
  final Future<void> Function()? onLoadMore;
  final double? gridMinItemWidth;

  @override
  State<ProgressiveListSection<T>> createState() =>
      _ProgressiveListSectionState<T>();
}

class _ProgressiveListSectionState<T> extends State<ProgressiveListSection<T>> {
  late int _visibleCount;

  @override
  void initState() {
    super.initState();
    _visibleCount = _clampVisibleCount(
      widget.initialCount,
      widget.items.length,
    );
  }

  @override
  void didUpdateWidget(covariant ProgressiveListSection<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetKey != widget.resetKey) {
      _visibleCount = _clampVisibleCount(
        widget.initialCount,
        widget.items.length,
      );
      return;
    }
    if (_visibleCount > widget.items.length) {
      _visibleCount = widget.items.length;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.onLoadMore != null) {
      return _buildItems(
        context,
        visibleCount: widget.items.length,
        footer: _buildLoadMoreFooter(),
      );
    }

    final visibleCount = _visibleCount.clamp(0, widget.items.length);
    final remaining = widget.items.length - visibleCount;

    return _buildItems(
      context,
      visibleCount: visibleCount,
      footer: remaining > 0
          ? Center(
              child: OutlinedButton.icon(
                onPressed: _loadMore,
                icon: const Icon(Icons.expand_more),
                label: const Text('Show more'),
              ),
            )
          : null,
    );
  }

  Widget _buildItems(
    BuildContext context, {
    required int visibleCount,
    Widget? footer,
  }) {
    final gridMinItemWidth = widget.gridMinItemWidth;
    if (gridMinItemWidth == null) {
      return Column(
        children: [
          ...List<Widget>.generate(visibleCount, (index) {
            return Padding(
              padding: widget.padding,
              child: widget.itemBuilder(context, widget.items[index], index),
            );
          }),
          ?footer,
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final gap = AppSpacing.sm;
        final canGrid = constraints.maxWidth >= (gridMinItemWidth * 2) + gap;
        if (!canGrid) {
          return Column(
            children: [
              ...List<Widget>.generate(visibleCount, (index) {
                return Padding(
                  padding: widget.padding,
                  child: widget.itemBuilder(
                    context,
                    widget.items[index],
                    index,
                  ),
                );
              }),
              ?footer,
            ],
          );
        }

        final columns = (constraints.maxWidth / gridMinItemWidth).floor().clamp(
          2,
          3,
        );
        final rows = <Widget>[];
        for (var start = 0; start < visibleCount; start += columns) {
          final end = (start + columns).clamp(0, visibleCount);
          rows.add(
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var index = start; index < start + columns; index++) ...[
                  if (index > start) SizedBox(width: gap),
                  Expanded(
                    child: index < end
                        ? widget.itemBuilder(
                            context,
                            widget.items[index],
                            index,
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          );
        }
        return Column(
          children: [
            for (var index = 0; index < rows.length; index++) ...[
              rows[index],
              if (index != rows.length - 1) SizedBox(height: gap),
            ],
            if (footer != null) ...[
              const SizedBox(height: AppSpacing.sm),
              footer,
            ],
          ],
        );
      },
    );
  }

  Widget? _buildLoadMoreFooter() {
    if (widget.isLoadingMore) {
      return const Padding(
        padding: EdgeInsets.only(bottom: AppSpacing.sm),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (widget.hasMore ?? false) {
      return Center(
        child: OutlinedButton.icon(
          onPressed: widget.onLoadMore,
          icon: const Icon(Icons.expand_more),
          label: const Text('Show more'),
        ),
      );
    }
    return null;
  }

  void _loadMore() {
    setState(() {
      _visibleCount = _clampVisibleCount(
        _visibleCount + widget.step,
        widget.items.length,
      );
    });
  }

  int _clampVisibleCount(int value, int total) {
    if (total <= 0) {
      return 0;
    }
    return value < total ? value : total;
  }
}
