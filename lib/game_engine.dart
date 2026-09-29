import 'dart:math';

enum Rule { bomb, wrongPenalty, elimination }

extension RuleLabel on Rule {
  String get label => switch (this) {
    Rule.bomb => '炸弹模式',
    Rule.wrongPenalty => '猜错惩罚',
    Rule.elimination => '淘汰模式',
  };
  String get description => switch (this) {
    Rule.bomb => '猜中受罚',
    Rule.wrongPenalty => '猜错输出',
    Rule.elimination => '失误三次淘汰',
  };
}

class Player {
  Player(this.name);
  final String name;
  int misses = 0;
  bool eliminated = false;
}

class Guess {
  const Guess(
    this.player,
    this.value,
    this.relation,
    this.eliminated, {
    this.timeout = false,
  });
  final String player;
  final int value;
  // -1 表示猜小了，1 表示猜大了，0 表示命中，2 表示超时。
  final int relation;
  final bool eliminated;
  // 没有在规定时间内输入，value 使用 -1 仅用于记录，不参与命中判断。
  final bool timeout;
  bool get hit => relation == 0;
  String get hint => switch (relation) {
    -1 => '炸弹更大',
    1 => '炸弹更小',
    2 => '输入超时',
    _ => '命中数字',
  };
}

class GameEngine {
  GameEngine({
    required this.minimum,
    required this.maximum,
    required this.rule,
    required List<String> names,
    this.missLimit = 3,
    int? target,
    Random? random,
  }) : lower = minimum,
       upper = maximum,
       players = names.map(Player.new).toList() {
    if (minimum < 0 || maximum > 9999 || minimum >= maximum) {
      throw ArgumentError('请设置 0～9999 内的范围，最小值必须小于最大值。');
    }
    if (names.isEmpty || names.any((name) => name.trim().isEmpty)) {
      throw ArgumentError('至少需要一位猜测者。');
    }
    if (rule == Rule.elimination && (names.length < 2 || missLimit < 1)) {
      throw ArgumentError('淘汰模式至少需要两位猜测者。');
    }
    _target =
        target ??
        (random ?? Random.secure()).nextInt(maximum - minimum + 1) + minimum;
    if (_target < minimum || _target > maximum) {
      throw ArgumentError('炸弹数字必须在设定范围内。');
    }
  }

  final int minimum;
  final int maximum;
  final Rule rule;
  final int missLimit;
  final List<Player> players;
  late final int _target;
  int lower;
  int upper;
  int _current = 0;
  bool finished = false;
  String? winner;
  final List<Guess> history = [];

  Player get currentPlayer => players[_current];
  int get remaining => upper - lower + 1;
  double get danger =>
      (1 - (remaining - 1) / (maximum - minimum)).clamp(0.0, 1.0);
  // 结果页才能读取答案，游戏界面不暴露隐藏数字。
  int? get revealedTarget => finished ? _target : null;

  Guess submit(int value) {
    if (finished) throw StateError('本轮已经结束。');
    if (value < lower || value > upper) {
      throw ArgumentError('请输入 $lower～$upper 之间的整数。');
    }
    final player = currentPlayer;
    final relation = value.compareTo(_target);
    if (relation == 0) {
      finished = true;
      if (rule != Rule.bomb) winner = player.name;
    } else {
      // 猜错数字从闭区间移除，炸弹始终在新范围内。
      if (relation < 0) {
        lower = value + 1;
      } else {
        upper = value - 1;
      }
      player.misses++;
      if (rule == Rule.elimination && player.misses >= missLimit) {
        player.eliminated = true;
        final survivors = players.where((p) => !p.eliminated).toList();
        if (survivors.length == 1) {
          finished = true;
          winner = survivors.single.name;
        }
      }
    }
    final guess = Guess(player.name, value, relation, player.eliminated);
    history.add(guess);
    if (!finished) {
      // 顺序轮换并跳过出局玩家，出题者不会进入这个队列。
      do {
        _current = (_current + 1) % players.length;
      } while (players[_current].eliminated);
    }
    return guess;
  }

  /// 倒计时结束时记为一次失误，但不改变可猜范围。
  Guess submitTimeout() {
    if (finished) throw StateError('本轮已经结束。');
    final player = currentPlayer;
    player.misses++;
    if (rule == Rule.elimination && player.misses >= missLimit) {
      player.eliminated = true;
      final survivors = players.where((p) => !p.eliminated).toList();
      if (survivors.length == 1) {
        finished = true;
        winner = survivors.single.name;
      }
    }
    final timeout = Guess(player.name, -1, 2, player.eliminated, timeout: true);
    history.add(timeout);
    if (!finished) {
      do {
        _current = (_current + 1) % players.length;
      } while (players[_current].eliminated);
    }
    return timeout;
  }
}

const bombPunishments = [
  '用播音腔说三遍：“我是今天的数字炸弹王！”',
  '模仿一种动物，让大家猜一猜。',
  '即兴表演 15 秒机器人舞。',
  '用三个词夸夸下一位玩家。',
  '唱一句你最熟悉的歌。',
  '保持严肃表情 20 秒，挑战不笑场。',
  '用慢动作重演刚才猜中炸弹的瞬间。',
  '给自己起一个搞笑的新昵称，坚持到下局结束。',
];
