import 'game_engine.dart';

const shockIntensityMin = 0;
const shockIntensityMax = 180;
const shockIntensityStep = 5;

// 猜错惩罚模式累计失败强度，达到设备支持的界面上限后保持不变。
int nextShockIntensity(int current) {
  final next = current + shockIntensityStep;
  if (next > shockIntensityMax) return shockIntensityMax;
  if (next < shockIntensityMin) return shockIntensityMin;
  return next;
}

int intensityAfterGuess(Rule rule, int current, Guess guess) =>
    rule == Rule.wrongPenalty && !guess.hit
    ? nextShockIntensity(current)
    : current;

// 只有猜中炸弹或本人出局才算输出失败；整局结束不代表获胜者需要受罚。
Duration? shockDurationFor(Guess guess) =>
    guess.hit || guess.eliminated ? const Duration(seconds: 10) : null;
