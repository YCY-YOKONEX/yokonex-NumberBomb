import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble_protocol.dart';
import 'ble_scan_lifecycle.dart';

enum BleConnectionStatus {
  idle,
  scanning,
  connecting,
  connected,
  disconnected,
  error,
}

enum BleIssue {
  nearbyPermission,
  locationPermission,
  scanFailed,
  connectFailed,
  deviceServiceMissing,
  deviceLostDuringConnect,
  disconnected,
}

class BleConnectionException implements Exception {
  const BleConnectionException(this.issue);
  final BleIssue issue;
}

// 同一台设备的输出、保活和停止包必须顺序写入；停止时丢弃尚未写出的旧输出。
class BleOutputCommandQueue {
  Future<void> _pending = Future<void>.value();
  int _generation = 0;

  int get generation => _generation;
  void invalidate() => _generation++;

  Future<void> run(Future<void> Function() write, {int? generation}) {
    final task = _pending.then((_) async {
      if (generation != null && generation != _generation) return;
      await write();
    });
    _pending = task.then((_) {}, onError: (Object error, StackTrace stack) {});
    return task;
  }

  Future<void> get idle => _pending;
}

class BleDeviceInfo {
  const BleDeviceInfo({
    required this.device,
    required this.name,
    this.serviceMatched = false,
    this.rssi,
  });

  final BluetoothDevice device;
  final String name;
  final bool serviceMatched;
  final int? rssi;

  YycDjGeneration get generation => YycDjProtocol.classifyName(name);
  bool get namedTarget => generation != YycDjGeneration.unknown;
  bool get recognized => namedTarget || serviceMatched;
  String get displayName =>
      name.isEmpty ? '未命名 BLE 设备（${_shortId(device.remoteId.str)}）' : name;
  String get generationLabel => generation == YycDjGeneration.unknown
      ? (serviceMatched ? 'FF30 服务设备' : '未识别 BLE 设备')
      : generation.label;
  String get id => device.remoteId.str;
  String get shortId => _shortId(id);
  // RSSI 受遮挡和设备姿态影响，只能作为大致距离参考。
  String get distanceLabel => rssi == null
      ? '距离未知'
      : '约 ${pow(10, (-59 - rssi!) / 20).clamp(0.1, 99).toStringAsFixed(1)} 米（信号估算）';

  BleDeviceInfo copyWith({String? name, bool? serviceMatched, int? rssi}) =>
      BleDeviceInfo(
        device: device,
        name: name ?? this.name,
        serviceMatched: serviceMatched ?? this.serviceMatched,
        rssi: rssi ?? this.rssi,
      );

  static String _shortId(String value) =>
      value.length > 8 ? value.substring(value.length - 8) : value;
}

class BleSnapshot {
  const BleSnapshot({
    this.status = BleConnectionStatus.idle,
    this.devices = const [],
    this.selected,
    this.connectedDevices = const [],
    this.error,
    this.issue,
    this.outputActive = false,
    this.outputRemaining = Duration.zero,
    this.rawScanResultCount = 0,
    this.scanCompleted = false,
    this.scanInProgress = false,
  });

  final BleConnectionStatus status;
  final List<BleDeviceInfo> devices;
  final BleDeviceInfo? selected;
  final List<BleDeviceInfo> connectedDevices;
  final String? error;
  final BleIssue? issue;
  final bool outputActive;
  final Duration outputRemaining;
  final int rawScanResultCount;
  final bool scanCompleted;
  final bool scanInProgress;

  bool get connected => status == BleConnectionStatus.connected;
  int get recognizedDeviceCount =>
      devices.where((item) => item.recognized).length;

