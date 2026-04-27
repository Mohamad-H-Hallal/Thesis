import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/network/api_client.dart';
import 'package:lebanese_gis_mobile/features/notifications/data/api_notifications_repository.dart';

void main() {
  group('ApiNotificationsRepository', () {
    test('reads unread_count from the notifications count endpoint', () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:3000'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path.endsWith('/notifications/unread/count')) {
              handler.resolve(
                Response<Map<String, dynamic>>(
                  requestOptions: options,
                  statusCode: 200,
                  data: const <String, dynamic>{
                    'success': true,
                    'data': <String, dynamic>{'unread_count': 4},
                  },
                ),
              );
              return;
            }
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.badResponse,
                response: Response<dynamic>(
                  requestOptions: options,
                  statusCode: 404,
                  data: const <String, dynamic>{
                    'message': 'Unhandled test request',
                  },
                ),
              ),
            );
          },
        ),
      );

      final repository = ApiNotificationsRepository(ApiClient(dio: dio));

      await expectLater(repository.fetchUnreadCount(), completion(4));
    });
  });
}
