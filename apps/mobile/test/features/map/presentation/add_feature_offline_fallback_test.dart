import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/features/map/presentation/screens/add_feature_screen.dart';

void main() {
  test('offline draft fallback accepts Dio transport failures', () {
    final error = DioException(
      requestOptions: RequestOptions(path: '/features/drafts'),
      type: DioExceptionType.connectionError,
      error: const SocketException('Connection refused'),
    );

    expect(shouldPersistFeatureDraftLocally(error), isTrue);
  });

  test('offline draft fallback accepts sanitized offline copy', () {
    expect(
      shouldPersistFeatureDraftLocally(
        'Unable to reach the server right now. Please try again.',
      ),
      isTrue,
    );
  });

  test('offline draft fallback rejects validation failures', () {
    final error = DioException(
      requestOptions: RequestOptions(path: '/features/drafts'),
      response: Response<dynamic>(
        requestOptions: RequestOptions(path: '/features/drafts'),
        statusCode: 400,
        data: <String, dynamic>{'message': 'Validation failed'},
      ),
      type: DioExceptionType.badResponse,
    );

    expect(shouldPersistFeatureDraftLocally(error), isFalse);
  });
}
