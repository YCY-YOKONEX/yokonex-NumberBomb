import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:number_bomb/app_strings.dart';
import 'package:number_bomb/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppStrings.preload();
  });

  testWidgets('已保存英文时首屏直接显示英文', (tester) async {
    SharedPreferences.setMockInitialValues({'language': 'en'});
    await tester.pumpWidget(
      NumberBombApp(key: UniqueKey(), initialLanguage: 'en'),
    );
    await tester.pump();
    expect(find.text('Solo'), findsOneWidget);
    expect(find.text('单人'), findsNothing);
  });

  testWidgets('多人模式逐个添加和删除玩家，未确认时不能开局', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(NumberBombApp(key: UniqueKey()));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('役次元·'), findsOneWidget);
    expect(find.text('数字炸弹'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('役次元·')).dy,
      tester.getTopLeft(find.text('数字炸弹')).dy,
    );
    await tester.tap(find.text('多人'));
    await tester.pump();

    expect(find.text('Master'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(4));
    expect(find.byTooltip('至少保留 2 位猜测者'), findsNWidgets(2));

    await tester.ensureVisible(find.byTooltip('添加玩家'));
    await tester.tap(find.byTooltip('添加玩家'));
    await tester.pump();
    expect(find.byType(TextField), findsNWidgets(5));
    expect(find.text('玩家 4'), findsOneWidget);

    await tester.tap(find.byTooltip('删除玩家 2'));
    await tester.pump();
    expect(find.byType(TextField), findsNWidgets(4));
    expect(find.text('玩家 3'), findsOneWidget);
    expect(find.text('玩家 4'), findsOneWidget);

    final start = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, '设置炸弹'),
    );
    expect(start.onPressed, isNull);
  });

  testWidgets('语言切换保留玩家设置并记住选择', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(NumberBombApp(key: UniqueKey()));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('多人'));
    await tester.pump();
    await tester.ensureVisible(find.byTooltip('添加玩家'));
    await tester.tap(find.byTooltip('添加玩家'));
    await tester.pump();
    expect(find.text('玩家 4'), findsOneWidget);

    await tester.tap(find.byTooltip('语言'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.text('English').last);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('yiciyuan·'), findsOneWidget);
    expect(find.text('Number Bomb'), findsOneWidget);
    expect(find.text('Group'), findsOneWidget);
    expect(find.text('Player 4'), findsOneWidget);
    expect(find.byTooltip('More'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('language'), 'en');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(NumberBombApp(key: UniqueKey()));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Solo'), findsOneWidget);
  });

  testWidgets('自定义玩家名在语言切换后保持原样', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(NumberBombApp(key: UniqueKey()));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('多人'));
    await tester.pump();
    final playerField = find.byType(TextField).at(2);
    await tester.ensureVisible(playerField);
    await tester.enterText(playerField, 'Alex');
    await tester.tap(find.byTooltip('语言'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.text('English').last);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Alex'), findsOneWidget);
    expect(find.text('Player 3'), findsOneWidget);
  });
}
