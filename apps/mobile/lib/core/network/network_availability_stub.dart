import 'network_availability_base.dart';

class DefaultNetworkAvailabilityService implements NetworkAvailabilityService {
  const DefaultNetworkAvailabilityService();

  @override
  Stream<bool> get onOnlineStatusChanged => const Stream<bool>.empty();

  @override
  Future<bool> isOnline() async => true;
}

NetworkAvailabilityService createPlatformNetworkAvailabilityService() {
  return const DefaultNetworkAvailabilityService();
}
