import 'package:flutter_test/flutter_test.dart';
import 'package:number_bomb/game_engine.dart';
import 'package:number_bomb/shock_rules.dart';

void main() {
  test('猜错后会收紧范围，猜中后揭示炸弹', () {
    final game = GameEngine(
      minimum: 1,
      maximum: 100,
      rule: Rule.bomb,
      names: const ['你'],
      target: 67,
    );

    final low = game.submit(50);
    expect(low.hint, '炸弹更大');
    expect(game.lower, 51);
    expect(game.upper, 100);

    final high = game.submit(80);
    expect(high.hint, '炸弹更小');
    expect(game.lower, 51);
    expect(game.upper, 79);

    final hit = game.submit(67);
    expect(hit.hit, isTrue);
    expect(game.finished, isTrue);
    expect(game.revealedTarget, 67);
  });

  test('淘汰模式累计达到上限后会跳过出局玩家', () {
    final game = GameEngine(
      minimum: 1,
      maximum: 20,
      rule: Rule.elimination,
      names: const ['甲', '乙', '丙'],
      target: 20,
      missLimit: 2,
    );
    game.submit(1); // 甲
    game.submit(2); // 乙
    game.submit(3); // 丙
    final out = game.submit(4); // 甲第二次失误

    expect(out.eliminated, isTrue);
    expect(game.players.first.eliminated, isTrue);
    expect(game.currentPlayer.name, '乙');
  });

  test('范围只剩一个数字时不会自动结束', () {
    final game = GameEngine(
      minimum: 1,
      maximum: 4,
      rule: Rule.bomb,
      names: const ['你'],
      target: 4,
    );

    final guess = game.submit(3);

    expect(guess.hit, isFalse);
    expect(game.lower, 4);
    expect(game.upper, 4);
    expect(game.remaining, 1);
    expect(game.finished, isFalse);
    expect(game.revealedTarget, isNull);
  });

  test('输入超时只记录失误，不改变范围，并轮换玩家', () {
    final game = GameEngine(
      minimum: 1,
      maximum: 20,
      rule: Rule.bomb,
      names: const ['甲', '乙'],
      target: 12,
    );

    final timeout = game.submitTimeout();

    expect(timeout.timeout, isTrue);
    expect(timeout.hit, isFalse);
    expect(timeout.hint, '输入超时');
    expect(game.lower, 1);
    expect(game.upper, 20);
    expect(game.players.first.misses, 1);
    expect(game.currentPlayer.name, '乙');
    expect(game.finished, isFalse);
  });

  test('淘汰模式的超时会累计并淘汰玩家', () {
    final game = GameEngine(
      minimum: 1,
      maximum: 20,
      rule: Rule.elimination,
      names: const ['甲', '乙'],
      target: 12,
      missLimit: 1,
    );

    final timeout = game.submitTimeout();

    expect(timeout.timeout, isTrue);
    expect(timeout.eliminated, isTrue);
    expect(game.players.first.eliminated, isTrue);
    expect(game.finished, isTrue);
    expect(game.winner, '乙');
  });

  test('超时惩罚在所有模式都是 2 秒', () {
    for (final rule in Rule.values) {
      expect(
        shockDurationFor(
          rule: rule,
          hit: false,
          gameFinished: false,
          timeout: true,
        ),
        const Duration(seconds: 2),
      );
    }
  });
}
