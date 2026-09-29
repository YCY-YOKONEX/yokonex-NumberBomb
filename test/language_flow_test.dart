import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:number_bomb/app_strings.dart';
import 'package:number_bomb/ble_protocol.dart';
import 'package:number_bomb/ble_shock_service.dart';
import 'package:number_bomb/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ConnectedHub extends YycDjBleHub {
  _ConnectedHub() {
    snapshot.value = BleSnapshot(
      status: BleConnectionStatus.connected,
      connectedDevices: [
        BleDeviceInfo(
          device: BluetoothDevice.fromId('AA:BB:CC:DD:EE:FF'),
          name: 'YYC-DJ-TEST',
          rssi: -59,
        ),
      ],
    );
  }

  @override
  bool isConnected(String id) => id == 'AA:BB:CC:DD:EE:FF';

  @override
  Future<void> startOutput({
    required String deviceId,
    required ShockChannel channel,
    required int intensity,
    required int frequency,
    required int pulseWidth,
    required Duration duration,
  }) async {
    snapshot.value = snapshot.value.copyWith(outputActive: false);
  }

  @override
  Future<void> emergencyStop() async {
    snapshot.value = snapshot.value.copyWith(outputActive: false);
  }
}

Future<void> _selectLanguage(
  WidgetTester tester,
  String currentTooltip,
  String nativeName,
) async {
  await tester.tap(find.byTooltip(currentTooltip));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.tap(find.text(nativeName).last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppStrings.preload();
  });

  test('十种语言的键名和动态参数一致', () async {
    final base = jsonDecode(
      await rootBundle.loadString('assets/l10n/zh.json'),
    ) as Map<String, dynamic>;
    final parameters = RegExp(r'\{[a-zA-Z]+\}');
    for (final language in AppStrings.languages) {
      final values = jsonDecode(
        await rootBundle.loadString('assets/l10n/${language.code}.json'),
      ) as Map<String, dynamic>;
      expect(values.keys.toSet(), base.keys.toSet(), reason: language.code);
      for (final key in base.keys) {
        expect(values[key], isA<String>(), reason: '${language.code}: $key');
        expect(
          parameters
              .allMatches(values[key] as String)
              .map((m) => m.group(0))
              .toSet(),
          parameters
              .allMatches(base[key] as String)
              .map((m) => m.group(0))
              .toSet(),
          reason: '${language.code}: $key',
        );
      }
    }
  });

  testWidgets('十种语言切换后保留玩家和窄屏顶部布局', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(NumberBombApp(key: UniqueKey()));
    await tester.pump();
    await tester.tap(find.text('多人'));
    await tester.pump();
    var currentTooltip = '语言';
    for (final language in AppStrings.languages) {
      await _selectLanguage(tester, currentTooltip, language.nativeName);
      expect(find.text(language.shortLabel).first, findsOneWidget);
      expect(
        find.text(
          AppStrings.of(tester.element(find.byType(Scaffold)))
              .text('defaultPlayer', {'number': 2}),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull, reason: language.code);
      currentTooltip = AppStrings.of(tester.element(find.byType(Scaffold)))
          .text('language');
    }
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('language'), 'ru');
  });

  testWidgets('十种语言的游戏页和结果页在窄屏无溢出', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    for (final language in AppStrings.languages) {
      final hub = _ConnectedHub();
      await tester.pumpWidget(
        NumberBombApp(
          key: UniqueKey(),
          bleHub: hub,
          initialLanguage: language.code,
        ),
      );
      await tester.pump();
      final strings = AppStrings.of(tester.element(find.byType(Scaffold)));
      await tester.enterText(find.byType(TextField).at(1), '2');
      await tester.ensureVisible(
        find.widgetWithText(ElevatedButton, strings.text('startGame')),
      );
      await tester.tap(
        find.widgetWithText(ElevatedButton, strings.text('startGame')),
      );
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '${language.code} game');

      await tester.ensureVisible(find.widgetWithText(OutlinedButton, '1'));
      await tester.tap(find.widgetWithText(OutlinedButton, '1'));
      await tester.ensureVisible(
        find.widgetWithText(ElevatedButton, strings.text('guessNumber')),
      );
      await tester.tap(
        find.widgetWithText(ElevatedButton, strings.text('guessNumber')),
      );
      await tester.pump();
      expect(
        tester.takeException(),
        isNull,
        reason: '${language.code} first guess',
      );
      if (find.text(strings.text('hintHigher')).evaluate().isNotEmpty) {
        await tester.ensureVisible(find.widgetWithText(OutlinedButton, '2'));
        await tester.tap(find.widgetWithText(OutlinedButton, '2'));
        await tester.ensureVisible(
          find.widgetWithText(ElevatedButton, strings.text('guessNumber')),
        );
        await tester.tap(
          find.widgetWithText(ElevatedButton, strings.text('guessNumber')),
        );
        await tester.pump();
        expect(
          tester.takeException(),
          isNull,
          reason: '${language.code} second guess',
        );
      }
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.text(strings.text('hiddenNumber')), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '${language.code} result');
    }
  });

  testWidgets('游戏中切换语言不重置回合和倒计时', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final hub = _ConnectedHub();
    await tester.pumpWidget(NumberBombApp(key: UniqueKey(), bleHub: hub));
    await tester.pump();
    expect(find.textContaining('YYC-DJ-TEST'), findsWidgets);
    expect(find.textContaining('约 1.0 米'), findsOneWidget);
    await tester.ensureVisible(find.widgetWithText(ElevatedButton, '开始游戏'));
    await tester.tap(find.widgetWithText(ElevatedButton, '开始游戏'));
    await tester.pump();
    expect(find.text('输入倒计时 5s'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('输入倒计时 4s'), findsOneWidget);
    await _selectLanguage(tester, '语言', 'English');
    expect(find.text('Guess timer: 4s'), findsOneWidget);
    expect(find.text('YOU'), findsOneWidget);
    expect(find.textContaining('YYC-DJ-TEST'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Guess timer: 3s'), findsOneWidget);
  });

  testWidgets('设备名称保持原样，蓝牙报错和距离随语言切换', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final hub = _ConnectedHub();
    hub.snapshot.value = hub.snapshot.value.copyWith(
      error: '请允许附近的设备',
      issue: BleIssue.nearbyPermission,
    );
    await tester.pumpWidget(NumberBombApp(key: UniqueKey(), bleHub: hub));
    await tester.pump();
    expect(find.textContaining('约 1.0 米'), findsOneWidget);
    expect(find.textContaining('请在系统设置中允许'), findsOneWidget);
    await _selectLanguage(tester, '语言', 'English');
    expect(find.textContaining('YYC-DJ-TEST'), findsWidgets);
    expect(find.textContaining('Approx. 1.0 m'), findsOneWidget);
    expect(find.textContaining('Allow Nearby devices'), findsOneWidget);
    expect(find.textContaining('请允许附近的设备'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('多人设备通道和确认状态在语言切换后保留', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final hub = _ConnectedHub();
    await tester.pumpWidget(NumberBombApp(key: UniqueKey(), bleHub: hub));
    await tester.pump();
    await tester.tap(find.text('多人'));
    await tester.pump();
    final channelFields = find.byWidgetPredicate(
      (widget) => widget is DropdownButtonFormField,
    );
    await tester.ensureVisible(channelFields.first);
    await tester.tap(channelFields.first);
    await tester.pump();
    await tester.tap(find.textContaining('/ A').last);
    await tester.pump();
    await tester.ensureVisible(
      find.widgetWithText(OutlinedButton, '确认接通').first,
    );
    await tester.tap(find.widgetWithText(OutlinedButton, '确认接通').first);
    await tester.pump();
    await tester.ensureVisible(channelFields.last);
    await tester.tap(channelFields.last);
    await tester.pump();
    await tester.tap(find.textContaining('/ B').last);
    await tester.pump();
    await tester.ensureVisible(
      find.widgetWithText(OutlinedButton, '确认接通').last,
    );
    await tester.tap(find.widgetWithText(OutlinedButton, '确认接通').last);
    await tester.pump();
    await tester.ensureVisible(find.widgetWithText(OutlinedButton, '确认准备'));
    await tester.tap(find.widgetWithText(OutlinedButton, '确认准备'));
    await tester.pump();
    expect(find.text('3 / 3 已确认'), findsOneWidget);
    expect(
      tester
          .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, '设置炸弹'))
          .onPressed,
      isNotNull,
    );

    await _selectLanguage(tester, '语言', 'English');
    expect(find.text('3 / 3 confirmed'), findsOneWidget);
    expect(find.text('Player 2'), findsOneWidget);
    expect(find.text('Player 3'), findsOneWidget);
    expect(
      tester
          .widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, 'Set bomb'),
          )
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('结果页切换语言保留揭晓数字', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final hub = _ConnectedHub();
    await tester.pumpWidget(NumberBombApp(key: UniqueKey(), bleHub: hub));
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(1), '2');
    await tester.ensureVisible(find.widgetWithText(ElevatedButton, '开始游戏'));
    await tester.tap(find.widgetWithText(ElevatedButton, '开始游戏'));
    await tester.pump();
    await _selectLanguage(tester, '语言', 'English');

    await tester.ensureVisible(find.widgetWithText(OutlinedButton, '1'));
    await tester.tap(find.widgetWithText(OutlinedButton, '1'));
    await tester.ensureVisible(
      find.widgetWithText(ElevatedButton, 'Guess this number'),
    );
    await tester.tap(find.widgetWithText(ElevatedButton, 'Guess this number'));
    await tester.pump();
    if (find.text('Bomb is higher').evaluate().isNotEmpty) {
      await tester.ensureVisible(find.widgetWithText(OutlinedButton, '2'));
      await tester.tap(find.widgetWithText(OutlinedButton, '2'));
      await tester.ensureVisible(
        find.widgetWithText(ElevatedButton, 'Guess this number'),
      );
      await tester.tap(
        find.widgetWithText(ElevatedButton, 'Guess this number'),
      );
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('Hidden number'), findsOneWidget);
    final revealed = find.text('1').evaluate().isNotEmpty ? '1' : '2';
    await _selectLanguage(tester, 'Language', '中文');
    expect(find.text('隐藏数字'), findsOneWidget);
    expect(find.text(revealed), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
