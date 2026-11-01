import 'dart:math';

/// Exponential backoff with jitter: 50%..100% of the capped exponential.
int backoffDelay(int attempt, {int baseMs = 1000, int maxMs = 30000, double Function()? random}) {
  final cap = min(maxMs, baseMs * (1 << min(attempt, 20)));
  return (cap * (0.5 + 0.5 * (random ?? Random().nextDouble)())).round();
}

/// Network failure, timeout, rate limit, server errors.
bool isRetryable(int status) => status == 0 || status == 408 || status == 429 || status >= 500;
