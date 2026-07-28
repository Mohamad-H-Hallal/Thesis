import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/offline/local_database_migration.dart';

void main() {
  group('SQLCipher version gate', () {
    test('accepts the tested minimum and newer semantic versions', () {
      expect(
        isSqlCipherVersionAllowed(minimumSupportedSqlCipherVersion),
        isTrue,
      );
      expect(isSqlCipherVersionAllowed('4.17.1 community'), isTrue);
      expect(isSqlCipherVersionAllowed('4.18.0'), isTrue);
      expect(isSqlCipherVersionAllowed('5.0.0'), isTrue);
    });

    test('rejects older, malformed, and incomplete versions', () {
      expect(isSqlCipherVersionAllowed('4.16.99'), isFalse);
      expect(isSqlCipherVersionAllowed('3.99.99'), isFalse);
      expect(isSqlCipherVersionAllowed('4.17'), isFalse);
      expect(isSqlCipherVersionAllowed('unknown'), isFalse);
      expect(isSqlCipherVersionAllowed(''), isFalse);
    });
  });
}
