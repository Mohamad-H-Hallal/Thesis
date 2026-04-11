import 'package:flutter/material.dart';

class AnimatedReveal extends StatelessWidget {
  const AnimatedReveal({
    required this.child,
    this.duration = const Duration(milliseconds: 360),
    this.delay = Duration.zero,
    this.offsetY = 10,
    super.key,
  });

  final Widget child;
  final Duration duration;
  final Duration delay;
  final double offsetY;

  @override
  Widget build(BuildContext context) {
    // Scrollable screens build children lazily; fading them on first build
    // makes content look dull while the user scrolls. Keep the wrapper, but
    // render immediately so shared screens stay visually stable.
    return child;
  }
}
