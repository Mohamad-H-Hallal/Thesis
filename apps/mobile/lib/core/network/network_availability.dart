import 'network_availability_stub.dart'
    if (dart.library.io) 'network_availability_io.dart'
    if (dart.library.html) 'network_availability_web.dart';
import 'network_availability_base.dart';

NetworkAvailabilityService createNetworkAvailabilityService() {
  return createPlatformNetworkAvailabilityService();
}
