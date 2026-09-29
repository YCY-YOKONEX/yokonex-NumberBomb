import 'dart:async';

import 'package:flutter/services.dart';

String vibrationPatternForDanger(double danger) {
  if (danger >= .72) return 'dangerHigh';
  if (danger >= .25) return 'dangerLow';
  return 'none';
}

class FeedbackService {
  static const _channel = MethodChannel('number_bomb/feedback');
  bool soundEnabled = true;
  bool vibrationEnabled = true;
  bool _active = true;
  String _lastDangerPattern = 'none';
  Timer? _heartbeat;

  Future<void> _send(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // 单元测试或不支持的平台不阻断游戏。
    } on PlatformException {
      // 音频设备暂不可用时，游戏仍可继续。
    }
  }

  void play(String name) {
    if (soundEnabled && _active) unawaited(_send('play', name));
  }

  void boom() {
    play('explosion');
    if (vibrationEnabled && _active) {
      unawaited(_send('vibrate', 'explosion'));
    }
  }

  void updateHeartbeat(double danger) {
    _heartbeat?.cancel();
    final pattern = vibrationPatternForDanger(danger);
    if (vibrationEnabled && _active && pattern != 'none') {
      // 只在危险等级变化时立即反馈，避免每次重绘都触发震动。
      if (_lastDangerPattern != pattern) {
        unawaited(_send('vibrate', pattern));
        _lastDangerPattern = pattern;
      }
    } else if (!vibrationEnabled || pattern == 'none') {
      _lastDangerPattern = 'none';
    }
    if (!soundEnabled || !_active || danger < .25) return;
    // 范围越小，双拍心跳之间的间隔越短。
    final interval = (1500 - danger * 1000).round();
    _heartbeat = Timer.periodic(Duration(milliseconds: interval), (_) {
      play('heartbeat');
      if (vibrationEnabled && _active) {
        unawaited(_send('vibrate', pattern));
      }
    });
  }

  void setActive(bool value) {
    _active = value;
    if (!value) stop();
  }

  void stop() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _lastDangerPattern = 'none';
    unawaited(_send('stop'));
  }

  void dispose() => stop();
}
