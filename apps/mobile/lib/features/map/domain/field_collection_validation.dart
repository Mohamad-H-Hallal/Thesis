import '../../projects/domain/project.dart';
import '../../auth/presentation/utils/auth_form_validators.dart';
import '../../../core/utils/lebanese_phone.dart';
import 'package:latlong2/latlong.dart';

class Phase6Validation {
  const Phase6Validation._();

  static String? validateGeometry({
    required String geometryType,
    required List<String> allowedGeometryTypes,
    required List<LatLng> vertices,
    double? gpsAccuracyMeters,
    required double maxGpsAccuracyMeters,
  }) {
    if (!allowedGeometryTypes.contains(geometryType)) {
      return 'Geometry type is not allowed for this project.';
    }

    switch (geometryType) {
      case 'Point':
        if (vertices.length != 1) {
          return 'Place one point on the map before continuing.';
        }
        break;
      case 'LineString':
        if (vertices.length < 2) {
          return 'Add at least two vertices to draw a line.';
        }
        break;
      case 'Polygon':
        if (vertices.length < 3) {
          return 'Add at least three vertices to draw a polygon.';
        }
        break;
    }

    for (final vertex in vertices) {
      if (vertex.latitude < -90 ||
          vertex.latitude > 90 ||
          vertex.longitude < -180 ||
          vertex.longitude > 180) {
        return 'Captured coordinates are out of valid range.';
      }
    }

    if (gpsAccuracyMeters != null && gpsAccuracyMeters > maxGpsAccuracyMeters) {
      return 'GPS accuracy (${gpsAccuracyMeters.toStringAsFixed(1)}m) is above allowed threshold (${maxGpsAccuracyMeters.toStringAsFixed(1)}m).';
    }

    return null;
  }

  static Map<String, String> validateAttributes({
    required CollectionFormSchema schema,
    required Map<String, dynamic> values,
  }) {
    final errors = <String, String>{};

    for (final field in schema.fields) {
      final value = values[field.key];

      if (field.required) {
        final isEmptyString = value is String && value.trim().isEmpty;
        if (value == null || isEmptyString) {
          errors[field.key] = '${field.label} is required.';
          continue;
        }
      }

      if (value == null) {
        continue;
      }

      if (field.type == CollectionFieldType.number) {
        final numberValue = value is num ? value : num.tryParse('$value');
        if (numberValue == null) {
          errors[field.key] = '${field.label} must be numeric.';
          continue;
        }
        if (field.min != null && numberValue < field.min!) {
          errors[field.key] = '${field.label} must be >= ${field.min}.';
        } else if (field.max != null && numberValue > field.max!) {
          errors[field.key] = '${field.label} must be <= ${field.max}.';
        }
      }

      if (field.type == CollectionFieldType.select &&
          field.options.isNotEmpty &&
          !field.options.contains('$value')) {
        errors[field.key] = '${field.label} has an invalid option.';
      }

      if (field.type == CollectionFieldType.email && value is String) {
        final emailError = AuthFormValidators.email(value);
        if (emailError != null) {
          errors[field.key] = 'Enter a valid email address.';
        }
      }

      if (field.type == CollectionFieldType.lebaneseMobile &&
          value is String &&
          !LebanesePhone.isValid(value)) {
        errors[field.key] = 'Enter a valid Lebanese mobile number.';
      }
    }

    return errors;
  }

  static String? validatePhotoCount({
    required bool requiresPhotos,
    required int minPhotos,
    required int maxPhotos,
    required int actualPhotos,
  }) {
    if (requiresPhotos && actualPhotos < minPhotos) {
      return 'At least $minPhotos photo(s) are required.';
    }
    if (actualPhotos > maxPhotos) {
      return 'Photo limit exceeded. Maximum allowed: $maxPhotos.';
    }
    return null;
  }

  static String gpsQualityLabel(double? accuracyMeters) {
    if (accuracyMeters == null || accuracyMeters <= 0) {
      return 'Unknown';
    }
    if (accuracyMeters <= 5) {
      return 'Excellent';
    }
    if (accuracyMeters <= 10) {
      return 'Good';
    }
    if (accuracyMeters <= 20) {
      return 'Fair';
    }
    return 'Poor';
  }
}
