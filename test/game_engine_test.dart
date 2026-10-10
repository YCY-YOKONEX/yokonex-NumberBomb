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

  test('只有猜错惩罚模式累计失误强度', () {
    const wrong = Guess('甲', 2, -1, false);
    const timeout = Guess('甲', -1, 2, false, timeout: true);
    const hit = Guess('甲', 5, 0, false);
    for (final rule in Rule.values) {
      final expected = rule == Rule.wrongPenalty ? 15 : 10;
      expect(intensityAfterGuess(rule, 10, wrong), expected);
      expect(intensityAfterGuess(rule, 10, timeout), expected);
      expect(intensityAfterGuess(rule, 10, hit), 10);
    }
    expect(intensityAfterGuess(Rule.wrongPenalty, 180, wrong), 180);
  });

  test('淘汰模式猜中炸弹不把失败玩家记为获胜者', () {
    final game = GameEngine(
      minimum: 1,
      maximum: 10,
      rule: Rule.elimination,
      names: const ['甲', '乙'],
      target: 5,
    );
    final hit = game.submit(5);
    expect(hit.hit, isTrue);
    expect(game.finished, isTrue);
    expect(game.winner, isNull);
  });
}
