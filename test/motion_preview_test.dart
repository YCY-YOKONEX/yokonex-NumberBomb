import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:number_bomb/app_strings.dart';
import 'package:number_bomb/ble_protocol.dart';
import 'package:number_bomb/ble_shock_service.dart';
import 'package:number_bomb/main.dart';
import 'package:number_bomb/motion_preset.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _PreviewHub extends YycDjBleHub {
  static const deviceId = 'AA:BB:CC:DD:EE:FF';
  int outputCalls = 0;
  int stopCalls = 0;

  _PreviewHub() {
    snapshot.value = BleSnapshot(
      status: BleConnectionStatus.connected,
      connectedDevices: [
        BleDeviceInfo(
          device: BluetoothDevice.fromId(deviceId),
          name: 'YYC-DJ-TEST',
          rssi: -59,
        ),
      ],
    );
  }

  @override
  bool isConnected(String id) =>
      snapshot.value.connected &&
      snapshot.value.connectedDevices.any((device) => device.id == id);

  @override
  Future<void> startOutput({
    required String deviceId,
    required ShockChannel channel,
    required int intensity,
    required int frequency,
    required int pulseWidth,
    required Duration duration,
  }) async {
    outputCalls++;
  }

  @override
  Future<void> emergencyStop() async {
    stopCalls++;
    snapshot.value = snapshot.value.copyWith(
      outputActive: false,
      outputRemaining: Duration.zero,
    );
  }
}

Future<void> _captureFrame(GlobalKey key, String path) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 1.5);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  await File(path).writeAsBytes(data!.buffer.asUint8List());
  image.dispose();
}

Future<ByteData> _fontBytes(String path) async {
  final bytes = await File(path).readAsBytes();
  return bytes.buffer.asByteData(bytes.offsetInBytes, bytes.lengthInBytes);
}

Future<void> _loadPreviewFonts() async {
  final flutterRoot = File(Platform.resolvedExecutable)
      .parent
      .parent
      .parent
      .parent
      .parent
      .parent
      .path;
  final iconFont =
      '$flutterRoot/bin/cache/dart-sdk/bin/resources/'
      'devtools/assets/fonts/MaterialIcons-Regular.otf';
  for (final (family, path) in [
    ('Roboto', 'build/motion-preview/fonts/Roboto-Regular.ttf'),
    ('Noto Sans CJK', 'build/motion-preview/fonts/NotoSansCJK-Regular.ttc'),
    ('Segoe UI Emoji', 'build/motion-preview/fonts/SegoeUIEmoji.ttf'),
    ('Noto Color Emoji', 'build/motion-preview/fonts/NotoColorEmoji.ttf'),
    ('monospace', 'build/motion-preview/fonts/DroidSansMono.ttf'),
    ('MaterialIcons', iconFont),
  ]) {
    final loader = FontLoader(family)..addFont(_fontBytes(path));
    await loader.load();
  }
}

