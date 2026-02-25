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
    return TweenAnimationBuilder<double>(
      duration: duration + delay,
      tween: Tween<double>(begin: 0, end: 1),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) {
        final revealProgress = delay == Duration.zero
            ? value
            : ((value -
                      (delay.inMilliseconds /
                          (duration + delay).inMilliseconds))
                  .clamp(0.0, 1.0)
                  .toDouble());

        return Opacity(
          opacity: revealProgress,
          child: Transform.translate(
            offset: Offset(0, (1 - revealProgress) * offsetY),
            child: child,
          ),
        );
      },
    );
  }
}
