import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/features/exports/presentation/export_request_validation.dart';

void main() {
  group('validateExportDateInput', () {
    test('accepts empty values', () {
      expect(validateExportDateInput('From date', ''), isNull);
    });

    test('rejects non ISO format', () {
      expect(
        validateExportDateInput('From date', '13/04/2026'),
        'From date must use YYYY-MM-DD.',
      );
    });

    test('rejects invalid calendar date', () {
      expect(
        validateExportDateInput('To date', '2026-02-30'),
        'To date must use a real calendar date in YYYY-MM-DD.',
      );
    });

    test('accepts a valid date', () {
      expect(validateExportDateInput('From date', '2026-04-13'), isNull);
    });
  });

  group('validateExportDateRange', () {
    test('accepts missing date pair', () {
      expect(validateExportDateRange('', '2026-04-13'), isNull);
      expect(validateExportDateRange('2026-04-13', ''), isNull);
    });

    test('rejects reversed range', () {
      expect(
        validateExportDateRange('2026-04-13', '2026-04-12'),
        'To date must be the same day or later than From date.',
      );
    });

    test('accepts same day or later', () {
      expect(validateExportDateRange('2026-04-13', '2026-04-13'), isNull);
      expect(validateExportDateRange('2026-04-13', '2026-04-20'), isNull);
    });
  });

  group('validateExportBboxInput', () {
    test('accepts empty values', () {
      expect(validateExportBboxInput(''), isNull);
    });

    test('rejects wrong part count', () {
      expect(
        validateExportBboxInput('35.1,33.1,36.0'),
        'BBOX must use minLon,minLat,maxLon,maxLat.',
      );
    });

    test('rejects non numeric values', () {
      expect(
        validateExportBboxInput('35.1,33.1,abc,34.6'),
        'BBOX must use numeric values in minLon,minLat,maxLon,maxLat.',
      );
    });

    test('rejects reversed min max values', () {
      expect(
        validateExportBboxInput('36.0,33.1,35.1,34.6'),
        'BBOX must keep min values smaller than max values.',
      );
    });

    test('accepts a valid bbox', () {
      expect(validateExportBboxInput('35.1,33.1,36.0,34.6'), isNull);
    });
  });
}
