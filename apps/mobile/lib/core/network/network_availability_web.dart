import 'package:connectivity_plus/connectivity_plus.dart';

import 'network_availability_base.dart';

class WebNetworkAvailabilityService implements NetworkAvailabilityService {
  WebNetworkAvailabilityService({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  @override
  Stream<bool> get onOnlineStatusChanged {
    return _connectivity.onConnectivityChanged
        .map(_hasNetworkInterface)
        .distinct();
  }

  @override
  Future<bool> isOnline() async {
    final connectivity = await _connectivity.checkConnectivity();
    return _hasNetworkInterface(connectivity);
  }

  bool _hasNetworkInterface(List<ConnectivityResult> results) {
    return results.any((result) => result != ConnectivityResult.none);
  }
}

NetworkAvailabilityService createPlatformNetworkAvailabilityService() {
  return WebNetworkAvailabilityService();
}
