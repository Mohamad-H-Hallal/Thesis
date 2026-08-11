import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/network/api_client.dart';
import 'package:lebanese_gis_mobile/core/providers/providers.dart';
import 'package:lebanese_gis_mobile/features/auth/data/contact_verification_repository.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/screens/contact_verification_screen.dart';

class _MemorySecureStorage extends FlutterSecureStorage {
  _MemorySecureStorage(this._values);
  final Map<String, String> _values;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _values.remove(key);
  }
}

class _VerificationAdapter implements HttpClientAdapter {
  int statusRequests = 0;
  int sendRequests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.endsWith('/verification/status')) statusRequests += 1;
    if (options.path.endsWith('/verification/email/send')) sendRequests += 1;
    return ResponseBody.fromString(
      jsonEncode({
        'success': true,
        'message': 'A verification code has been sent.',
        'data': {
          'verification': {
            'account_status': 'pending_verification',
            'email_verified': false,
            'phone_verified': false,
            'next_step': 'email',
            'masked_email': 'm***@example.com',
            'masked_phone': '+961 70 *** ***',
            'expires_at': DateTime.now()
                .add(const Duration(minutes: 5))
                .toIso8601String(),
            'resend_after_seconds': 60,
          },
        },
      }),
      200,
      headers: const {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  testWidgets('restores pending verification and renders masked email state', (
    tester,
  ) async {
    final storage = _MemorySecureStorage({
      ContactVerificationRepository.pendingTokenKey: 'limited-token',
    });
    final adapter = _VerificationAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final apiClient = ApiClient(dio: dio, storage: storage);
    final repository = ContactVerificationRepository(storage, apiClient);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          contactVerificationRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(home: ContactVerificationScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Verify your email'), findsOneWidget);
    expect(find.textContaining('m***@example.com'), findsOneWidget);
    expect(
      find.textContaining('Verification requires an internet connection'),
      findsOneWidget,
    );
    expect(adapter.statusRequests, 1);
    expect(adapter.sendRequests, 0);

    await tester.enterText(find.byType(TextFormField), '123');
    await tester.tap(find.text('Verify code'));
    await tester.pump();
    expect(find.text('Enter the 6-digit verification code.'), findsOneWidget);
  });
}
