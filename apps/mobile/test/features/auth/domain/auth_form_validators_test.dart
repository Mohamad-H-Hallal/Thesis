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
  });
}