  BleSnapshot copyWith({
    BleConnectionStatus? status,
    List<BleDeviceInfo>? devices,
    BleDeviceInfo? selected,
    List<BleDeviceInfo>? connectedDevices,
    bool clearSelected = false,
    String? error,
    BleIssue? issue,
    bool clearError = false,
    bool? outputActive,
    Duration? outputRemaining,
    int? rawScanResultCount,
    bool? scanCompleted,
    bool? scanInProgress,
  }) => BleSnapshot(
    status: status ?? this.status,
    devices: devices ?? this.devices,
    selected: clearSelected ? null : selected ?? this.selected,
    connectedDevices: connectedDevices ?? this.connectedDevices,
    error: clearError ? null : error ?? this.error,
    issue: clearError ? null : issue ?? this.issue,
    outputActive: outputActive ?? this.outputActive,
    outputRemaining: outputRemaining ?? this.outputRemaining,
    rawScanResultCount: rawScanResultCount ?? this.rawScanResultCount,
    scanCompleted: scanCompleted ?? this.scanCompleted,
    scanInProgress: scanInProgress ?? this.scanInProgress,
  );
}

class YycDjBleService {
  final ValueNotifier<BleSnapshot> snapshot = ValueNotifier(
    const BleSnapshot(),
  );
  final StreamController<List<int>> _notifications =
      StreamController<List<int>>.broadcast();

  BluetoothDevice? _device;
  BluetoothCharacteristic? _writeCharacteristic;
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<List<int>>? _notificationSubscription;
  Timer? _outputTimer;
  Timer? _outputKeepAliveTimer;
  DateTime? _outputEndsAt;
  final BleOutputCommandQueue _outputCommands = BleOutputCommandQueue();
  bool _disconnecting = false;
  Future<void>? _scanFuture;
  int _scanGeneration = 0;

  Stream<List<int>> get notifications => _notifications.stream;

  Future<void> scan() {
    final current = _scanFuture;
    if (current != null) return current;

    final generation = ++_scanGeneration;
    final task = _scanInternal(generation);
    late final Future<void> tracked;
    tracked = task.whenComplete(() {
      if (identical(_scanFuture, tracked)) _scanFuture = null;
    });
    _scanFuture = tracked;
    return tracked;
  }