void main() {
  setUpAll(AppStrings.preload);
  if (const bool.fromEnvironment('CAPTURE_MOTION')) {
    setUpAll(_loadPreviewFonts);
  }

  for (final preset in [
    MotionPreset.light,
    MotionPreset.tense,
    MotionPreset.arcade,
  ]) {
    testWidgets('${preset.name} 预览在窄屏完成固定回合且不输出', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final hub = _PreviewHub();
      await tester.pumpWidget(
        NumberBombApp(
          initialLanguage: 'zh',
          bleHub: hub,
          motionPreset: preset,
          motionPreview: true,
        ),
      );
      await tester.pump();
      final strings = AppStrings.of(tester.element(find.byType(Scaffold)));
      for (var turn = 0; turn < 3; turn++) {
        await tester.pump(const Duration(milliseconds: 4200));
        await tester.pump(preset.turnDuration);
        expect(tester.takeException(), isNull);
      }
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.text(strings.text('hiddenNumber')), findsOneWidget);
      expect(hub.outputCalls, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('系统关闭动画时预览不持续请求新画面', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(
      tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );
    final hub = _PreviewHub();
    await tester.pumpWidget(
      NumberBombApp(
        initialLanguage: 'zh',
        bleHub: hub,
        motionPreset: MotionPreset.arcade,
        motionPreview: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pump(const Duration(milliseconds: 4200));
    await tester.pump(const Duration(milliseconds: 40));
    final impact = tester.widget<Transform>(
      find.byKey(const ValueKey('game-impact')),
    );
    expect(impact.transform.getTranslation().x, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('街机失误和命中只短暂抖动游戏内容', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final hub = _PreviewHub();
    await tester.pumpWidget(
      NumberBombApp(
        initialLanguage: 'zh',
        bleHub: hub,
        motionPreset: MotionPreset.arcade,
        motionPreview: true,
      ),
    );
    await tester.pump();
    final impact = find.byKey(const ValueKey('game-impact'));
    double horizontalShift() =>
        tester.widget<Transform>(impact).transform.getTranslation().x;
    expect(horizontalShift(), 0);

    await tester.pump(const Duration(milliseconds: 4200));
    await tester.pump(const Duration(milliseconds: 40));
    final missShift = horizontalShift().abs();
    expect(missShift, greaterThan(.1));
    await tester.pump(const Duration(milliseconds: 400));
    expect(horizontalShift(), 0);

    await tester.pump(const Duration(milliseconds: 3800));
    await tester.pump(const Duration(milliseconds: 4200));
    await tester.pump(const Duration(milliseconds: 40));
    expect(horizontalShift().abs(), greaterThan(missShift));
    await tester.pump(const Duration(milliseconds: 800));
    expect(hub.outputCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('断线和模拟输出会暂停循环动效', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final hub = _PreviewHub();
    await tester.pumpWidget(
      NumberBombApp(
        initialLanguage: 'zh',
        bleHub: hub,
        motionPreset: MotionPreset.arcade,
        motionPreview: true,
      ),
    );
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isTrue);

    hub.snapshot.value = hub.snapshot.value.copyWith(
      outputActive: true,
      outputRemaining: const Duration(seconds: 10),
    );
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);

    hub.snapshot.value = hub.snapshot.value.copyWith(
      outputActive: false,
      outputRemaining: Duration.zero,
      status: BleConnectionStatus.disconnected,
      connectedDevices: const [],
    );
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('急停后回合继续，重置后动效结束', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final hub = _PreviewHub();
    await tester.pumpWidget(
      NumberBombApp(
        initialLanguage: 'zh',
        bleHub: hub,
        motionPreset: MotionPreset.tense,
        motionPreview: true,
      ),
    );
    await tester.pump();
    hub.snapshot.value = hub.snapshot.value.copyWith(
      outputActive: true,
      outputRemaining: const Duration(seconds: 10),
    );
    await tester.pumpAndSettle();
    final strings = AppStrings.of(tester.element(find.byType(Scaffold)));
    await tester.tap(find.byTooltip(strings.text('emergencyStop')).first);
    await tester.pump();
    expect(hub.stopCalls, 1);
    expect(hub.snapshot.value.outputActive, isFalse);
    expect(tester.binding.hasScheduledFrame, isTrue);

    await tester.tap(find.byTooltip(strings.text('reset')));
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });

  if (const bool.fromEnvironment('CAPTURE_MOTION')) {
    for (final preset in MotionPreset.values) {
      testWidgets('${preset.name} 录制真实界面帧', (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = const Size(394, 960);
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        final key = GlobalKey();
        final hub = _PreviewHub();
        final directory = Directory('build/motion-preview/${preset.name}');
        directory.createSync(recursive: true);
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: NumberBombApp(
              initialLanguage: 'zh',
              bleHub: hub,
              motionPreset: preset,
              motionPreview: true,
            ),
          ),
        );
        await tester.pump();
        await tester.runAsync(() async {
          final context = tester.element(find.byType(Scaffold));
          for (final asset in [
            'assets/bomb/bomb_idle.png',
            'assets/bomb/bomb_hot.png',
            'assets/bomb/bomb_burst.png',
          ]) {
            await precacheImage(AssetImage(asset), context);
          }
        });
        await tester.pump();
        final frameCount = preset == MotionPreset.original ? 1 : 400;
        for (var frame = 0; frame < frameCount; frame++) {
          if (frame > 0) await tester.pump(const Duration(milliseconds: 40));
          final name = 'frame-${frame.toString().padLeft(4, '0')}.png';
          await tester.runAsync(
            () => _captureFrame(key, '${directory.path}/$name'),
          );
        }
        expect(hub.outputCalls, 0);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
