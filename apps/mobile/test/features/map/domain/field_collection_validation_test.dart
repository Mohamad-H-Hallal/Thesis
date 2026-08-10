import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:lebanese_gis_mobile/features/map/domain/field_collection_validation.dart';
import 'package:lebanese_gis_mobile/features/projects/domain/project.dart';

void main() {
  group('Phase6Validation geometry', () {
    test('accepts valid point with acceptable gps accuracy', () {
      final error = Phase6Validation.validateGeometry(
        geometryType: 'Point',
        allowedGeometryTypes: const <String>['Point', 'Polygon'],
        vertices: const <LatLng>[LatLng(33.92, 35.58)],
        gpsAccuracyMeters: 7.5,
        maxGpsAccuracyMeters: 12,
      );

      expect(error, isNull);
    });

    test('rejects poor gps accuracy', () {
      final error = Phase6Validation.validateGeometry(
        geometryType: 'Point',
        allowedGeometryTypes: const <String>['Point'],
        vertices: const <LatLng>[LatLng(33.92, 35.58)],
        gpsAccuracyMeters: 22,
        maxGpsAccuracyMeters: 12,
      );

      expect(error, contains('above allowed threshold'));
    });
  });

  group('Phase6Validation attributes', () {
    const schema = CollectionFormSchema(
      version: 'v1',
      fields: <CollectionFormFieldSchema>[
        CollectionFormFieldSchema(
          key: 'species',
          label: 'Species',
          type: CollectionFieldType.select,
          required: true,
          options: <String>['Olive', 'Apple'],
        ),
        CollectionFormFieldSchema(
          key: 'age',
          label: 'Age',
          type: CollectionFieldType.number,
          required: true,
          min: 0,
          max: 100,
        ),
      ],
    );

    test('returns errors for missing required and range violations', () {
      final errors = Phase6Validation.validateAttributes(
        schema: schema,
        values: <String, dynamic>{'species': '', 'age': 150},
      );

      expect(errors['species'], contains('required'));
      expect(errors['age'], contains('<= 100'));
    });

    test('passes when values satisfy schema', () {
      final errors = Phase6Validation.validateAttributes(
        schema: schema,
        values: <String, dynamic>{'species': 'Olive', 'age': 24},
      );

      expect(errors, isEmpty);
    });

    test('validates third-party email and Lebanese mobile fields', () {
      const contactSchema = CollectionFormSchema(
        version: 'v2',
        fields: <CollectionFormFieldSchema>[
          CollectionFormFieldSchema(
            key: 'owner_email',
            label: 'Owner email',
            type: CollectionFieldType.email,
          ),
          CollectionFormFieldSchema(
            key: 'owner_mobile',
            label: 'Owner mobile',
            type: CollectionFieldType.lebaneseMobile,
          ),
        ],
      );

      expect(
        Phase6Validation.validateAttributes(
          schema: contactSchema,
          values: const <String, dynamic>{
            'owner_email': 'owner@example.com',
            'owner_mobile': '٠٣ ١٢٣ ٤٥٦',
          },
        ),
        isEmpty,
      );

      final errors = Phase6Validation.validateAttributes(
        schema: contactSchema,
        values: const <String, dynamic>{
          'owner_email': 'not-an-email',
          'owner_mobile': '12 345 678',
        },
      );
      expect(errors['owner_email'], 'Enter a valid email address.');
      expect(errors['owner_mobile'], 'Enter a valid Lebanese mobile number.');
    });
  });

  group('Phase6Validation photos', () {
    test('enforces min and max limits', () {
      final tooFew = Phase6Validation.validatePhotoCount(
        requiresPhotos: true,
        minPhotos: 2,
        maxPhotos: 5,
        actualPhotos: 1,
      );
      expect(tooFew, contains('At least 2'));

      final tooMany = Phase6Validation.validatePhotoCount(
        requiresPhotos: false,
        minPhotos: 0,
        maxPhotos: 3,
        actualPhotos: 5,
      );
      expect(tooMany, contains('Maximum allowed: 3'));

      final valid = Phase6Validation.validatePhotoCount(
        requiresPhotos: true,
        minPhotos: 1,
        maxPhotos: 4,
        actualPhotos: 2,
      );
      expect(valid, isNull);
    });
  });
}