  Future<void> _scanInternal(int generation) async {
    await _scanSubscription?.cancel();
    final found = <String, BleDeviceInfo>{};
    var rawScanResultCount = 0;

    bool isCurrentSession() => generation == _scanGeneration;

    void publishDevices() {
      if (!isCurrentSession()) return;
      // 界面只显示目标名称或 FF30 服务设备，其他 BLE 广播不进入列表。
      // 部分 YYC 固件把名称放在扫描响应包里，名称暂时为空但 FF30 已广播，
      // 不能因为没有名称就提前丢弃，否则手机系统能看到、应用却显示为空。
      final devices = found.values.where((item) => item.recognized).toList()
        ..sort((a, b) {
          final nameCompare = a.displayName.compareTo(b.displayName);
          if (nameCompare != 0) return nameCompare;
          return (b.rssi ?? -999).compareTo(a.rssi ?? -999);
        });
      _publish(
        snapshot.value.copyWith(
          devices: devices,
          rawScanResultCount: rawScanResultCount,
        ),
      );
    }

    _publish(
      snapshot.value.copyWith(
        status: BleConnectionStatus.scanning,
        devices: const [],
        clearError: true,
        rawScanResultCount: 0,
        scanCompleted: false,
      ),
    );
    try {
      await FlutterBluePlus.adapterState
          .where((state) => state == BluetoothAdapterState.on)
          .first
          .timeout(const Duration(seconds: 8));

      // 系统已连接设备不会再次广播，先从系统连接列表补齐它们。
      final systemDevices = await FlutterBluePlus.systemDevices([]);
      for (final device in systemDevices) {
        final name = device.platformName.trim().isNotEmpty
            ? device.platformName.trim()
            : device.advName.trim();
        found[device.remoteId.str] = BleDeviceInfo(
          device: device,
          name: name,
          serviceMatched: true,
        );
      }
      publishDevices();

      _scanSubscription = FlutterBluePlus.onScanResults.listen(
        (results) {
          for (final result in results) {
            if (!isCurrentSession()) return;
            rawScanResultCount++;
            final advertisedName = result.advertisementData.advName.trim();
            final platformName = result.device.platformName.trim();
            final deviceAdvName = result.device.advName.trim();
            final name = advertisedName.isNotEmpty
                ? advertisedName
                : platformName.isNotEmpty
                ? platformName
                : deviceAdvName;
            final serviceMatched =
                YycDjProtocol.hasServiceUuid(
                  result.advertisementData.serviceUuids.map((uuid) => uuid.str),
                  YycDjProtocol.serviceUuid,
                ) ||
                YycDjProtocol.hasServiceUuid(
                  result.advertisementData.serviceData.keys.map(
                    (uuid) => uuid.str,
                  ),
                  YycDjProtocol.serviceUuid,
                );
            final previous = found[result.device.remoteId.str];
            found[result.device.remoteId.str] = BleDeviceInfo(
              device: result.device,
              name: name.isNotEmpty ? name : previous?.name ?? '',
              serviceMatched:
                  serviceMatched || previous?.serviceMatched == true,
              rssi: result.rssi,
            );
          }
          publishDevices();
        },
        onError: (Object error) {
          // 由扫描主流程统一收尾，避免错误回调和正常完成状态竞争。
          unawaited(FlutterBluePlus.stopScan());
          _publish(
            snapshot.value.copyWith(
              status: BleConnectionStatus.error,
              error: _scanErrorMessage(error),
              issue: _scanIssue(error),
              scanCompleted: false,
            ),
          );
        },
      );
      try {
        await _startScanPass(androidUsesFineLocation: true);
      } catch (error) {
        // 用户拒绝定位权限时仍保留普通 BLE 扫描能力，避免整个设备列表为空。
        if (!_isLocationPermissionError(error)) rethrow;
        _publish(
          snapshot.value.copyWith(
            status: BleConnectionStatus.scanning,
            clearError: true,
          ),
        );
        await _startScanPass(androidUsesFineLocation: false);
      }
      if (!isCurrentSession()) return;
      await _scanSubscription?.cancel();
      _scanSubscription = null;
      if (snapshot.value.status == BleConnectionStatus.scanning) {
        _publish(
          snapshot.value.copyWith(
            status: BleConnectionStatus.idle,
            scanCompleted: true,
          ),
        );
      }
    } catch (error) {
      await _scanSubscription?.cancel();
      _scanSubscription = null;
      if (!isCurrentSession()) return;
      _publish(
        snapshot.value.copyWith(
          status: BleConnectionStatus.error,
          error: _scanErrorMessage(error),
          issue: _scanIssue(error),
          scanCompleted: false,
        ),
      );
    }
  }

