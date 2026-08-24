class RealtimeEditGuardRegistry {
  final Set<String> _activeEntities = <String>{};

  String _key(String entityType, String entityId) => '$entityType:$entityId';

  void register(String entityType, String entityId) {
    if (entityType.isNotEmpty && entityId.isNotEmpty) {
      _activeEntities.add(_key(entityType, entityId));
    }
  }

  void unregister(String entityType, String entityId) {
    _activeEntities.remove(_key(entityType, entityId));
  }

  bool isEditing(String entityType, String entityId) {
    return _activeEntities.contains(_key(entityType, entityId));
  }
}
