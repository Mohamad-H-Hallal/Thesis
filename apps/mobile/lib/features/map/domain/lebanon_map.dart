import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

enum LebanonBasemapStyle { satellite, street }

class LebanonMapConfig {
  const LebanonMapConfig._();

  static const LatLng southWest = LatLng(33.045, 35.094);
  static const LatLng northEast = LatLng(34.695, 36.645);

  static final LatLngBounds bounds = LatLngBounds(southWest, northEast);
  static final LatLng center = LatLng(
    (southWest.latitude + northEast.latitude) / 2,
    (southWest.longitude + northEast.longitude) / 2,
  );

  static const double quickMinZoom = 7.0;
  static const double quickMaxZoom = 16.0;
  static const double quickInitialZoom = 7.4;
  static const double fullscreenMinZoom = 7.0;
  static const double fullscreenMaxZoom = 18.5;
  static const double fullscreenInitialZoom = 7.4;
  static const double projectWorkspaceZoom = 8.2;
  static const double drawingMinZoom = 8.0;
  static const double drawingMaxZoom = 19.0;
  static const double drawingInitialZoom = 8.5;

  static final CameraConstraint cameraConstraint = CameraConstraint.contain(
    bounds: bounds,
  );

  static final CameraFit quickFit = CameraFit.bounds(
    bounds: bounds,
    padding: const EdgeInsets.all(20),
  );

  static final CameraFit fullscreenFit = CameraFit.bounds(
    bounds: bounds,
    padding: const EdgeInsets.all(22),
  );

  static final CameraFit drawingFit = CameraFit.bounds(
    bounds: bounds,
    padding: const EdgeInsets.all(18),
  );

  static CameraFit lebanonFit({EdgeInsets padding = const EdgeInsets.all(20)}) {
    return CameraFit.bounds(bounds: bounds, padding: padding);
  }

  static bool contains(LatLng point) => bounds.contains(point);

  static String basemapUrlTemplate(LebanonBasemapStyle style) {
    switch (style) {
      case LebanonBasemapStyle.satellite:
        return 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
      case LebanonBasemapStyle.street:
        return 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/{z}/{y}/{x}';
    }
  }

  static String? referenceLabelUrlTemplate(LebanonBasemapStyle style) {
    switch (style) {
      case LebanonBasemapStyle.satellite:
        return 'https://services.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}';
      case LebanonBasemapStyle.street:
        return null;
    }
  }

  static String basemapLabel(LebanonBasemapStyle style) {
    switch (style) {
      case LebanonBasemapStyle.satellite:
        return 'Satellite';
      case LebanonBasemapStyle.street:
        return 'Street';
    }
  }
}
