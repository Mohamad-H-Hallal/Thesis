import 'dart:async';

import 'realtime_models.dart';

class RealtimeScopeRegistry {
  final Map<RealtimeScope, int> _registrations = <RealtimeScope, int>{};
  final Map<RealtimeScope, int> _revisions = <RealtimeScope, int>{};
  final StreamController<void> _changes = StreamController<void>.broadcast();

  Stream<void> get changes => _changes.stream;
  Set<RealtimeScope> get scopes =>
      Set<RealtimeScope>.unmodifiable(_registrations.keys);
  List<RealtimeKnownRevision> get knownRevisions => _registrations.keys
      .map(
        (scope) => RealtimeKnownRevision(
          scope: scope,
          revision: _revisions[scope] ?? 0,
        ),
      )
      .toList(growable: false);

  void register(RealtimeScope scope) {
    _registrations.update(scope, (count) => count + 1, ifAbsent: () => 1);
    _notify();
  }

  void unregister(RealtimeScope scope) {
    final count = _registrations[scope];
    if (count == null) {
      return;
    }
    if (count <= 1) {
      _registrations.remove(scope);
    } else {
      _registrations[scope] = count - 1;
    }
    _notify();
  }

  bool setRevision(RealtimeScope scope, int revision) {
    final previous = _revisions[scope] ?? 0;
    if (revision <= previous) {
      return false;
    }
    _revisions[scope] = revision;
    return true;
  }

  int revisionFor(RealtimeScope scope) => _revisions[scope] ?? 0;

  void _notify() {
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }

  Future<void> dispose() => _changes.close();
}
