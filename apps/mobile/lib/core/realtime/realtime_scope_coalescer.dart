import 'dart:async';

import 'realtime_models.dart';

class RealtimeScopeCoalescer {
  RealtimeScopeCoalescer({
    required this.onRefresh,
    this.window = const Duration(milliseconds: 175),
  });

  final void Function(RealtimeScope scope) onRefresh;
  final Duration window;
  final Map<RealtimeScope, Timer> _timers = <RealtimeScope, Timer>{};

  int get pendingScopeCount => _timers.length;

  void schedule(RealtimeScope scope) {
    _timers[scope]?.cancel();
    _timers[scope] = Timer(window, () {
      _timers.remove(scope);
      onRefresh(scope);
    });
  }

  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }
}
