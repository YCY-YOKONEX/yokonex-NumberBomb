enum YycDjGeneration { v1, v2, unknown }

enum ShockChannel { a, b }

extension YycDjGenerationLabel on YycDjGeneration {
  String get label => switch (this) {
    YycDjGeneration.v1 => '一代 YYC-DJ',
    YycDjGeneration.v2 => '二代 YYC-DJ-V2',
    YycDjGeneration.unknown => '未知设备',
  };
}

class YycDjProtocol {
  static const serviceUuid = '0000ff30-0000-1000-8000-00805f9b34fb';
  static const writeCharacteristicUuid = '0000ff31-0000-1000-8000-00805f9b34fb';
  static const notifyCharacteristicUuid =
      '0000ff32-0000-1000-8000-00805f9b34fb';

  static const minDeviceLevel = 0;
  static const maxDeviceLevel = 276;
  static const minFrequency = 1;
  static const maxFrequency = 100;
  static const minPulseWidth = 0;
  static const maxPulseWidth = 100;

  static YycDjGeneration classifyName(String name) {
    final normalized = normalizeName(name);
    if (normalized.startsWith('YYC-DJ-V2')) return YycDjGeneration.v2;
    if (normalized.startsWith('YYC-DJ')) return YycDjGeneration.v1;
    // 一代设备部分固件广播为 YCY-DJ，协议和 FF30 服务仍按一代处理。
    if (normalized.startsWith('YCY-DJ')) return YycDjGeneration.v1;
    return YycDjGeneration.unknown;
  }

  // 广播名称可能包含空格或下划线，统一后再识别设备代际。
  static String normalizeName(String name) =>
      name.trim().toUpperCase().replaceAll(RegExp(r'[\s_]+'), '-');

  // Android 有时返回 16 位 UUID，有时返回完整 128 位 UUID。
  static String normalizeUuid(String uuid) {
    final normalized = uuid.trim().toLowerCase();
    if (RegExp(r'^[0-9a-f]{4}$').hasMatch(normalized)) {
      return '0000$normalized-0000-1000-8000-00805f9b34fb';
    }
    return normalized;
  }

  static bool isUuidMatch(String actual, String expected) =>
      normalizeUuid(actual) == normalizeUuid(expected);

  static bool hasServiceUuid(Iterable<String> uuids, String expected) =>
      uuids.any((uuid) => isUuidMatch(uuid, expected));

  // 将界面 0～180 强度转换为设备协议的 0～276 等级。
  static int mapIntensityToDevice(int intensity) {
    final uiIntensity = intensity.clamp(0, 180);
    return (uiIntensity * maxDeviceLevel / 180).round().clamp(
      minDeviceLevel,
      maxDeviceLevel,
    );
  }

  static List<int> realtimePacket({
    required int deviceLevel,
    required int frequency,
    required int pulseWidth,
    ShockChannel? channel,
  }) {
    final level = deviceLevel.clamp(minDeviceLevel, maxDeviceLevel);
    final hz = frequency.clamp(minFrequency, maxFrequency);
    final pulse = pulseWidth.clamp(minPulseWidth, maxPulseWidth);
    final body = <int>[
      0x35,
      0x11,
      0x02,
      (channel == ShockChannel.b ? 0 : level) >> 8 & 0xff,
      (channel == ShockChannel.b ? 0 : level) & 0xff,
      hz,
      pulse,
      (channel == ShockChannel.a ? 0 : level) >> 8 & 0xff,
      (channel == ShockChannel.a ? 0 : level) & 0xff,
      hz,
      pulse,
    ];
    return [...body, checksum(body)];
  }

  static List<int> stopPacket({int frequency = 10, int pulseWidth = 50}) =>
      realtimePacket(
        deviceLevel: 0,
        frequency: frequency,
        pulseWidth: pulseWidth,
      );

  static int checksum(Iterable<int> bytes) =>
      bytes.fold<int>(0, (sum, byte) => sum + byte) & 0xff;
}
