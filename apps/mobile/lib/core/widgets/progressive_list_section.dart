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
      return Column(
        children: [
          ...List<Widget>.generate(widget.items.length, (index) {
            return Padding(
              padding: widget.padding,
              child: widget.itemBuilder(context, widget.items[index], index),
            );
          }),
          if (widget.isLoadingMore)
            const Padding(
              padding: EdgeInsets.only(bottom: AppSpacing.sm),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (widget.hasMore ?? false)
            Center(
              child: OutlinedButton.icon(
                onPressed: widget.onLoadMore,
                icon: const Icon(Icons.expand_more),
                label: const Text('Show more'),
              ),
            ),
        ],
      );
    }

    final visibleCount = _visibleCount.clamp(0, widget.items.length);
    final remaining = widget.items.length - visibleCount;

    return Column(
      children: [
        ...List<Widget>.generate(visibleCount, (index) {
          return Padding(
            padding: widget.padding,
            child: widget.itemBuilder(context, widget.items[index], index),
          );
        }),
        if (remaining > 0)
          Center(
            child: OutlinedButton.icon(
              onPressed: _loadMore,
              icon: const Icon(Icons.expand_more),
              label: const Text('Show more'),
            ),
          ),
      ],
    );
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
