import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/sync/sync_retry_policy.dart';

void main() {
  test('backoff doubles and is capped', () {
    expect(SyncRetryPolicy.backoffForAttempt(1).inSeconds, 10);
    expect(SyncRetryPolicy.backoffForAttempt(2).inSeconds, 20);
    expect(SyncRetryPolicy.backoffForAttempt(3).inSeconds, 40);
    expect(SyncRetryPolicy.backoffForAttempt(8).inSeconds, 300);
    expect(SyncRetryPolicy.backoffForAttempt(20).inSeconds, 300);
  });

  test('dead-letter threshold is enforced at max attempts', () {
    expect(
      SyncRetryPolicy.shouldDeadLetter(SyncRetryPolicy.maxAttempts - 1),
      isFalse,
    );
    expect(
      SyncRetryPolicy.shouldDeadLetter(SyncRetryPolicy.maxAttempts),
      isTrue,
    );
    expect(
      SyncRetryPolicy.shouldDeadLetter(SyncRetryPolicy.maxAttempts + 3),
      isTrue,
    );
  });
}