  Future<void> _startScanPass({required bool androidUsesFineLocation}) async {
    await FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 8),
      continuousUpdates: true,
      oneByOne: true,
      // 部分 YYC 固件的广播需要定位兼容模式才能被 Android 返回。
      androidUsesFineLocation: androidUsesFineLocation,
    );
    // startScan 只表示启动成功，必须等待内部超时或 stopScan 后再返回。
    await BleScanLifecycle.waitUntilStopped(
      scanningNow: FlutterBluePlus.isScanningNow,
      scanningStates: FlutterBluePlus.isScanning,
    );
  }

  bool _isLocationPermissionError(Object error) {
    final message = error.toString();
    return message.contains('ACCESS_FINE_LOCATION') ||
        message.contains('Location services');
  }

  Future<void> connect(BleDeviceInfo info) async {
    if (_device?.remoteId == info.device.remoteId && snapshot.value.connected) {
      return;
    }
    await _disconnectCurrent();
    _publish(
      snapshot.value.copyWith(
        status: BleConnectionStatus.connecting,
        selected: info,
        clearError: true,
      ),
    );
    final device = info.device;
    // 订阅连接状态时，插件会先回放一次当前的 disconnected 状态。
    // 这不是异常断开，只有设备真正连上后再次变为 disconnected 才需要清理。
    var connectionEstablished = false;
    _device = device;
    _connectionSubscription = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.connected) {
        connectionEstablished = true;
      } else if (state == BluetoothConnectionState.disconnected &&
          connectionEstablished &&
          !_disconnecting) {
        // 设备被拔出或关机时，主动清理旧连接，避免页面继续显示“断开”按钮。
        unawaited(_handleUnexpectedDisconnect(device));
      }
    });
    try {
      // YYC-DJ 固件不稳定支持 Android 自动 MTU 512 请求。
      // flutter_blue_plus 默认会在连接后请求 MTU，部分设备会因此立刻断开，
      // 报出 requestMtu: device is disconnected。关闭自动 MTU 请求后，
      // 继续使用设备默认 MTU，不影响 FF31/FF32 协议包通信。
      await device.connect(timeout: const Duration(seconds: 18), mtu: null);
      _ensureCurrentDevice(device);
      var services = await device.discoverServices();
      if (services.isEmpty) {
        // 部分 Android 蓝牙栈首次发现服务为空，短暂等待后重试一次。
        await Future<void>.delayed(const Duration(milliseconds: 350));
        _ensureCurrentDevice(device);
        services = await device.discoverServices();
      }
      _ensureCurrentDevice(device);
      final service = services.firstWhere(
        (item) =>
            YycDjProtocol.isUuidMatch(item.uuid.str, YycDjProtocol.serviceUuid),
        orElse: () =>
            throw const BleConnectionException(BleIssue.deviceServiceMissing),
      );
      final writeCharacteristic = service.characteristics.firstWhere(
        (item) => YycDjProtocol.isUuidMatch(
          item.uuid.str,
          YycDjProtocol.writeCharacteristicUuid,
        ),
        orElse: () =>
            throw const BleConnectionException(BleIssue.deviceServiceMissing),
      );
      final notifyCharacteristic = service.characteristics.firstWhere(
        (item) => YycDjProtocol.isUuidMatch(
          item.uuid.str,
          YycDjProtocol.notifyCharacteristicUuid,
        ),
        orElse: () =>
            throw const BleConnectionException(BleIssue.deviceServiceMissing),
      );
      _writeCharacteristic = writeCharacteristic;
      await notifyCharacteristic.setNotifyValue(true);
      _ensureCurrentDevice(device);
      await _notificationSubscription?.cancel();
      _notificationSubscription = notifyCharacteristic.onValueReceived.listen(
        _notifications.add,
      );
      _ensureCurrentDevice(device);
      _publish(
        snapshot.value.copyWith(
          status: BleConnectionStatus.connected,
          selected: info.copyWith(
            name: info.name.isNotEmpty ? info.name : device.platformName.trim(),
            serviceMatched: true,
          ),
          clearError: true,
        ),
      );
    } catch (error) {
      await _disconnectCurrent();
      _publish(
        snapshot.value.copyWith(
          status: BleConnectionStatus.error,
          selected: info,
          error: '连接设备失败：$error',
          issue: error is BleConnectionException
              ? error.issue
              : BleIssue.connectFailed,
          clearSelected: true,
        ),
      );
      rethrow;
    }
  }

  void _ensureCurrentDevice(BluetoothDevice device) {
    if (_device?.remoteId != device.remoteId) {
      throw const BleConnectionException(BleIssue.deviceLostDuringConnect);
    }
  }

  String _scanErrorMessage(Object error) {
    final message = error.toString();
    if (message.contains('BLUETOOTH_SCAN') ||
        message.contains('BLUETOOTH_CONNECT')) {
      return '请在系统设置中允许“附近的设备”权限后重试。';
    }
    if (message.contains('ACCESS_FINE_LOCATION') ||
        message.contains('Location services')) {
      return '请打开系统定位和定位权限后重试。';
    }
    return '蓝牙扫描失败：$error';
  }

  BleIssue _scanIssue(Object error) {
    final message = error.toString();
    if (message.contains('BLUETOOTH_SCAN') ||
        message.contains('BLUETOOTH_CONNECT')) {
      return BleIssue.nearbyPermission;
    }
    if (message.contains('ACCESS_FINE_LOCATION') ||
        message.contains('Location services')) {
      return BleIssue.locationPermission;
    }
    return BleIssue.scanFailed;
  }

  Future<void> startOutput({
    required int intensity,
    required int frequency,
    required int pulseWidth,
    required Duration duration,
    ShockChannel? channel,
  }) async {
    final characteristic = _writeCharacteristic;
    if (characteristic == null || !snapshot.value.connected) {
      throw StateError('请先连接 YYC-DJ 设备。');
    }
    _outputCommands.invalidate();
    _clearOutputTimers();
    final generation = _outputCommands.generation;
    final deviceLevel = YycDjProtocol.mapIntensityToDevice(intensity);
    if (deviceLevel == 0) {
      _publish(
        snapshot.value.copyWith(
          outputActive: false,
          outputRemaining: Duration.zero,
        ),
      );
      return;
    }
    final packet = YycDjProtocol.realtimePacket(
      deviceLevel: deviceLevel,
      frequency: frequency,
      pulseWidth: pulseWidth,
      channel: channel,
    );
    await _outputCommands.run(() async {
      if (!identical(_writeCharacteristic, characteristic) ||
          !snapshot.value.connected) {
        return;
      }
      await _writePacket(characteristic, packet);
    }, generation: generation);
    if (generation != _outputCommands.generation ||
        !identical(_writeCharacteristic, characteristic) ||
        !snapshot.value.connected) {
      return;
    }
    _outputEndsAt = DateTime.now().add(duration);
    _publish(
      snapshot.value.copyWith(outputActive: true, outputRemaining: duration),
    );
    // 实时模式需要持续刷新，避免部分设备在几秒后自动结束输出。
    _outputKeepAliveTimer = Timer.periodic(const Duration(milliseconds: 700), (
      _,
    ) {
      if (_writeCharacteristic == null || !snapshot.value.outputActive) return;
      unawaited(
        _outputCommands
            .run(
              () => _writePacket(characteristic, packet),
              generation: generation,
            )
            .catchError((_) {}),
      );
    });
    _outputTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final endsAt = _outputEndsAt;
      if (endsAt == null) return;
      final remaining = endsAt.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        unawaited(stopOutput(frequency: frequency, pulseWidth: pulseWidth));
      } else {
        _publish(
          snapshot.value.copyWith(
            outputActive: true,
            outputRemaining: remaining,
          ),
        );
      }
    });
  }

  Future<void> stopOutput({int frequency = 10, int pulseWidth = 50}) async {
    _outputCommands.invalidate();
    _clearOutputTimers();
    final characteristic = _writeCharacteristic;
    try {
      if (characteristic != null) {
        await _outputCommands.run(() async {
          if (identical(_writeCharacteristic, characteristic)) {
            await _writePacket(
              characteristic,
              YycDjProtocol.stopPacket(
                frequency: frequency,
                pulseWidth: pulseWidth,
              ),
            );
          }
        });
      }
    } finally {
      _publish(
        snapshot.value.copyWith(
          outputActive: false,
          outputRemaining: Duration.zero,
        ),
      );
    }
  }

  Future<void> emergencyStop() => stopOutput();

  Future<void> disconnect() async {
    await emergencyStop();
    await _disconnectCurrent();
    _publish(
      snapshot.value.copyWith(
        status: BleConnectionStatus.disconnected,
        clearSelected: true,
        clearError: true,
      ),
    );
  }

  Future<void> _handleUnexpectedDisconnect(BluetoothDevice? device) async {
    if (device == null || _device?.remoteId != device.remoteId) return;
    _disconnecting = true;
    // 设备已经断开，停止包通常无法发送；先清理计时器和本地引用。
    _outputCommands.invalidate();
    _clearOutputTimers();
    await _outputCommands.idle;
    await _notificationSubscription?.cancel();
    await _connectionSubscription?.cancel();
    _notificationSubscription = null;
    _connectionSubscription = null;
    _device = null;
    _writeCharacteristic = null;
    _disconnecting = false;
    _publish(
      snapshot.value.copyWith(
        status: BleConnectionStatus.disconnected,
        clearSelected: true,
        outputActive: false,
        outputRemaining: Duration.zero,
        error: '设备已断开，请重新扫描并连接。',
        issue: BleIssue.disconnected,
      ),
    );
  }

  Future<void> _disconnectCurrent() async {
    _disconnecting = true;
    _outputCommands.invalidate();
    _clearOutputTimers();
    await _outputCommands.idle;
    await _notificationSubscription?.cancel();
    await _connectionSubscription?.cancel();
    _notificationSubscription = null;
    _connectionSubscription = null;
    final device = _device;
    _device = null;
    _writeCharacteristic = null;
    if (device != null) {
      try {
        await device.disconnect();
      } catch (_) {
        // 设备已经断开时无需阻断新的连接。
      }
    }
    _disconnecting = false;
  }

  void _clearOutputTimers() {
    _outputTimer?.cancel();
    _outputTimer = null;
    _outputKeepAliveTimer?.cancel();
    _outputKeepAliveTimer = null;
    _outputEndsAt = null;
  }

  void _publish(BleSnapshot value) => snapshot.value = value;

  Future<void> dispose() async {
    _scanGeneration++;
    _outputCommands.invalidate();
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }
    await _scanSubscription?.cancel();
    // 应用退到后台或进程退出时不发送停止包，让设备按已下发的时长继续输出。
    // 用户主动断开、重置或点击紧急停止仍会走 emergencyStop。
    _outputTimer?.cancel();
    _outputTimer = null;
    _outputKeepAliveTimer?.cancel();
    _outputKeepAliveTimer = null;
    _outputEndsAt = null;
    await _outputCommands.idle;
    await _notificationSubscription?.cancel();
    await _connectionSubscription?.cancel();
    await _notifications.close();
    snapshot.dispose();
  }

  // 优先使用带响应写入；设备只开放无响应写入时再自动降级重试。
  Future<void> _writePacket(
    BluetoothCharacteristic characteristic,
    List<int> packet,
  ) async {
    try {
      await characteristic.write(packet, withoutResponse: false);
    } catch (_) {
      if (!characteristic.properties.writeWithoutResponse) rethrow;
      await characteristic.write(packet, withoutResponse: true);
    }
  }
}

