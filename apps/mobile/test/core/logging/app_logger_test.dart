import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/logging/app_logger.dart';

void main() {
  test('sanitizes credentials and personal contact values', () {
    final sanitized = AppLogger.sanitizeForLogging(
      'password=Secret123! Authorization: Bearer eyJabc.def.ghi '
      'email=admin@example.com phone=+96170123456',
    );

    expect(sanitized, isNot(contains('Secret123!')));
    expect(sanitized, isNot(contains('eyJabc.def.ghi')));
    expect(sanitized, isNot(contains('admin@example.com')));
    expect(sanitized, isNot(contains('+96170123456')));
    expect(sanitized, contains('[REDACTED]'));
  });
}
