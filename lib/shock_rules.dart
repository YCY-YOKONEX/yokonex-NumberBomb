import 'game_engine.dart';

const shockIntensityMin = 0;
const shockIntensityMax = 180;
const shockIntensityStep = 5;

// 每次答错只影响下一次输出，达到设备支持的界面上限后保持不变。
int nextShockIntensity(int current) {
  final next = current + shockIntensityStep;
  if (next > shockIntensityMax) return shockIntensityMax;
  if (next < shockIntensityMin) return shockIntensityMin;
  return next;
}

Duration? shockDurationFor({
  required Rule rule,
  required bool hit,
  required bool gameFinished,
  bool eliminated = false,
  bool timeout = false,
}) {
  // 超时按一次普通失误处理，所有模式统一输出 2 秒。
  if (timeout) return const Duration(seconds: 2);
  if (hit || gameFinished) return const Duration(seconds: 10);
  return switch (rule) {
    Rule.bomb => null,
    Rule.wrongPenalty => const Duration(seconds: 2),
    Rule.elimination => eliminated ? const Duration(seconds: 10) : null,
  };
}