// 扫描器和每台设备各用一个连接实例，避免新连接挤掉已分配给玩家的设备。
class YycDjBleHub {
  final ValueNotifier<BleSnapshot> snapshot = ValueNotifier(
    const BleSnapshot(),
  );
  final YycDjBleService _scanner = YycDjBleService();
  final Map<String, YycDjBleService> _connections = {};
  final Map<String, int> _connectedRssi = {};
  Timer? _rssiTimer;
  bool _disposed = false;

  YycDjBleHub() {
    _scanner.snapshot.addListener(_publish);
  }

  bool isConnected(String id) =>
      _connections[id]?.snapshot.value.connected == true;

  Future<void> scan() => _scanner.scan();

  Future<void> connect(BleDeviceInfo info) async {
    if (isConnected(info.id)) return;
    final old = _connections.remove(info.id);
    if (old != null) {
      old.snapshot.removeListener(_publish);
      await old.dispose();
    }
    final connection = YycDjBleService();
    _connections[info.id] = connection;
    connection.snapshot.addListener(_publish);
    _publish();
    try {
      await connection.connect(info);
      _rssiTimer ??= Timer.periodic(
        const Duration(seconds: 5),
        (_) => unawaited(_refreshRssi()),
      );
      unawaited(_refreshRssi());
    } catch (_) {
      _connections.remove(info.id);
      connection.snapshot.removeListener(_publish);
      await connection.dispose();
      _publish();
      rethrow;
    }
  }

