import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/utils/auth_form_validators.dart';

void main() {
  group('AuthFormValidators.email', () {
    test('returns error for invalid email', () {
      expect(AuthFormValidators.email('invalid-email'), isNotNull);
    });

    test('returns null for valid email', () {
      expect(AuthFormValidators.email('collector@gov.lb'), isNull);
    });

    test('accepts plus tags and surrounding whitespace', () {
      expect(
        AuthFormValidators.email('  User.Name+field@Example.COM  '),
        isNull,
      );
    });
  });

  group('AuthFormValidators.password', () {
    test('enforces strong password rules', () {
      expect(AuthFormValidators.password('weakpass'), isNotNull);
      expect(AuthFormValidators.password('StrongPass1!'), isNull);
    });
  });

  group('AuthFormValidators.confirmPassword', () {
    test('matches original password', () {
      expect(
        AuthFormValidators.confirmPassword(
          value: 'StrongPass1!',
          password: 'StrongPass1!',
        ),
        isNull,
      );
      expect(
        AuthFormValidators.confirmPassword(
          value: 'StrongPass1?',
          password: 'StrongPass1!',
        ),
        isNotNull,
      );
    });
  });

  group('AuthFormValidators.phoneOptional', () {
    test('accepts empty or valid digits', () {
      expect(AuthFormValidators.phoneOptional(''), isNull);
      expect(AuthFormValidators.phoneOptional('03123456'), isNull);
      expect(AuthFormValidators.phoneOptional('12ab'), isNotNull);
    });

    test('normalizes Lebanese formats and Eastern Arabic digits', () {
      expect(AuthFormValidators.phoneOptional('70 123 456'), isNull);
      expect(AuthFormValidators.phoneOptional('+961-3-123-456'), isNull);
      expect(AuthFormValidators.phoneOptional('78 712 345'), isNull);
      expect(AuthFormValidators.phoneOptional('79 012 345'), isNull);
      expect(AuthFormValidators.phoneOptional('81 123 456'), isNull);
      expect(
        AuthFormValidators.normalizeLebanesePhone('٠٣ ١٢٣ ٤٥٦'),
        '+9613123456',
      );
    });

    test('rejects invalid prefixes, landlines, and foreign numbers', () {
      expect(AuthFormValidators.phoneOptional('12 345 678'), isNotNull);
      expect(AuthFormValidators.phoneOptional('01 234 567'), isNotNull);
      expect(AuthFormValidators.phoneOptional('+33 6 12 34 56 78'), isNotNull);
    });
  });
}
