import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/realtime/realtime_edit_guard.dart';
import 'package:lebanese_gis_mobile/core/realtime/realtime_models.dart';
import 'package:lebanese_gis_mobile/core/realtime/realtime_scope_registry.dart';
import 'package:lebanese_gis_mobile/core/realtime/realtime_scope_coalescer.dart';
import 'package:lebanese_gis_mobile/core/realtime/workflow_realtime_service.dart';

void main() {
  group('realtime protocol models', () {
    test('parses the v1 typed invalidation envelope', () {
      final event = RealtimeDomainEvent.tryParse(<String, dynamic>{
        'protocolVersion': 1,
        'type': 'domain_changed',
        'eventId': 'event-1',
        'action': 'updated',
        'scopeType': 'features',
        'scopeId': 'project-1',
        'entityType': 'feature',
        'entityId': 'feature-1',
        'projectId': 'project-1',
        'revision': 4,
        'occurredAt': '2026-08-11T12:00:00.000Z',
        'originatedByCurrentSession': false,
      });

      expect(event, isNotNull);
      expect(event!.scope, const RealtimeScope('features', 'project-1'));
      expect(event.revision, 4);
      expect(event.entityId, 'feature-1');
    });

    test('rejects malformed versions, revisions, and timestamps', () {
      Map<String, dynamic> payload() => <String, dynamic>{
        'protocolVersion': 1,
        'type': 'domain_changed',
        'eventId': 'event-1',
        'action': 'updated',
        'scopeType': 'project',
        'scopeId': 'project-1',
        'entityType': 'project',
        'revision': 1,
        'occurredAt': '2026-08-11T12:00:00.000Z',
      };

      expect(
        RealtimeDomainEvent.tryParse(payload()..['protocolVersion'] = 2),
        isNull,
      );
      expect(RealtimeDomainEvent.tryParse(payload()..['revision'] = 0), isNull);
      expect(
        RealtimeDomainEvent.tryParse(payload()..['occurredAt'] = 'invalid'),
        isNull,
      );
    });
  });

  group('realtime scope registry', () {
    test(
      'reference-counts visible scopes and ignores duplicate revisions',
      () async {
        final registry = RealtimeScopeRegistry();
        const scope = RealtimeScope('features', 'project-1');

        registry.register(scope);
        registry.register(scope);
        expect(registry.scopes, <RealtimeScope>{scope});
        expect(registry.setRevision(scope, 3), isTrue);
        expect(registry.setRevision(scope, 3), isFalse);
        expect(registry.setRevision(scope, 2), isFalse);
        expect(registry.revisionFor(scope), 3);
        expect(registry.knownRevisions.single.revision, 3);

        registry.unregister(scope);
        expect(registry.scopes, contains(scope));
        registry.unregister(scope);
        expect(registry.scopes, isEmpty);
        await registry.dispose();
      },
    );
  });

  test('edit guards distinguish independently edited entities', () {
    final registry = RealtimeEditGuardRegistry();
    registry.register('feature', 'feature-1');
    registry.register('project', 'project-1');

    expect(registry.isEditing('feature', 'feature-1'), isTrue);
    expect(registry.isEditing('feature', 'feature-2'), isFalse);
    expect(registry.isEditing('project', 'project-1'), isTrue);

    registry.unregister('feature', 'feature-1');
    expect(registry.isEditing('feature', 'feature-1'), isFalse);
    expect(registry.isEditing('project', 'project-1'), isTrue);
  });

  test('coalesces repeated invalidations only within the same scope', () async {
    final refreshed = <RealtimeScope>[];
    final coalescer = RealtimeScopeCoalescer(
      window: const Duration(milliseconds: 10),
      onRefresh: refreshed.add,
    );
    const projectA = RealtimeScope('features', 'project-a');
    const projectB = RealtimeScope('features', 'project-b');

    coalescer.schedule(projectA);
    coalescer.schedule(projectA);
    coalescer.schedule(projectB);
    expect(coalescer.pendingScopeCount, 2);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(refreshed.where((scope) => scope == projectA), hasLength(1));
    expect(refreshed.where((scope) => scope == projectB), hasLength(1));
    coalescer.dispose();
  });

  test('reconnect backoff is exponential, capped, and jittered', () {
    expect(
      realtimeReconnectDelay(attempt: 0, randomValue: 0).inMilliseconds,
      750,
    );
    expect(
      realtimeReconnectDelay(attempt: 1, randomValue: 0.5).inMilliseconds,
      2000,
    );
    expect(
      realtimeReconnectDelay(attempt: 20, randomValue: 1).inMilliseconds,
      37500,
    );
  });
}
