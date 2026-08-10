import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_error_mapper.dart';

void main() {
  DioException dioError({
    required DioExceptionType type,
    int? statusCode,
    Object? data,
  }) {
    final requestOptions = RequestOptions(path: '/api/v1/auth/login');
    return DioException(
      requestOptions: requestOptions,
      type: type,
      response: statusCode == null
          ? null
          : Response<dynamic>(
              requestOptions: requestOptions,
              statusCode: statusCode,
              data: data,
            ),
    );
  }

  test('maps 401 to wrong password message', () {
    final failure = mapAuthDioException(
      dioError(type: DioExceptionType.badResponse, statusCode: 401),
      fallbackMessage: 'fallback',
    );
    expect(failure.message, 'Wrong email or password.');
  });

  test('maps a coded email conflict to duplicate email guidance', () {
    final failure = mapAuthDioException(
      dioError(
        type: DioExceptionType.badResponse,
        statusCode: 409,
        data: <String, dynamic>{
          'message': 'An account already uses this email address.',
          'error': <String, dynamic>{'code': 'EMAIL_ALREADY_IN_USE'},
        },
      ),
      fallbackMessage: 'fallback',
    );
    expect(failure.message, 'An account already uses this email address.');
    expect(failure.code, 'duplicate_email');
  });

  test('maps a coded phone conflict to duplicate phone guidance', () {
    final failure = mapAuthDioException(
      dioError(
        type: DioExceptionType.badResponse,
        statusCode: 409,
        data: <String, dynamic>{
          'message': 'An account already uses this mobile number.',
          'error': <String, dynamic>{'code': 'PHONE_ALREADY_IN_USE'},
        },
      ),
      fallbackMessage: 'fallback',
    );
    expect(failure.message, 'An account already uses this mobile number.');
    expect(failure.code, 'duplicate_phone');
  });

  test('maps the three-account phone cap to the phone field', () {
    final failure = mapAuthDioException(
      dioError(
        type: DioExceptionType.badResponse,
        statusCode: 409,
        data: <String, dynamic>{
          'message':
              'This mobile number is already used by the maximum of 3 accounts. Use another Lebanese mobile number.',
          'error': <String, dynamic>{'code': 'PHONE_ACCOUNT_LIMIT_REACHED'},
        },
      ),
      fallbackMessage: 'fallback',
    );

    expect(failure.code, 'phone_account_limit');
    expect(failure.message, contains('maximum of 3 accounts'));
  });

  test('maps blocked account message from backend', () {
    final failure = mapAuthDioException(
      dioError(
        type: DioExceptionType.badResponse,
        statusCode: 403,
        data: <String, dynamic>{'message': 'Your account has been blocked.'},
      ),
      fallbackMessage: 'fallback',
    );
    expect(failure.message, 'Your account has been blocked.');
  });

  test('maps pending contributor message from backend', () {
    final failure = mapAuthDioException(
      dioError(
        type: DioExceptionType.badResponse,
        statusCode: 403,
        data: <String, dynamic>{
          'message':
              'Your contributor request is still pending approval. You cannot log in yet.',
        },
      ),
      fallbackMessage: 'fallback',
    );
    expect(
      failure.message,
      'Your contributor request is still pending approval. You cannot log in yet.',
    );
  });

  test('maps rejected contributor message from backend', () {
    final failure = mapAuthDioException(
      dioError(
        type: DioExceptionType.badResponse,
        statusCode: 403,
        data: <String, dynamic>{
          'message':
              'Your contributor request was rejected. You cannot log in with contributor access.',
        },
      ),
      fallbackMessage: 'fallback',
    );
    expect(
      failure.message,
      'Your contributor request was rejected. You cannot log in with contributor access.',
    );
  });

  test('maps inactive message from backend', () {
    final failure = mapAuthDioException(
      dioError(
        type: DioExceptionType.badResponse,
        statusCode: 403,
        data: <String, dynamic>{'message': 'This account is inactive.'},
      ),
      fallbackMessage: 'fallback',
    );
    expect(failure.message, 'This account is inactive.');
  });

  test('maps 422 using response message when present', () {
    final failure = mapAuthDioException(
      dioError(
        type: DioExceptionType.badResponse,
        statusCode: 422,
        data: <String, dynamic>{'message': 'Password policy violation'},
      ),
      fallbackMessage: 'fallback',
    );
    expect(failure.message, 'Password policy violation');
  });

  test('maps 400 validation failure using the first field error message', () {
    final failure = mapAuthDioException(
      dioError(
        type: DioExceptionType.badResponse,
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
      fallbackMessage: 'fallback',
    );

    expect(failure.message, 'Enter a valid phone number.');
    expect(failure.code, 'validation_error');
  });

  test('maps timeouts to connectivity guidance', () {
    final failure = mapAuthDioException(
      dioError(type: DioExceptionType.connectionTimeout),
      fallbackMessage: 'fallback',
    );
    expect(
      failure.message,
      'Sign-in timed out. Check your connection and try again. If you are using a real Android device against the local API, 10.0.2.2 only works on the emulator. Use your computer\'s LAN IP in API_BASE_URL.',
    );
  });

  test('maps offline sign-in attempts to a direct reconnect message', () {
    final failure = mapAuthDioException(
      dioError(type: DioExceptionType.connectionError),
      fallbackMessage: 'fallback',
    );

    expect(
      failure.message,
      'You are offline. New sign-in requires internet access. Reconnect and try again. If you are using a real Android device against the local API, 10.0.2.2 only works on the emulator. Use your computer\'s LAN IP in API_BASE_URL.',
    );
  });

  test('maps 503 reset email failures to professional delivery copy', () {
    final failure = mapAuthDioException(
      dioError(
        type: DioExceptionType.badResponse,
        statusCode: 503,
        data: <String, dynamic>{'message': 'SMTP relay rejected recipient.'},
      ),
      fallbackMessage: 'fallback',
    );
    expect(failure.message, 'SMTP relay rejected recipient.');
  });

  test('maps 503 reset mode failures using backend copy', () {
    final failure = mapAuthDioException(
      dioError(
        type: DioExceptionType.badResponse,
        statusCode: 503,
        data: <String, dynamic>{
          'message':
              'Email delivery is not configured for real password reset yet. Please contact support.',
        },
      ),
      fallbackMessage: 'fallback',
    );

    expect(
      failure.message,
      'Email delivery is not configured for real password reset yet. Please contact support.',
    );
  });
}
