enum RealtimeConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
  offline,
  resyncing,
}

class RealtimeScope {
  const RealtimeScope(this.scopeType, this.scopeId);

  final String scopeType;
  final String scopeId;

  String get key => '$scopeType:$scopeId';

  Map<String, Object> toJson() => <String, Object>{
    'scopeType': scopeType,
    'scopeId': scopeId,
  };

  static RealtimeScope? tryParse(Object? value) {
    if (value is! Map) {
      return null;
    }
    final scopeType = value['scopeType']?.toString().trim() ?? '';
    final scopeId = value['scopeId']?.toString().trim() ?? '';
    if (scopeType.isEmpty || scopeId.isEmpty) {
      return null;
    }
    return RealtimeScope(scopeType, scopeId);
  }

  @override
  bool operator ==(Object other) =>
      other is RealtimeScope &&
      other.scopeType == scopeType &&
      other.scopeId == scopeId;

  @override
  int get hashCode => Object.hash(scopeType, scopeId);
}

class RealtimeKnownRevision {
  const RealtimeKnownRevision({required this.scope, required this.revision});

  final RealtimeScope scope;
  final int revision;

  Map<String, Object> toJson() => <String, Object>{
    ...scope.toJson(),
    'revision': revision,
  };

  static RealtimeKnownRevision? tryParse(Object? value) {
    final scope = RealtimeScope.tryParse(value);
    if (scope == null || value is! Map) {
      return null;
    }
    final revision = int.tryParse(value['revision']?.toString() ?? '');
    if (revision == null || revision < 0) {
      return null;
    }
    return RealtimeKnownRevision(scope: scope, revision: revision);
  }
}

class RealtimeDomainEvent {
  const RealtimeDomainEvent({
    required this.protocolVersion,
    required this.eventId,
    required this.type,
    required this.action,
    required this.scope,
    required this.entityType,
    required this.revision,
    required this.occurredAt,
    required this.originatedByCurrentSession,
    this.entityId,
    this.projectId,
  });

  final int protocolVersion;
  final String eventId;
  final String type;
  final String action;
  final RealtimeScope scope;
  final String entityType;
  final String? entityId;
  final String? projectId;
  final int revision;
  final DateTime occurredAt;
  final bool originatedByCurrentSession;

  static RealtimeDomainEvent? tryParse(Map<String, dynamic> value) {
    if (value['type'] != 'domain_changed') {
      return null;
    }
    final protocolVersion = int.tryParse(
      value['protocolVersion']?.toString() ?? '',
    );
    final eventId = value['eventId']?.toString().trim() ?? '';
    final action = value['action']?.toString().trim() ?? '';
    final entityType = value['entityType']?.toString().trim() ?? '';
    final scope = RealtimeScope.tryParse(value);
    final revision = int.tryParse(value['revision']?.toString() ?? '');
    final occurredAt = DateTime.tryParse(value['occurredAt']?.toString() ?? '');
    if (protocolVersion != 1 ||
        eventId.isEmpty ||
        action.isEmpty ||
        entityType.isEmpty ||
        scope == null ||
        revision == null ||
        revision < 1 ||
        occurredAt == null) {
      return null;
    }
    return RealtimeDomainEvent(
      protocolVersion: protocolVersion!,
      eventId: eventId,
      type: 'domain_changed',
      action: action,
      scope: scope,
      entityType: entityType,
      entityId: value['entityId']?.toString(),
      projectId: value['projectId']?.toString(),
      revision: revision,
      occurredAt: occurredAt,
      originatedByCurrentSession: value['originatedByCurrentSession'] == true,
    );
  }
}
