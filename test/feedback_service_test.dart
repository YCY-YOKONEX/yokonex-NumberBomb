import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:number_bomb/feedback_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('number_bomb/feedback');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add('${call.method}:${call.arguments}');
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('街机倒计时、失误和命中分别发送音效与震动', () async {
    final feedback = FeedbackService();
    feedback.urgentTick();
    feedback.miss(timeout: false, arcade: true);
    feedback.boom(arcade: true);
    await Future<void>.delayed(Duration.zero);

    expect(
      calls,
      containsAllInOrder([
        'play:arcadeWarning',
        'vibrate:arcadeWarning',
        'play:arcadeMiss',
        'vibrate:arcadeMiss',
        'play:arcadeExplosion',
        'vibrate:arcadeExplosion',
      ]),
    );
    feedback.dispose();
  });

  test('音效和震动开关关闭后不发送街机反馈', () async {
    final feedback = FeedbackService()
      ..soundEnabled = false
      ..vibrationEnabled = false;
    feedback.urgentTick();
    feedback.miss(timeout: true, arcade: true);
    feedback.boom(arcade: true);
    await Future<void>.delayed(Duration.zero);
    expect(calls, isEmpty);
    feedback.dispose();
  });
}
