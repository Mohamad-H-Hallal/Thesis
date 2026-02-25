import '../../projects/domain/project.dart';

class Phase6Validation {
  const Phase6Validation._();

  static String? validateGeometry({
    required String geometryType,
    required List<String> allowedGeometryTypes,
    required double? latitude,
    required double? longitude,
    required double? gpsAccuracyMeters,
    required double maxGpsAccuracyMeters,
  }) {
    if (!allowedGeometryTypes.contains(geometryType)) {
      return 'Geometry type is not allowed for this project.';
    }

    if (latitude == null || longitude == null) {
      return 'Capture coordinates before continuing.';
    }

    if (latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      return 'Captured coordinates are out of valid range.';
    }

    if (gpsAccuracyMeters == null || gpsAccuracyMeters <= 0) {
      return 'GPS accuracy is required.';
    }

    if (gpsAccuracyMeters > maxGpsAccuracyMeters) {
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