  Future<void> disconnect(String id) async {
    final connection = _connections.remove(id);
    if (connection == null) return;
    _connectedRssi.remove(id);
    if (_connections.isEmpty) {
      _rssiTimer?.cancel();
      _rssiTimer = null;
    }
    connection.snapshot.removeListener(_publish);
    try {
      await connection.disconnect();
    } finally {
      await connection.dispose();
      _publish();
    }
  }

  Future<void> startOutput({
    required String deviceId,
    required ShockChannel channel,
    required int intensity,
    required int frequency,
    required int pulseWidth,
    required Duration duration,
  }) async {
    final connection = _connections[deviceId];
    if (connection == null || !connection.snapshot.value.connected) {
      throw StateError('指定玩家的电击器已断开。');
    }
    await connection.startOutput(
      intensity: intensity,
      frequency: frequency,
      pulseWidth: pulseWidth,
      duration: duration,
      channel: channel,
    );
  }

  Future<void> emergencyStop() async {
    await Future.wait(_connections.values.map((item) => item.emergencyStop()));
  }

  Future<void> _refreshRssi() async {
    for (final entry in _connections.entries.toList()) {
      if (!entry.value.snapshot.value.connected) continue;
      try {
        final rssi = await entry.value.snapshot.value.selected?.device
            .readRssi();
        if (!_disposed && rssi != null && isConnected(entry.key)) {
          _connectedRssi[entry.key] = rssi;
          _publish();
        }
      } catch (_) {
        // 个别设备不支持读取 RSSI，保留扫描时的距离估算。
      }
    }
  }

