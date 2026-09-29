import 'dart:async';

/// 等待 flutter_blue_plus 的异步扫描真正停止。
class BleScanLifecycle {
  const BleScanLifecycle._();

  static Future<void> waitUntilStopped({
    required bool scanningNow,
    required Stream<bool> scanningStates,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    // startScan 返回时原生扫描状态可能还没有同步到 isScanningNow。
    // 因此不能把 false 当成“已经结束”，必须等到本轮出现 true 后再等 false。
    var started = scanningNow;
    final stopped = Completer<void>();
    late final StreamSubscription<bool> subscription;
    subscription = scanningStates.listen((scanning) {
      if (scanning) {
        started = true;
      } else if (started && !stopped.isCompleted) {
        stopped.complete();
      }
    });
    try {
      // 某些 Android 蓝牙栈偶尔不发送状态事件，超时后交给上层清理，
      // 但不能在扫描刚启动时立即标记完成。
      await stopped.future.timeout(timeout);
    } on TimeoutException {
      // 原生扫描通常会由 timeout 自动停止；缺少状态事件时允许流程收尾。
    } finally {
      await subscription.cancel();
    }
  }
}
