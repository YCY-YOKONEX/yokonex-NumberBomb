import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'app_strings.dart';
import 'ble_protocol.dart';
import 'ble_shock_service.dart';
import 'main.dart';
import 'motion_preset.dart';

const _previewDeviceId = 'AA:BB:CC:DD:EE:FF';

// 预览入口只提供界面状态，绝不向真实蓝牙设备发送命令。
class _PreviewBleHub extends YycDjBleHub {
  _PreviewBleHub() {
    snapshot.value = BleSnapshot(
      status: BleConnectionStatus.connected,
      connectedDevices: [
        BleDeviceInfo(
          device: BluetoothDevice.fromId(_previewDeviceId),
          name: 'YYC-DJ-TEST',
          rssi: -59,
        ),
      ],
    );
  }

  @override
  bool isConnected(String id) => id == _previewDeviceId;

  @override
  Future<void> startOutput({
    required String deviceId,
    required ShockChannel channel,
    required int intensity,
    required int frequency,
    required int pulseWidth,
    required Duration duration,
  }) async {}

  @override
  Future<void> emergencyStop() async {}
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppStrings.preload();
  const code = String.fromEnvironment('MOTION_PRESET', defaultValue: 'arcade');
  runApp(
    NumberBombApp(
      initialLanguage: 'zh',
      bleHub: _PreviewBleHub(),
      motionPreset: MotionPreset.fromCode(code),
      motionPreview: true,
    ),
  );
}
