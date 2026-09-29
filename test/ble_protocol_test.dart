import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:number_bomb/ble_scan_lifecycle.dart';
import 'package:number_bomb/ble_protocol.dart';
import 'package:number_bomb/feedback_service.dart';
import 'package:number_bomb/game_engine.dart';
import 'package:number_bomb/shock_rules.dart';

void main() {
  test('扫描启动返回后必须等待扫描状态变为停止', () async {
    final states = StreamController<bool>.broadcast();
    var completed = false;
    final waiting = BleScanLifecycle.waitUntilStopped(
      scanningNow: true,
      scanningStates: states.stream,
      timeout: const Duration(seconds: 1),
    ).then((_) => completed = true);

    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    states.add(true);
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    states.add(false);
    await waiting;
    expect(completed, isTrue);
    await states.close();
  });

  test('扫描已经停止时不会阻塞完成状态', () async {
    await BleScanLifecycle.waitUntilStopped(
      scanningNow: false,
      scanningStates: const Stream<bool>.empty(),
      timeout: const Duration(milliseconds: 1),
    );
  });

  test('扫描状态初始为 false 时仍需等待 true 后再等待 false', () async {
    final states = StreamController<bool>.broadcast();
    var completed = false;
    final waiting = BleScanLifecycle.waitUntilStopped(
      scanningNow: false,
      scanningStates: states.stream,
      timeout: const Duration(seconds: 1),
    ).then((_) => completed = true);

    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    states.add(true);
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    states.add(false);
    await waiting;
    expect(completed, isTrue);
    await states.close();
  });

  test('设备名称能区分一代和二代', () {
    expect(YycDjProtocol.classifyName('YYC-DJ'), YycDjGeneration.v1);
    expect(YycDjProtocol.classifyName('YYC-DJ-V2'), YycDjGeneration.v2);
    expect(YycDjProtocol.classifyName('YYC-DJ-V2-001'), YycDjGeneration.v2);
    expect(YycDjProtocol.classifyName(' yyc-dj v2_001 '), YycDjGeneration.v2);
    expect(YycDjProtocol.classifyName('YCY-DJ'), YycDjGeneration.v1);
    expect(YycDjProtocol.classifyName('ycy-dj-001'), YycDjGeneration.v1);
    expect(YycDjProtocol.classifyName('other'), YycDjGeneration.unknown);
  });

  test('服务 UUID 支持 16 位和完整格式', () {
    expect(
      YycDjProtocol.isUuidMatch('FF30', YycDjProtocol.serviceUuid),
      isTrue,
    );
    expect(
      YycDjProtocol.isUuidMatch(
        YycDjProtocol.serviceUuid.toUpperCase(),
        'ff30',
      ),
      isTrue,
    );
    expect(
      YycDjProtocol.hasServiceUuid([
        '00001800-0000-1000-8000-00805f9b34fb',
        'FF30',
      ], YycDjProtocol.serviceUuid),
      isTrue,
    );
  });

  test('应用强度按 0～180 映射到设备 0～276', () {
    expect(YycDjProtocol.mapIntensityToDevice(0), 0);
    expect(YycDjProtocol.mapIntensityToDevice(90), 138);
    expect(YycDjProtocol.mapIntensityToDevice(180), 276);
    expect(YycDjProtocol.mapIntensityToDevice(-10), 0);
    expect(YycDjProtocol.mapIntensityToDevice(300), 276);
  });

  test('实时模式数据包包含 A/B 参数和累加校验', () {
    final packet = YycDjProtocol.realtimePacket(
      deviceLevel: 276,
      frequency: 10,
      pulseWidth: 50,
    );

    expect(packet, [
      0x35,
      0x11,
      0x02,
      0x01,
      0x14,
      10,
      50,
      0x01,
      0x14,
      10,
      50,
      0xea,
    ]);
    expect(
      packet.last,
      YycDjProtocol.checksum(packet.sublist(0, packet.length - 1)),
    );
  });

  test('指定通道输出时另一通道强度为零', () {
    final a = YycDjProtocol.realtimePacket(
      deviceLevel: 100,
      frequency: 10,
      pulseWidth: 50,
      channel: ShockChannel.a,
    );
    final b = YycDjProtocol.realtimePacket(
      deviceLevel: 100,
      frequency: 10,
      pulseWidth: 50,
      channel: ShockChannel.b,
    );
    expect(a.sublist(3, 5), [0, 100]);
    expect(a.sublist(7, 9), [0, 0]);
    expect(b.sublist(3, 5), [0, 0]);
    expect(b.sublist(7, 9), [0, 100]);
    expect(a.last, YycDjProtocol.checksum(a.take(11)));
    expect(b.last, YycDjProtocol.checksum(b.take(11)));
  });

  test('不同规则使用约定的输出时长', () {
    expect(
      shockDurationFor(rule: Rule.bomb, hit: false, gameFinished: false),
      isNull,
    );
    expect(
      shockDurationFor(rule: Rule.bomb, hit: true, gameFinished: true),
      const Duration(seconds: 10),
    );
    expect(
      shockDurationFor(
        rule: Rule.wrongPenalty,
        hit: false,
        gameFinished: false,
      ),
      const Duration(seconds: 2),
    );
    expect(
      shockDurationFor(rule: Rule.elimination, hit: false, gameFinished: true),
      const Duration(seconds: 10),
    );
    expect(
      shockDurationFor(
        rule: Rule.elimination,
        hit: false,
        gameFinished: false,
        eliminated: false,
      ),
      isNull,
    );
    expect(
      shockDurationFor(
        rule: Rule.elimination,
        hit: false,
        gameFinished: false,
        eliminated: true,
      ),
      const Duration(seconds: 10),
    );
  });

  test('猜错惩罚模式不再包含轻度惩罚提示', () {
    expect(Rule.wrongPenalty.description, isNot(contains('轻度惩罚')));
  });

  test('危险度映射到分级震动模式', () {
    expect(vibrationPatternForDanger(0), 'none');
    expect(vibrationPatternForDanger(.25), 'dangerLow');
    expect(vibrationPatternForDanger(.71), 'dangerLow');
    expect(vibrationPatternForDanger(.72), 'dangerHigh');
    expect(vibrationPatternForDanger(1), 'dangerHigh');
  });

  test('答错后的下一次设备强度每次增加 5 并封顶 180', () {
    expect(nextShockIntensity(0), 5);
    expect(nextShockIntensity(5), 10);
    expect(nextShockIntensity(175), 180);
    expect(nextShockIntensity(180), 180);

    var current = 0;
    final sequence = <int>[];
    for (var index = 0; index < 4; index++) {
      sequence.add(current);
      current = nextShockIntensity(current);
    }
    expect(sequence, [0, 5, 10, 15]);
  });
}
