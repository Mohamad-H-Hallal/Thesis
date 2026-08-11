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
          data: <String, dynamic>{'message': 'limit must be between 1 and 100'},
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

    test('extracts field-level validation messages when available', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/auth/register'),
        response: Response<dynamic>(
          requestOptions: RequestOptions(path: '/auth/register'),
          statusCode: 400,
          data: <String, dynamic>{
            'message': 'Validation failed',
            'errors': <Map<String, dynamic>>[
              <String, dynamic>{
                'msg': 'Enter a valid phone number.',
                'path': 'phone',
              },
            ],
          },
        ),
      );

      expect(
        userFacingErrorMessage(
          error,
          fallback: 'Unable to create this account right now.',
        ),
        'Enter a valid phone number.',
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

    test('maps rate limits to calm retry-later copy', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/users'),
        response: Response<dynamic>(
          requestOptions: RequestOptions(path: '/users'),
          statusCode: 429,
          data: <String, dynamic>{
            'message': 'Too many requests from this IP, please try again later',
          },
        ),
      );

      expect(
        userFacingErrorMessage(
          error,
          fallback: 'Unable to load users right now. Please try again.',
        ),
        'Requests are temporarily limited. Please wait a moment and try again.',
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

    test('does not expose internal state diagnostics', () {
      expect(
        userFacingErrorMessage(
          StateError(
            'The project feature response did not match the active project.',
          ),
          fallback: 'Unable to load the project preview map right now.',
        ),
        'Unable to load the project preview map right now.',
      );
    });
  });
}
