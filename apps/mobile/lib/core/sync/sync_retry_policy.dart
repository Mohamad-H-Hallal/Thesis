import 'dart:math';

class SyncRetryPolicy {
  const SyncRetryPolicy._();

  static const int maxAttempts = 5;

  static Duration backoffForAttempt(int attempt) {
    final safeAttempt = max(1, attempt);
    final seconds = min(pow(2, safeAttempt).toInt() * 5, 300);
    return Duration(seconds: seconds);
  }

  static bool shouldDeadLetter(int attempt) {
    return attempt >= maxAttempts;
  }
}