  void _publish() {
    if (_disposed) return;
    final scan = _scanner.snapshot.value;
    final active = _connections.values
        .map((item) => item.snapshot.value)
        .where((item) => item.connected)
        .toList();
    _connectedRssi.removeWhere((id, _) => !isConnected(id));
    if (active.isEmpty) {
      _rssiTimer?.cancel();
      _rssiTimer = null;
    }
    final connectedDevices = active
        .map((item) {
          final selected = item.selected;
          if (selected == null) return null;
          for (final scanned in scan.devices) {
            if (scanned.id == selected.id) {
              return selected.copyWith(
                rssi: _connectedRssi[selected.id] ?? scanned.rssi,
              );
            }
          }
          return selected.copyWith(rssi: _connectedRssi[selected.id]);
        })
        .whereType<BleDeviceInfo>()
        .toList();
    final outputs = active.where((item) => item.outputActive).toList();
    snapshot.value = BleSnapshot(
      status: connectedDevices.isNotEmpty
          ? BleConnectionStatus.connected
          : scan.status,
      devices: scan.devices,
      selected: connectedDevices.firstOrNull,
      connectedDevices: connectedDevices,
      error: scan.error,
      issue: scan.issue,
      outputActive: outputs.isNotEmpty,
      outputRemaining: outputs.fold(
        Duration.zero,
        (remaining, item) =>
            item.outputRemaining > remaining ? item.outputRemaining : remaining,
      ),
      rawScanResultCount: scan.rawScanResultCount,
      scanCompleted: scan.scanCompleted,
      scanInProgress: scan.status == BleConnectionStatus.scanning,
    );
  }

  Future<void> dispose() async {
    _disposed = true;
    _rssiTimer?.cancel();
    _scanner.snapshot.removeListener(_publish);
    await _scanner.dispose();
    for (final connection in _connections.values) {
      connection.snapshot.removeListener(_publish);
      await connection.dispose();
    }
    _connections.clear();
    snapshot.dispose();
  }
}
