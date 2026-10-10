import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:number_bomb/ble_shock_service.dart';

void main() {
  test('停止使排队中的启动和保活失效，并在当前写入后发送停止包', () async {
    final queue = BleOutputCommandQueue();
    final gate = Completer<void>();
    final writes = <String>[];
    final current = queue.run(() async {
      writes.add('current');
      await gate.future;
    });
    final generation = queue.generation;
    final start = queue.run(
      () async => writes.add('start'),
      generation: generation,
    );
    final keepAlive = queue.run(
      () async => writes.add('keepAlive'),
      generation: generation,
    );

    queue.invalidate();
    final stop = queue.run(() async => writes.add('stop'));
    gate.complete();
    await Future.wait([current, start, keepAlive, stop]);

    expect(writes, ['current', 'stop']);
  });

  test('前一次写入失败后仍能发送停止包', () async {
    final queue = BleOutputCommandQueue();
    final failed = queue.run(() async => throw StateError('write failed'));
    final writes = <String>[];
    queue.invalidate();
    final stop = queue.run(() async => writes.add('stop'));

    await expectLater(failed, throwsStateError);
    await stop;
    expect(writes, ['stop']);
  });
}
