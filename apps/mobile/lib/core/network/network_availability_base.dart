abstract class NetworkAvailabilityService {
  Future<bool> isOnline();
  Stream<bool> get onOnlineStatusChanged;
}
