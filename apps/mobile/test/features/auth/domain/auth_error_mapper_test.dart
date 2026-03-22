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

  test('maps 409 to duplicate email message', () {
    final failure = mapAuthDioException(
      dioError(type: DioExceptionType.badResponse, statusCode: 409),
      fallbackMessage: 'fallback',
    );
    expect(failure.message, 'This email is already registered.');
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

  test('maps timeouts to connectivity guidance', () {
    final failure = mapAuthDioException(
      dioError(type: DioExceptionType.connectionTimeout),
      fallbackMessage: 'fallback',
    );
    expect(
      failure.message,
      'Request timed out. Please check your connection and try again.',
    );
  });
}
