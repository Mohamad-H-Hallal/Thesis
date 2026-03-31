import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/network/api_error_message.dart';

void main() {
  group('userFacingErrorMessage', () {
    test('maps raw pagination validation errors to the fallback copy', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/projects'),
        response: Response<dynamic>(
          requestOptions: RequestOptions(path: '/projects'),
          statusCode: 400,
          data: <String, dynamic>{
            'message': 'limit must be between 1 and 100',
          },
        ),
      );

      expect(
        userFacingErrorMessage(
          error,
          fallback: 'Unable to load projects right now. Please try again.',
        ),
        'Unable to load projects right now. Please try again.',
      );
    });

    test('maps session failures to a sign-in prompt', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/projects'),
        response: Response<dynamic>(
          requestOptions: RequestOptions(path: '/projects'),
          statusCode: 401,
          data: <String, dynamic>{'message': 'Token expired'},
        ),
      );

      expect(
        userFacingErrorMessage(
          error,
          fallback: 'Unable to load projects right now. Please try again.',
        ),
        'Your session may have expired. Please sign in again.',
      );
    });

    test('preserves safe application copy', () {
      expect(
        userFacingErrorMessage(
          'This email is already registered.',
          fallback: 'Something went wrong.',
        ),
        'This email is already registered.',
      );
    });

    test('strips generic exception prefixes from user-facing copy', () {
      expect(
        userFacingErrorMessage(
          Exception('Feature submission failed.'),
          fallback: 'Something went wrong.',
        ),
        'Feature submission failed.',
      );
    });
  });
}
