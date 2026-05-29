import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/utils/lebanon_time.dart';

void main() {
  test('formats user-facing timestamps in Lebanon time with DST', () {
    expect(
      formatLebanonDateTime(DateTime.utc(2026, 5, 22, 18, 53)),
      '2026-05-22 21:53',
    );
    expect(
      formatLebanonDateTime(DateTime.utc(2026, 1, 22, 18, 53)),
      '2026-01-22 20:53',
    );
  });
}
