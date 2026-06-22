import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';

import 'network_availability_base.dart';

class IoNetworkAvailabilityService implements NetworkAvailabilityService {
  IoNetworkAvailabilityService({Connectivity? connectivity})
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
    try {
      final connectivity = await _connectivity.checkConnectivity();
      if (!_hasNetworkInterface(connectivity)) {
        return false;
      }
      final result = await InternetAddress.lookup(
        'example.com',
      ).timeout(const Duration(seconds: 2));
      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  bool _hasNetworkInterface(List<ConnectivityResult> results) {
    return results.any((result) => result != ConnectivityResult.none);
  }
}

NetworkAvailabilityService createPlatformNetworkAvailabilityService() {
  return IoNetworkAvailabilityService();
}
