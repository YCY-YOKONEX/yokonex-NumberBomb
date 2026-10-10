import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_strings.dart';
import 'feedback_service.dart';
import 'ble_protocol.dart';
import 'ble_shock_service.dart';
import 'game_engine.dart';
import 'motion_preset.dart';
import 'shock_rules.dart';

// 方向 A：近黑红底色，危险度只用红橙色变化，保证信息层级清楚。
const _navy = Color(0xFF0D0A0B);
const _navy2 = Color(0xFF171012);
const _paper = Color(0xFFF7ECE8);
const _muted = Color(0xFFA88B8A);
const _mint = Color(0xFFFF7165);
const _coral = Color(0xFFFF5A45);
const _yellow = Color(0xFFF29A58);
const _languagePreferenceKey = 'language';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  var initialLanguage = 'zh';
  try {
    final preferences = await SharedPreferences.getInstance();
    final saved = preferences.getString(_languagePreferenceKey);
    if (AppStrings.supportsCode(saved)) {
      initialLanguage = saved!;
    }
  } catch (_) {
    // 存储不可用时从中文启动。
  }
  await AppStrings.preload();
  runApp(NumberBombApp(initialLanguage: initialLanguage));
}

class NumberBombApp extends StatefulWidget {
  const NumberBombApp({
    super.key,
    this.bleHub,
    this.initialLanguage,
    this.motionPreset = MotionPreset.arcade,
    this.motionPreview = false,
  });

  final YycDjBleHub? bleHub;
  final String? initialLanguage;
  final MotionPreset motionPreset;
  final bool motionPreview;

  @override
  State<NumberBombApp> createState() => _NumberBombAppState();
}

class _NumberBombAppState extends State<NumberBombApp> {
  late Locale _locale;
  bool _languageChangedByUser = false;
  Future<void> _languageWrite = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _locale = Locale(
      AppStrings.supportsCode(widget.initialLanguage)
          ? widget.initialLanguage!
          : 'zh',
    );
    if (widget.initialLanguage == null) _restoreLanguage();
  }

  Future<void> _restoreLanguage() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (!mounted || _languageChangedByUser) return;
      final saved = preferences.getString(_languagePreferenceKey);
      setState(
        () => _locale = Locale(AppStrings.supportsCode(saved) ? saved! : 'zh'),
      );
    } catch (_) {
      // 存储不可用时继续使用默认中文。
    }
  }

  Future<void> _selectLanguage(String next) async {
    if (!AppStrings.supportsCode(next) || next == _locale.languageCode) return;
    _languageChangedByUser = true;
    setState(() => _locale = Locale(next));
    // 顺序保存，快速连续切换时以最后一次选择为准。
    _languageWrite = _languageWrite.then((_) async {
      try {
        final preferences = await SharedPreferences.getInstance();
        await preferences.setString(_languagePreferenceKey, next);
      } catch (_) {
        // 本次切换仍然生效，下次启动回到默认语言。
      }
    });
    await _languageWrite;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '役次元·数字炸弹',
      onGenerateTitle: (context) => AppStrings.of(context).text('appTitle'),
      locale: _locale,
      supportedLocales: AppStrings.languages
          .map((language) => Locale(language.code))
          .toList(),
      localizationsDelegates: const [
        AppStrings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        // 预览测试显式加载与 Android 相同的字体，正常运行仍使用系统字体。
        fontFamily: widget.motionPreview ? 'Roboto' : null,
        fontFamilyFallback: widget.motionPreview
            ? const ['Noto Sans CJK', 'Segoe UI Emoji', 'Noto Color Emoji']
            : null,
        scaffoldBackgroundColor: _navy,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _coral,
          brightness: Brightness.dark,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF100B0D),
          border: const OutlineInputBorder(
            borderRadius: BorderRadius.zero,
            borderSide: BorderSide(color: Color(0x33233348)),
          ),
          enabledBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.zero,
            borderSide: BorderSide(color: Color(0x33233348)),
          ),
          focusedBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.zero,
            borderSide: BorderSide(color: _coral, width: 1.5),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 14,
          ),
        ),
      ),
      home: GameScreen(
        onSelectLanguage: _selectLanguage,
        bleHub: widget.bleHub,
        motionPreset: widget.motionPreset,
        motionPreview: widget.motionPreview,
      ),
    );
  }
}

enum _Page { setup, chooser, game, result }

enum _Mode { solo, group }

enum _Prompt {
  guess,
  disconnected,
  chooser,
  locked,
  hit,
  timeout,
  higher,
  lower,
}

enum _TopAction { sound, vibration, reset }

typedef _OutputAssignment = ({String deviceId, ShockChannel channel});

// 按设备类别选定一套稳定尺寸，不对整页做缩放。
class _ResponsiveSpec {
  const _ResponsiveSpec(this.shortestSide);

  final double shortestSide;

  bool get tablet => shortestSide >= 600;
  bool get compactPhone => shortestSide < 360;
  double get pageHorizontal => tablet
      ? 30
      : compactPhone
      ? 12
      : 18;
  double get titleSize => tablet
      ? 26
      : compactPhone
      ? 21
      : 23;
  double get rangeSize => tablet
      ? 72
      : compactPhone
      ? 52
      : 64;
  double get rangeMinHeight => tablet
      ? 330
      : compactPhone
      ? 240
      : 270;
  double get padHeight => tablet
      ? 56
      : compactPhone
      ? 44
      : 50;

  static _ResponsiveSpec of(BuildContext context) =>
      _ResponsiveSpec(MediaQuery.sizeOf(context).shortestSide);
}

class GameScreen extends StatefulWidget {
  const GameScreen({
    super.key,
    required this.onSelectLanguage,
    this.bleHub,
    this.motionPreset = MotionPreset.arcade,
    this.motionPreview = false,
  });
  final ValueChanged<String> onSelectLanguage;
  final YycDjBleHub? bleHub;
  final MotionPreset motionPreset;
  final bool motionPreview;
  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  final _minController = TextEditingController(text: '1');
  final _maxController = TextEditingController(text: '100');
  final List<TextEditingController> _playerNameControllers = [
    TextEditingController(text: '玩家 2'),
    TextEditingController(text: '玩家 3'),
  ];
  int _nextPlayerNumber = 4;
  late final Map<TextEditingController, int> _defaultPlayerNumbers;
  final Map<String, int> _gameDefaultNames = {};
  String _lastLanguage = 'zh';
  final _chooserController = TextEditingController();
  final _guessController = TextEditingController();
  final _guessFocus = FocusNode();
  final _feedback = FeedbackService();
  late final YycDjBleHub _ble;
  final _random = Random();
  late final AnimationController _waveController;
  late final AnimationController _impactController;
  Duration? _activeMotionPeriod;
  double _impactStrength = 0;
  bool _appActive = true;
  bool _disposing = false;
  final List<Timer> _previewTimers = [];

  _Page _page = _Page.setup;
  _Mode _mode = _Mode.solo;
  Rule _rule = Rule.bomb;
  GameEngine? _engine;
  List<String> _names = [];
  String _chooser = 'Master';
  bool _exploding = false;
  bool _soundEnabled = true;
  bool _vibrationEnabled = true;
  final Map<int, _OutputAssignment> _assignments = {};
  final Set<int> _confirmedPlayers = {};
  _OutputAssignment? _soloAssignment;
  bool _shockBusy = false;
  bool _outputHasStarted = false;
  bool _showWaveform = false;
  Timer? _guessCountdownTimer;
  int _guessSecondsRemaining = 0;
  bool _countdownWaitingForOutput = false;
  int _initialShockIntensity = 0;
  int _currentShockIntensity = 0;
  int _lastOutputIntensity = 0;
  String _lastOutputPlayer = '';
  final int _shockFrequency = 10;
  final int _shockPulseWidth = 50;
  _Prompt _prompt = _Prompt.guess;

  String _t(String key, [Map<String, Object> values = const {}]) =>
      AppStrings.of(context).text(key, values);

  String _deviceName(BleDeviceInfo info) =>
      info.name.isEmpty ? _t('unnamedDevice', {'id': info.shortId}) : info.name;

  String _deviceGeneration(BleDeviceInfo info) => _t(switch (info.generation) {
    YycDjGeneration.v1 => 'firstGeneration',
    YycDjGeneration.v2 => 'secondGeneration',
    YycDjGeneration.unknown =>
      info.serviceMatched ? 'serviceDevice' : 'unrecognizedDevice',
  });

  String _deviceDistance(BleDeviceInfo info) => info.rssi == null
      ? _t('distanceUnknown')
      : _t('distanceEstimate', {
          'distance': pow(
            10,
            (-59 - info.rssi!) / 20,
          ).clamp(0.1, 99).toStringAsFixed(1),
        });

  String _bleErrorMessage(BleIssue? issue) => _t(switch (issue) {
    BleIssue.nearbyPermission => 'nearbyPermission',
    BleIssue.locationPermission => 'locationPermission',
    BleIssue.deviceServiceMissing => 'deviceServiceMissing',
    BleIssue.deviceLostDuringConnect => 'deviceLostDuringConnect',
    BleIssue.disconnected => 'deviceDisconnectedPause',
    BleIssue.connectFailed => 'connectFailed',
    BleIssue.scanFailed || null => 'scanFailed',
  });

  @override
  void initState() {
    super.initState();
    _ble = widget.bleHub ?? YycDjBleHub();
    _defaultPlayerNumbers = {
      _playerNameControllers[0]: 2,
      _playerNameControllers[1]: 3,
    };
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
    _impactController = AnimationController(vsync: this);
    WidgetsBinding.instance.addObserver(this);
    _ble.snapshot.addListener(_onBleChanged);
    if (widget.motionPreview) {
      _prepareMotionPreview();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _startMotionPreview();
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
    final language = Localizations.localeOf(context).languageCode;
    if (language == _lastLanguage) return;
    for (final entry in _defaultPlayerNumbers.entries) {
      // 仅默认名称留在映射中；自定义名称不会被语言切换覆盖。
      entry.key.text = _t('defaultPlayer', {'number': entry.value});
    }
    _lastLanguage = language;
    // 切换语言后移除上一语言留下的短提示。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ScaffoldMessenger.of(context).removeCurrentSnackBar();
    });
  }

  @override
  void dispose() {
    _disposing = true;
    WidgetsBinding.instance.removeObserver(this);
    _ble.snapshot.removeListener(_onBleChanged);
    for (final timer in _previewTimers) {
      timer.cancel();
    }
    _stopGuessCountdown();
    if (widget.bleHub == null) unawaited(_ble.dispose());
    _waveController.dispose();
    _impactController.dispose();
    _feedback.dispose();
    for (final controller in [
      _minController,
      _maxController,
      _chooserController,
      _guessController,
      ..._playerNameControllers,
    ]) {
      controller.dispose();
    }
    _guessFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    _syncMotion();
    // 只停止手机本地音效和震动；不发送 BLE 停止包，保证设备按时长继续输出。
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _feedback.stop();
      _stopImpact();
      _pauseGuessCountdown();
    } else if (state == AppLifecycleState.resumed && _page == _Page.game) {
      _syncHeartbeat();
      _resumeGuessCountdown();
    }
  }

  void _prepareMotionPreview() {
    // 固定同一局游戏供三档动效录制；设备和输出均由预览入口模拟。
    const deviceId = 'AA:BB:CC:DD:EE:FF';
    _mode = _Mode.group;
    _rule = Rule.bomb;
    _names = ['Master', '玩家 2', '玩家 3'];
    _gameDefaultNames.addAll({'玩家 2': 2, '玩家 3': 3});
    _assignments.addAll({
      1: (deviceId: deviceId, channel: ShockChannel.a),
      2: (deviceId: deviceId, channel: ShockChannel.b),
    });
    _confirmedPlayers.addAll({0, 1, 2});
    _engine = GameEngine(
      minimum: 1,
      maximum: 100,
      rule: Rule.bomb,
      names: _names.sublist(1),
      target: 42,
    );
    _page = _Page.game;
    _prompt = _Prompt.locked;
  }

  void _startMotionPreview() {
    _startGuessCountdown();
    for (final (delay, value) in [
      (const Duration(milliseconds: 4200), 30),
      (const Duration(milliseconds: 8400), 60),
      (const Duration(milliseconds: 12600), 42),
    ]) {
      _previewTimers.add(
        Timer(delay, () {
          if (!mounted || _page != _Page.game) return;
          _guessController.text = '$value';
          _submitGuess();
        }),
      );
    }
  }

  bool get _motionUrgent =>
      _page == _Page.game &&
      _guessCountdownTimer != null &&
      _guessSecondsRemaining > 0 &&
      _guessSecondsRemaining <= 2 &&
      _devicesReady &&
      !_shockBusy &&
      !_ble.snapshot.value.outputActive;

  void _playImpact({required bool hit}) {
    if (widget.motionPreset != MotionPreset.arcade ||
        MediaQuery.disableAnimationsOf(context) ||
        !_appActive) {
      return;
    }
    // 只抖游戏内容，不移动顶部紧急停止按钮；命中比普通失误更强。
    _impactStrength = hit ? 9 : 3;
    _impactController.duration = Duration(milliseconds: hit ? 620 : 260);
    _impactController.forward(from: 0);
  }

  void _stopImpact() {
    _impactController.stop();
    _impactController.value = 0;
    _impactStrength = 0;
  }

  void _onCountdownTick() {
    if (_guessSecondsRemaining <= 2 &&
        _guessSecondsRemaining > 0 &&
        widget.motionPreset == MotionPreset.arcade) {
      _feedback.urgentTick();
    }
  }

  void _syncMotion() {
    if (_disposing) return;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion && _impactController.isAnimating) _stopImpact();
    // 回合以外、设备断开或输出期间，不继续运行游戏危险度动效。
    if (!_appActive ||
        reduceMotion ||
        widget.motionPreset == MotionPreset.light ||
        _page != _Page.game ||
        !_devicesReady ||
        _shockBusy ||
        _ble.snapshot.value.outputActive) {
      _waveController.stop();
      _activeMotionPeriod = null;
      if (_waveController.value != 0) _waveController.value = 0;
      return;
    }
    final period = widget.motionPreset.pulsePeriod(
      _engine?.danger ?? 0,
      urgent: _motionUrgent,
    );
    if (_activeMotionPeriod == period && _waveController.isAnimating) return;
    _activeMotionPeriod = period;
    _waveController.repeat(period: period);
  }

  void _onBleChanged() {
    if (!mounted) return;
    final ble = _ble.snapshot.value;
    // 断线后必须由对应玩家重新确认接线。
    _confirmedPlayers.removeWhere(
      (index) =>
          index > 0 && !_ble.isConnected(_assignments[index]?.deviceId ?? ''),
    );
    if (_shockBusy && ble.outputActive) _outputHasStarted = true;
    final outputEnded = _shockBusy && _outputHasStarted && !ble.outputActive;
    if (outputEnded) {
      _shockBusy = false;
      _outputHasStarted = false;
      _showWaveform = false;
      if (_countdownWaitingForOutput) {
        _countdownWaitingForOutput = false;
        _startGuessCountdown();
      }
    }
    if (!_devicesReady && _page == _Page.game) {
      _prompt = _Prompt.disconnected;
      _stopImpact();
    }
    setState(() {});
    if (outputEnded && _page == _Page.game) _focusGuess();
    if (!_devicesReady) {
      _pauseGuessCountdown();
    } else if (_page == _Page.game && !_shockBusy) {
      _resumeGuessCountdown();
    }
    _syncMotion();
  }

  List<String> get _groupNames => [
    'Master',
    ..._playerNameControllers.map((controller) => controller.text.trim()),
  ];

  String _displayPlayerName(String name) {
    if (_mode == _Mode.solo && name == '你') return _t('you');
    final number = _gameDefaultNames[name];
    return number == null ? name : _t('defaultPlayer', {'number': number});
  }

  String _guessHint(Guess guess) => switch (guess.relation) {
    -1 => _t('hintHigher'),
    1 => _t('hintLower'),
    2 => _t('promptTimeout'),
    _ => _t('hintHit'),
  };

  String get _promptTitle => switch (_prompt) {
    _Prompt.guess => _t('promptGuess'),
    _Prompt.disconnected => _t('promptDisconnected'),
    _Prompt.chooser => _t('promptChooser'),
    _Prompt.locked => _t('promptLocked'),
    _Prompt.hit => '💥 BOOM!',
    _Prompt.timeout => _t('promptTimeout'),
    _Prompt.higher => _t('hintHigher'),
    _Prompt.lower => _t('hintLower'),
  };

  String get _promptText => switch (_prompt) {
    _Prompt.guess => _t('enterNumber'),
    _Prompt.disconnected => _t('promptReconnect'),
    _Prompt.chooser => _t('promptPassNext'),
    _Prompt.locked => _t('promptHandOff'),
    _Prompt.hit => _t('promptHit'),
    _Prompt.timeout => _t('promptMiss'),
    _Prompt.higher || _Prompt.lower =>
      _engine?.remaining == 1
          ? _t('promptReveal', {'number': _engine!.lower})
          : _t('promptRange', {
              'min': _engine?.lower ?? 0,
              'max': _engine?.upper ?? 0,
            }),
  };

  void _addPlayer() {
    if (_playerNameControllers.length >= 7) return;
    setState(() {
      final number = _nextPlayerNumber++;
      final controller = TextEditingController(
        text: _t('defaultPlayer', {'number': number}),
      );
      _playerNameControllers.add(controller);
      _defaultPlayerNumbers[controller] = number;
    });
  }

  void _removePlayer(int index) {
    if (_playerNameControllers.length <= 2) return;
    final controller = _playerNameControllers[index - 1];
    setState(() {
      _playerNameControllers.removeAt(index - 1);
      _defaultPlayerNumbers.remove(controller);
      // 删除中间玩家时，设备通道和确认状态跟随剩余玩家前移。
      final assignments = Map<int, _OutputAssignment>.from(_assignments);
      _assignments.clear();
      for (final entry in assignments.entries) {
        if (entry.key == index) continue;
        _assignments[entry.key > index ? entry.key - 1 : entry.key] =
            entry.value;
      }
      final confirmed = Set<int>.from(_confirmedPlayers);
      _confirmedPlayers.clear();
      for (final playerIndex in confirmed) {
        if (playerIndex == index) continue;
        _confirmedPlayers.add(
          playerIndex > index ? playerIndex - 1 : playerIndex,
        );
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
  }

  _OutputAssignment? get _soloRoute {
    final chosen = _soloAssignment;
    if (chosen != null) {
      return _ble.isConnected(chosen.deviceId) ? chosen : null;
    }
    final devices = _ble.snapshot.value.connectedDevices;
    if (devices.isEmpty) return null;
    return (deviceId: devices.first.id, channel: ShockChannel.a);
  }

  bool get _devicesReady => _mode == _Mode.solo
      ? _soloRoute != null
      : _names.length > 1 &&
            _names.skip(1).indexed.every((entry) {
              final route = _assignments[entry.$1 + 1];
              return route != null && _ble.isConnected(route.deviceId);
            });

  bool get _allPlayersReady {
    final names = _groupNames;
    if (names.length < 3 ||
        names.any((name) => name.isEmpty) ||
        names.toSet().length != names.length) {
      return false;
    }
    final used = <_OutputAssignment>{};
    for (var index = 0; index < names.length; index++) {
      if (!_confirmedPlayers.contains(index)) return false;
      if (index == 0) continue;
      final route = _assignments[index];
      if (route == null ||
          !_ble.isConnected(route.deviceId) ||
          !used.add(route)) {
        return false;
      }
    }
    return true;
  }

  int? _parse(TextEditingController controller) =>
      int.tryParse(controller.text.trim());

  void _appendDigit(TextEditingController controller, String digit) {
    if (controller.text.length >= 4) return;
    controller
      ..text = '${controller.text}$digit'
      ..selection = TextSelection.collapsed(offset: controller.text.length);
    setState(() {});
  }

  void _removeDigit(TextEditingController controller) {
    if (controller.text.isEmpty) return;
    controller
      ..text = controller.text.substring(0, controller.text.length - 1)
      ..selection = TextSelection.collapsed(offset: controller.text.length);
    setState(() {});
  }

  void _clearDigits(TextEditingController controller) {
    controller.clear();
    setState(() {});
  }

  // 应用内数字键盘，避免系统键盘遮挡游戏操作区。
  Widget _numberPad(
    TextEditingController controller, {
    required VoidCallback? onConfirm,
    String? confirmLabel,
  }) {
    final enabled = onConfirm != null;
    final ui = _ResponsiveSpec.of(context);
    final rows = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
    ];
    return Column(
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                for (final digit in row) ...[
                  Expanded(
                    child: _padKey(
                      digit,
                      enabled ? () => _appendDigit(controller, digit) : null,
                      height: ui.padHeight,
                    ),
                  ),
                  if (digit != row.last) const SizedBox(width: 6),
                ],
              ],
            ),
          ),
        Row(
          children: [
            Expanded(
              child: _padKey(
                _t('clear'),
                enabled ? () => _clearDigits(controller) : null,
                height: ui.padHeight,
                muted: true,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _padKey(
                '0',
                enabled ? () => _appendDigit(controller, '0') : null,
                height: ui.padHeight,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _padKey(
                '',
                enabled ? () => _removeDigit(controller) : null,
                height: ui.padHeight,
                icon: Icons.backspace_outlined,
                muted: true,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: ui.padHeight,
          child: ElevatedButton.icon(
            onPressed: onConfirm,
            icon: const Icon(Icons.check_rounded, size: 18),
            label: Text(confirmLabel ?? _t('confirm')),
            style: ElevatedButton.styleFrom(
              backgroundColor: _coral,
              foregroundColor: Colors.white,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.zero,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _padKey(
    String label,
    VoidCallback? onPressed, {
    double height = 48,
    IconData? icon,
    bool muted = false,
  }) => SizedBox(
    height: height,
    child: OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: muted ? _muted : _paper,
        side: BorderSide(
          color: muted ? const Color(0x553D1E23) : _coral.withOpacity(.5),
        ),
        backgroundColor: muted
            ? const Color(0x12000000)
            : const Color(0x241F0E11),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        padding: EdgeInsets.zero,
      ),
      child: icon == null
          ? Text(label, style: TextStyle(fontSize: label.length > 1 ? 11 : 20))
          : Icon(icon, size: 18),
    ),
  );

  void _showMessage(String message, {Color color = _coral}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: color,
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  bool _readBounds() {
    final min = _parse(_minController);
    final max = _parse(_maxController);
    if (min == null || max == null || min < 0 || max > 9999 || min >= max) {
      _showMessage(_t('boundsError'));
      return false;
    }
    return true;
  }

  Future<void> _scanDevices() async {
    await _ble.scan();
    final ble = _ble.snapshot.value;
    if (mounted && ble.error != null) {
      _showMessage(_bleErrorMessage(ble.issue));
    }
  }

  Future<void> _connectDevice(BleDeviceInfo info) async {
    try {
      await _ble.connect(info);
      if (mounted) {
        _showMessage(
          _t('connectedTo', {'name': _deviceName(info)}),
          color: _mint,
        );
      }
    } catch (error) {
      if (mounted) {
        _showMessage(
          _bleErrorMessage(
            error is BleConnectionException
                ? error.issue
                : BleIssue.connectFailed,
          ),
        );
      }
    }
  }

  Future<void> _disconnectDevice(String id) async {
    await _ble.disconnect(id);
    if (mounted) _showMessage(_t('deviceDisconnected'), color: _yellow);
  }

  bool _requireConnectedDevice() {
    if (_devicesReady) return true;
    _showMessage(_t('connectYycFirst'));
    return false;
  }

  // 每个猜测回合都从 5 秒开始；输出或断开时只暂停，不消耗剩余时间。
  void _startGuessCountdown() {
    if (!mounted || _page != _Page.game || _engine == null) return;
    if (!_devicesReady ||
        _ble.snapshot.value.outputActive ||
        _shockBusy ||
        _engine!.finished) {
      return;
    }
    _guessCountdownTimer?.cancel();
    _guessSecondsRemaining = 5;
    setState(() {});
    _syncMotion();
    _guessCountdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (!_devicesReady || _ble.snapshot.value.outputActive || _shockBusy) {
        _pauseGuessCountdown();
        return;
      }
      if (_guessSecondsRemaining <= 1) {
        _stopGuessCountdown();
        _submitTimeout();
        return;
      }
      setState(() => _guessSecondsRemaining--);
      _onCountdownTick();
      _syncMotion();
    });
  }

  void _pauseGuessCountdown() {
    _guessCountdownTimer?.cancel();
    _guessCountdownTimer = null;
    if (mounted) _syncMotion();
  }

  void _resumeGuessCountdown() {
    if (!mounted || _page != _Page.game || _engine == null) return;
    if (_guessSecondsRemaining <= 0) {
      _startGuessCountdown();
      return;
    }
    if (_guessCountdownTimer == null &&
        _devicesReady &&
        !_ble.snapshot.value.outputActive &&
        !_shockBusy) {
      _guessCountdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        if (!_devicesReady || _ble.snapshot.value.outputActive || _shockBusy) {
          _pauseGuessCountdown();
          return;
        }
        if (_guessSecondsRemaining <= 1) {
          _stopGuessCountdown();
          _submitTimeout();
        } else {
          setState(() => _guessSecondsRemaining--);
          _onCountdownTick();
          _syncMotion();
        }
      });
      _syncMotion();
    }
  }

  void _stopGuessCountdown() {
    _guessCountdownTimer?.cancel();
    _guessCountdownTimer = null;
    _guessSecondsRemaining = 0;
    if (mounted) _syncMotion();
  }

  void _scheduleNextCountdown(
    Duration? shockDuration, {
    required int intensity,
    required String playerName,
  }) {
    if (_page != _Page.game || _engine?.finished == true) return;
    final shouldWait = shockDuration != null && _devicesReady && intensity > 0;
    if (shouldWait) {
      _countdownWaitingForOutput = true;
      unawaited(
        _triggerShock(
          shockDuration,
          intensity: intensity,
          playerName: playerName,
        ),
      );
    } else {
      _startGuessCountdown();
    }
  }

  Future<void> _triggerShock(
    Duration duration, {
    required int intensity,
    required String playerName,
  }) async {
    // 回合已经轮换，惩罚仍要落到刚刚猜测的玩家通道。
    final playerIndex = _mode == _Mode.solo ? -1 : _names.indexOf(playerName);
    final route = _mode == _Mode.solo ? _soloRoute : _assignments[playerIndex];
    if (route == null || !_ble.isConnected(route.deviceId)) {
      if (mounted) _showMessage(_t('outputSkipped'));
      return;
    }
    setState(() {
      _shockBusy = true;
      _outputHasStarted = false;
      _lastOutputIntensity = intensity;
      _lastOutputPlayer = playerName;
    });
    try {
      await _ble.startOutput(
        deviceId: route.deviceId,
        channel: route.channel,
        intensity: intensity,
        frequency: _shockFrequency,
        pulseWidth: _shockPulseWidth,
        duration: duration,
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _shockBusy = false;
          _outputHasStarted = false;
        });
        if (_countdownWaitingForOutput) {
          _countdownWaitingForOutput = false;
          _startGuessCountdown();
        }
        _showMessage(_t('outputFailed'));
      }
    }
  }

  Future<void> _emergencyStop() async {
    await _ble.emergencyStop();
    if (mounted) {
      _stopImpact();
      final resumeCountdown = _countdownWaitingForOutput;
      _countdownWaitingForOutput = false;
      setState(() {
        _shockBusy = false;
        _outputHasStarted = false;
        _showWaveform = false;
      });
      if (resumeCountdown) _startGuessCountdown();
      _showMessage(_t('emergencyStopped'), color: _mint);
    }
  }

  void _start() {
    if (_ble.snapshot.value.outputActive) {
      _showMessage(_t('waitForOutput'));
      return;
    }
    if (!_readBounds()) return;
    final minimum = _parse(_minController)!;
    final maximum = _parse(_maxController)!;
    if (_mode == _Mode.solo) {
      if (!_requireConnectedDevice()) return;
      _soloAssignment ??= _soloRoute;
      if (_rule == Rule.elimination) {
        _showMessage(_t('eliminationNeedsGroup'));
        return;
      }
      _engine = GameEngine(
        minimum: minimum,
        maximum: maximum,
        rule: _rule,
        names: const ['你'],
        random: _random,
      );
      _feedback.setActive(true);
      setState(() {
        _page = _Page.game;
        _currentShockIntensity = _initialShockIntensity;
        _lastOutputIntensity = _initialShockIntensity;
        _prompt = _Prompt.guess;
      });
      _syncHeartbeat();
      _focusGuess();
      _startGuessCountdown();
      return;
    }
    _names = _groupNames;
    if (_names.length < 3) {
      _showMessage(_t('groupNeedsPlayers'));
      return;
    }
    if (_names.any((name) => name.isEmpty)) {
      _showMessage(_t('namesRequired'));
      return;
    }
    if (_names.toSet().length != _names.length) {
      _showMessage(_t('namesUnique'));
      return;
    }
    if (!_allPlayersReady) {
      _showMessage(_t('playersNeedChannels'));
      return;
    }
    _gameDefaultNames.clear();
    for (final controller in _playerNameControllers) {
      final number = _defaultPlayerNumbers[controller];
      if (number != null) {
        _gameDefaultNames[controller.text.trim()] = number;
      }
    }
    _chooser = _names.first;
    _chooserController.clear();
    setState(() {
      _page = _Page.chooser;
      _currentShockIntensity = _initialShockIntensity;
      _lastOutputIntensity = _initialShockIntensity;
      _prompt = _Prompt.chooser;
    });
    _feedback.setActive(true);
  }

  void _lockBomb() {
    if (!_requireConnectedDevice()) return;
    if (!_allPlayersReady) {
      _showMessage(_t('playersNeedConfirmation'));
      return;
    }
    final value = _parse(_chooserController);
    final minimum = _parse(_minController)!;
    final maximum = _parse(_maxController)!;
    if (value == null || value < minimum || value > maximum) {
      _showMessage(_t('enterRangeNumber', {'min': minimum, 'max': maximum}));
      return;
    }
    _engine = GameEngine(
      minimum: minimum,
      maximum: maximum,
      rule: _rule,
      names: _names.sublist(1),
      target: value,
    );
    _chooserController.clear();
    _feedback.play('lock');
    setState(() {
      _page = _Page.game;
      _currentShockIntensity = _initialShockIntensity;
      _lastOutputIntensity = _initialShockIntensity;
      _prompt = _Prompt.locked;
    });
    _syncHeartbeat();
    _focusGuess();
    _startGuessCountdown();
  }

  void _submitGuess() {
    if (!_devicesReady) {
      _showMessage(_t('reconnectYyc'));
      return;
    }
    if (_ble.snapshot.value.outputActive || _shockBusy) {
      _showMessage(_t('waitForShock'), color: _yellow);
      return;
    }
    final engine = _engine;
    final value = _parse(_guessController);
    if (engine == null || value == null) {
      _showMessage(_t('enterInteger'));
      return;
    }
    try {
      final guess = engine.submit(value);
      _stopGuessCountdown();
      _guessController.clear();
      _processGuessResult(guess, engine);
    } on ArgumentError {
      _feedback.play('error');
      _showMessage(
        _t('enterRangeNumber', {'min': engine.lower, 'max': engine.upper}),
      );
    }
  }

  void _submitTimeout() {
    if (!mounted || _page != _Page.game || _engine == null) return;
    if (!_devicesReady || _ble.snapshot.value.outputActive || _shockBusy) {
      _resumeGuessCountdown();
      return;
    }
    final engine = _engine!;
    try {
      _stopGuessCountdown();
      final timeout = engine.submitTimeout();
      _guessController.clear();
      _processGuessResult(timeout, engine);
    } on StateError {
      _showMessage(_t('roundFinished'));
    }
  }

  void _processGuessResult(Guess guess, GameEngine engine) {
    // 先锁定本次强度；猜错惩罚模式的失误只影响之后的失败输出。
    final outputIntensity = _currentShockIntensity;
    final shockDuration = shockDurationFor(guess);
    if (guess.hit) {
      final reduceMotion = MediaQuery.disableAnimationsOf(context);
      _showWaveform = true;
      _feedback.boom(arcade: widget.motionPreset == MotionPreset.arcade);
      _playImpact(hit: true);
      if (shockDuration != null && outputIntensity > 0) {
        unawaited(
          _triggerShock(
            shockDuration,
            intensity: outputIntensity,
            playerName: guess.player,
          ),
        );
      }
      setState(() {
        _exploding = !reduceMotion;
        _prompt = _Prompt.hit;
      });
      _syncMotion();
      Future.delayed(
        reduceMotion ? Duration.zero : const Duration(milliseconds: 720),
        () {
          if (!mounted || !identical(_engine, engine) || _page != _Page.game) {
            return;
          }
          _feedback.stop();
          _stopImpact();
          setState(() {
            _exploding = false;
            _page = _Page.result;
          });
          _syncMotion();
        },
      );
      return;
    }
    _feedback.miss(
      timeout: guess.timeout,
      arcade: widget.motionPreset == MotionPreset.arcade,
    );
    _playImpact(hit: false);
    _showWaveform = false;
    setState(() {
      _currentShockIntensity = intensityAfterGuess(
        engine.rule,
        _currentShockIntensity,
        guess,
      );
      _prompt = guess.timeout
          ? _Prompt.timeout
          : guess.relation < 0
          ? _Prompt.higher
          : _Prompt.lower;
    });
    _syncMotion();
    if (engine.finished) {
      if (shockDuration != null && outputIntensity > 0) {
        unawaited(
          _triggerShock(
            shockDuration,
            intensity: outputIntensity,
            playerName: guess.player,
          ),
        );
      }
      _feedback.stop();
      _stopImpact();
      setState(() => _page = _Page.result);
      _syncMotion();
      return;
    }
    _syncHeartbeat();
    _scheduleNextCountdown(
      shockDuration,
      intensity: outputIntensity,
      playerName: guess.player,
    );
    _focusGuess();
  }

  void _syncHeartbeat() => _feedback.updateHeartbeat(
    _engine?.danger ?? 0,
    arcade: widget.motionPreset == MotionPreset.arcade,
  );
  void _focusGuess() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) FocusScope.of(context).requestFocus(_guessFocus);
  });

  void _reset() {
    _feedback.stop();
    _stopImpact();
    _stopGuessCountdown();
    _countdownWaitingForOutput = false;
    unawaited(_ble.emergencyStop());
    setState(() {
      _page = _Page.setup;
      _engine = null;
      _exploding = false;
      _shockBusy = false;
      _outputHasStarted = false;
      _showWaveform = false;
      _currentShockIntensity = _initialShockIntensity;
      _lastOutputIntensity = _initialShockIntensity;
      _prompt = _Prompt.guess;
    });
    _syncMotion();
  }

  void _toggleSound() {
    setState(() => _soundEnabled = !_soundEnabled);
    _feedback.soundEnabled = _soundEnabled;
    if (!_soundEnabled) _feedback.stop();
    _showMessage(_t(_soundEnabled ? 'soundOn' : 'soundOff'), color: _mint);
  }

  void _toggleVibration() {
    setState(() => _vibrationEnabled = !_vibrationEnabled);
    _feedback.vibrationEnabled = _vibrationEnabled;
    _showMessage(
      _t(_vibrationEnabled ? 'vibrationOn' : 'vibrationOff'),
      color: _mint,
    );
  }

  @override
  Widget build(BuildContext context) {
    final danger = _engine?.danger ?? 0;
    final dangerColor = danger >= .72
        ? _coral
        : danger >= .43
        ? _yellow
        : _mint;
    return Scaffold(
      body: AnimatedContainer(
        duration: const Duration(milliseconds: 500),
        color: Color.lerp(_navy, const Color(0xFF3A1318), danger) ?? _navy,
        child: SafeArea(
          child: Stack(
            children: [
              const _GridBackdrop(),
              Column(
                children: [
                  _buildTopBar(),
                  Expanded(
                    child: AnimatedBuilder(
                      animation: _impactController,
                      child: LayoutBuilder(
                        builder: (context, constraints) =>
                            _buildPage(constraints, dangerColor),
                      ),
                      builder: (context, child) {
                        final progress = _impactController.value;
                        final fade = (1 - progress) * (1 - progress);
                        return Transform.translate(
                          key: const ValueKey('game-impact'),
                          offset: Offset(
                            sin(progress * pi * 14) * fade * _impactStrength,
                            sin(progress * pi * 10) *
                                fade *
                                _impactStrength *
                                .35,
                          ),
                          child: child,
                        );
                      },
                    ),
                  ),
                  _buildFooter(),
                ],
              ),
              if (_exploding) _ExplosionOverlay(preset: widget.motionPreset),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    final ui = _ResponsiveSpec.of(context);
    final compact = MediaQuery.sizeOf(context).width < 600;
    final languageCode = Localizations.localeOf(context).languageCode;
    final cjkTitle =
        languageCode == 'zh' || languageCode == 'ja' || languageCode == 'ko';
    return Padding(
      padding: EdgeInsets.fromLTRB(
        ui.pageHorizontal,
        ui.tablet ? 18 : 10,
        ui.pageHorizontal,
        0,
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(border: Border.all(color: _mint)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final h in [.5, .75, 1.0])
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: FractionallySizedBox(
                        heightFactor: h,
                        alignment: Alignment.bottomCenter,
                        child: Container(color: _mint),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Semantics(
              label: _t('appTitle'),
              excludeSemantics: true,
              child: Wrap(
                children: [
                  Text(
                    '${_t('brandName')}·',
                    style: TextStyle(
                      color: _mint,
                      fontSize: compact ? (cjkTitle ? 14 : 12) : 21,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    _t('brandGame'),
                    style: TextStyle(
                      color: _paper,
                      fontSize: compact ? (cjkTitle ? 14 : 12) : 21,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: _t('emergencyStop'),
            onPressed: _ble.snapshot.value.outputActive || _shockBusy
                ? _emergencyStop
                : null,
            icon: Icon(
              Icons.stop_circle_outlined,
              color: _ble.snapshot.value.outputActive || _shockBusy
                  ? _coral
                  : _muted,
            ),
          ),
          PopupMenuButton<String>(
            tooltip: _t('language'),
            position: PopupMenuPosition.under,
            constraints: const BoxConstraints(minWidth: 180, maxWidth: 220),
            onSelected: widget.onSelectLanguage,
            itemBuilder: (context) => [
              for (final language in AppStrings.languages)
                PopupMenuItem<String>(
                  value: language.code,
                  height: 42,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 28,
                        child: Text(
                          language.shortLabel,
                          style: const TextStyle(color: _muted, fontSize: 11),
                        ),
                      ),
                      Expanded(child: Text(language.nativeName)),
                      if (language.code == languageCode)
                        const Icon(Icons.check, size: 16, color: _mint),
                    ],
                  ),
                ),
            ],
            child: SizedBox(
              width: 42,
              height: 48,
              child: Center(
                child: Text(
                  AppStrings.languageFor(languageCode).shortLabel,
                  style: const TextStyle(
                    color: _mint,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
          if (compact)
            PopupMenuButton<_TopAction>(
              tooltip: _t('more'),
              icon: const Icon(Icons.more_vert, color: _paper),
              onSelected: (action) {
                switch (action) {
                  case _TopAction.sound:
                    _toggleSound();
                  case _TopAction.vibration:
                    _toggleVibration();
                  case _TopAction.reset:
                    _reset();
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: _TopAction.sound,
                  child: Text(_t('sound')),
                ),
                PopupMenuItem(
                  value: _TopAction.vibration,
                  child: Text(_t('vibration')),
                ),
                PopupMenuItem(
                  value: _TopAction.reset,
                  child: Text(_t('reset')),
                ),
              ],
            )
          else ...[
            IconButton(
              tooltip: _t('sound'),
              onPressed: _toggleSound,
              icon: Icon(
                _soundEnabled
                    ? Icons.volume_up_outlined
                    : Icons.volume_off_outlined,
                color: _soundEnabled ? _mint : _muted,
              ),
            ),
            IconButton(
              tooltip: _t('vibration'),
              onPressed: _toggleVibration,
              icon: Icon(
                _vibrationEnabled
                    ? Icons.phone_android_outlined
                    : Icons.phone_disabled_outlined,
                color: _vibrationEnabled ? _mint : _muted,
              ),
            ),
            IconButton(
              tooltip: _t('reset'),
              onPressed: _reset,
              icon: const Icon(Icons.refresh, color: _paper),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPage(BoxConstraints constraints, Color dangerColor) {
    switch (_page) {
      case _Page.setup:
        return _buildSetup(constraints);
      case _Page.chooser:
        return _buildChooser();
      case _Page.game:
        return _buildGame(constraints, dangerColor);
      case _Page.result:
        return _buildResult();
    }
  }

  Widget _shell({
    required Widget child,
    double maxContentWidth = 1160,
    EdgeInsetsGeometry padding = const EdgeInsets.fromLTRB(18, 16, 18, 16),
  }) => SingleChildScrollView(
    padding: padding,
    physics: const ClampingScrollPhysics(),
    child: LayoutBuilder(
      builder: (context, available) {
        final width = min(available.maxWidth, maxContentWidth);
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: width,
            // 固定字号和控件尺寸，窄屏只改变布局宽度，内容超出时自然滚动。
            child: child,
          ),
        );
      },
    ),
  );

  Widget _buildSetup(BoxConstraints constraints) => _shell(
    maxContentWidth: 720,
    padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: _setupCard(),
    ),
  );

  Widget _setupCard() {
    final ui = _ResponsiveSpec.of(context);
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _t('startGame'),
                  style: TextStyle(
                    fontSize: ui.titleSize,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Icon(Icons.play_arrow_rounded, color: _mint),
            ],
          ),
          const SizedBox(height: 24),
          _segmented([
            (_t('solo'), '', _Mode.solo),
            (_t('group'), '', _Mode.group),
          ]),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(child: _numberField(_t('from'), _minController)),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: Text('—', style: TextStyle(color: _muted)),
              ),
              Expanded(child: _numberField(_t('to'), _maxController)),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            _t('rule'),
            style: const TextStyle(
              fontSize: 10,
              letterSpacing: 1.2,
              color: _muted,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: Rule.values
                .where(
                  (rule) => _mode == _Mode.group || rule != Rule.elimination,
                )
                .map(_ruleChip)
                .toList(),
          ),
          const SizedBox(height: 22),
          _blePanel(),
          if (_mode == _Mode.group) ...[
            const SizedBox(height: 18),
            _playerConnections(),
          ],
          const SizedBox(height: 24),
          _actionButton(
            _t(_mode == _Mode.solo ? 'startGame' : 'setBomb'),
            _mode == _Mode.solo
                ? (_soloRoute == null ? null : _start)
                : (_allPlayersReady ? _start : null),
          ),
        ],
      ),
    );
  }

  Widget _blePanel() => ValueListenableBuilder<BleSnapshot>(
    valueListenable: _ble.snapshot,
    builder: (context, ble, _) {
      final scanning =
          ble.scanInProgress || ble.status == BleConnectionStatus.scanning;
      final connected = ble.connected;
      final status = switch (ble.status) {
        BleConnectionStatus.connected => _t('connected'),
        BleConnectionStatus.connecting => _t('connecting'),
        BleConnectionStatus.scanning => _t('scanning'),
        BleConnectionStatus.disconnected => _t('disconnected'),
        BleConnectionStatus.error => _t('connectionError'),
        BleConnectionStatus.idle => _t('notConnected'),
      };
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          border: Border.all(
            color: connected ? _mint : const Color(0x33233348),
          ),
          color: const Color(0x140F1A2A),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bluetooth, size: 18, color: _mint),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _t('device'),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Flexible(
                  child: Text(
                    status,
                    textAlign: TextAlign.end,
                    style: TextStyle(color: connected ? _mint : _muted),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: _t('scanDevices'),
                  onPressed: scanning ? null : _scanDevices,
                  icon: AnimatedBuilder(
                    animation: _waveController,
                    builder: (context, child) => Transform.rotate(
                      angle: scanning ? _waveController.value * 2 * pi : 0,
                      child: Icon(
                        scanning ? Icons.sync : Icons.refresh,
                        size: 19,
                      ),
                    ),
                  ),
                  color: _mint,
                ),
              ],
            ),
            if (scanning) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(
                minHeight: 3,
                backgroundColor: Color(0x33233348),
                valueColor: AlwaysStoppedAnimation<Color>(_mint),
              ),
              const SizedBox(height: 5),
              Text(
                _t('searching'),
                style: const TextStyle(color: _mint, fontSize: 11),
              ),
            ],
            if (ble.scanCompleted) ...[
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: ble.recognizedDeviceCount > 0
                      ? const Color(0x1829D39A)
                      : const Color(0x18F7CB66),
                  border: Border.all(
                    color: ble.recognizedDeviceCount > 0
                        ? const Color(0x665DE5B7)
                        : const Color(0x66F7CB66),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      ble.recognizedDeviceCount > 0
                          ? Icons.check_circle_outline
                          : Icons.info_outline,
                      size: 16,
                      color: ble.recognizedDeviceCount > 0 ? _mint : _yellow,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        ble.recognizedDeviceCount > 0
                            ? _t('foundDevices', {
                                'count': ble.recognizedDeviceCount,
                              })
                            : _t('noDevices'),
                        style: TextStyle(
                          color: ble.recognizedDeviceCount > 0
                              ? _mint
                              : _yellow,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (ble.devices.isEmpty && ble.connectedDevices.isEmpty) ...[
              const SizedBox(height: 5),
              Text(
                _t('scanAndConnect'),
                style: const TextStyle(color: _muted, fontSize: 11),
              ),
            ],
            if (ble.connectedDevices.isNotEmpty) ...[
              const SizedBox(height: 8),
              ...ble.connectedDevices.map(
                (info) => Material(
                  color: Colors.transparent,
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(
                      Icons.bluetooth_connected,
                      color: _mint,
                    ),
                    title: Text('${_deviceName(info)} · ${info.shortId}'),
                    subtitle: Text(
                      '${_deviceGeneration(info)} · ${_deviceDistance(info)}',
                    ),
                    trailing: IconButton(
                      tooltip: _t('disconnectDevice', {
                        'name': _deviceName(info),
                      }),
                      onPressed: () => _disconnectDevice(info.id),
                      icon: const Icon(Icons.link_off, color: _yellow),
                    ),
                  ),
                ),
              ),
            ],
            if (ble.devices.isNotEmpty) ...[
              const SizedBox(height: 8),
              ...ble.devices
                  .where((info) => !_ble.isConnected(info.id))
                  .map(
                    (info) => Material(
                      color: Colors.transparent,
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(
                          Icons.electrical_services,
                          color: _mint,
                        ),
                        title: Text('${_deviceName(info)} · ${info.shortId}'),
                        subtitle: Text(
                          '${_deviceGeneration(info)} · ${_deviceDistance(info)}',
                        ),
                        trailing: const Icon(
                          Icons.chevron_right,
                          color: _muted,
                        ),
                        onTap: scanning ? null : () => _connectDevice(info),
                      ),
                    ),
                  ),
            ],
            if (ble.error != null) ...[
              const SizedBox(height: 4),
              Text(
                _bleErrorMessage(ble.issue),
                style: const TextStyle(color: _coral, fontSize: 11),
              ),
            ],
            const Divider(color: Color(0x24233348)),
            if (_mode == _Mode.solo && ble.connectedDevices.isNotEmpty)
              _soloChannelPicker(ble.connectedDevices),
            _settingSlider(
              label: _t('initialIntensity'),
              value: _initialShockIntensity.toDouble(),
              min: shockIntensityMin.toDouble(),
              max: shockIntensityMax.toDouble(),
              divisions: shockIntensityMax - shockIntensityMin,
              suffix: _t('deviceLevel', {
                'value': _initialShockIntensity,
                'max': shockIntensityMax,
                'level': YycDjProtocol.mapIntensityToDevice(
                  _initialShockIntensity,
                ),
              }),
              onChanged: (value) =>
                  setState(() => _initialShockIntensity = value.round()),
            ),
            const SizedBox(height: 2),
            Text(
              _t('intensityHelp'),
              style: const TextStyle(color: _muted, fontSize: 11, height: 1.4),
            ),
          ],
        ),
      );
    },
  );

  List<DropdownMenuItem<_OutputAssignment>> _channelOptions(
    List<BleDeviceInfo> devices, {
    int? playerIndex,
  }) => [
    for (final device in devices)
      for (final channel in ShockChannel.values)
        if (playerIndex == null ||
            !_assignments.entries.any(
              (entry) =>
                  entry.key != playerIndex &&
                  entry.value.deviceId == device.id &&
                  entry.value.channel == channel,
            ))
          DropdownMenuItem(
            value: (deviceId: device.id, channel: channel),
            child: Text(
              '${_deviceName(device)} · ${device.shortId} / ${channel.name.toUpperCase()}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
  ];

  Widget _soloChannelPicker(List<BleDeviceInfo> devices) {
    final options = _channelOptions(devices);
    final selected = _soloRoute;
    return DropdownButtonFormField<_OutputAssignment>(
      key: ValueKey('solo-${selected?.deviceId}-${selected?.channel}'),
      initialValue: options.any((item) => item.value == selected)
          ? selected
          : null,
      isExpanded: true,
      decoration: InputDecoration(labelText: _t('outputDeviceChannel')),
      items: options,
      onChanged: (value) => setState(() => _soloAssignment = value),
    );
  }

  Widget _playerConnections() {
    final names = _groupNames;
    final devices = _ble.snapshot.value.connectedDevices;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _t('bindPlayers'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Flexible(
              child: Text(
                _t('confirmedCount', {
                  'confirmed': _confirmedPlayers.length,
                  'total': names.length,
                }),
                textAlign: TextAlign.end,
                style: TextStyle(
                  color: _allPlayersReady ? _mint : _muted,
                  fontSize: 11,
                ),
              ),
            ),
            const SizedBox(width: 5),
            IconButton(
              tooltip: _t(
                _playerNameControllers.length >= 7 ? 'maxPlayers' : 'addPlayer',
              ),
              onPressed: _playerNameControllers.length >= 7 ? null : _addPlayer,
              icon: const Icon(Icons.person_add_alt_1_outlined),
              color: _mint,
            ),
          ],
        ),
        const SizedBox(height: 7),
        for (var index = 0; index < names.length; index++)
          _playerConnectionItem(index, devices),
      ],
    );
  }

  Widget _playerConnectionItem(int index, List<BleDeviceInfo> devices) {
    final confirmed = _confirmedPlayers.contains(index);
    final route = _assignments[index];
    final connected = route != null && _ble.isConnected(route.deviceId);
    final options = index == 0
        ? <DropdownMenuItem<_OutputAssignment>>[]
        : _channelOptions(devices, playerIndex: index);
    return Container(
      key: index == 0
          ? const ValueKey('master')
          : ValueKey(_playerNameControllers[index - 1]),
      margin: const EdgeInsets.only(bottom: 9),
      padding: const EdgeInsets.fromLTRB(12, 11, 10, 10),
      decoration: BoxDecoration(
        color: confirmed ? _mint.withOpacity(.06) : const Color(0x141A1113),
        border: Border(
          left: BorderSide(color: confirmed ? _mint : _yellow, width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: confirmed ? _mint : _yellow,
                child: Text(
                  '${index + 1}',
                  style: const TextStyle(
                    color: _navy,
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: index == 0
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Master',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          Text(
                            _t('chooser'),
                            style: const TextStyle(color: _muted, fontSize: 11),
                          ),
                        ],
                      )
                    : TextField(
                        controller: _playerNameControllers[index - 1],
                        inputFormatters: [LengthLimitingTextInputFormatter(16)],
                        decoration: InputDecoration(
                          hintText: _t('playerName'),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 11,
                          ),
                        ),
                        onChanged: (_) => setState(() {
                          _defaultPlayerNumbers.remove(
                            _playerNameControllers[index - 1],
                          );
                          _confirmedPlayers.remove(index);
                        }),
                      ),
              ),
              if (index > 0) ...[
                const SizedBox(width: 4),
                IconButton(
                  tooltip: _playerNameControllers.length <= 2
                      ? _t('minGuessers')
                      : _t('removePlayer', {'number': index + 1}),
                  onPressed: _playerNameControllers.length <= 2
                      ? null
                      : () => _removePlayer(index),
                  icon: const Icon(Icons.remove_circle_outline),
                  color: _muted,
                  iconSize: 22,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ],
          ),
          if (index > 0) ...[
            const SizedBox(height: 11),
            DropdownButtonFormField<_OutputAssignment>(
              key: ValueKey(
                'player-$index-${route?.deviceId}-${route?.channel}-${options.any((item) => item.value == route)}',
              ),
              initialValue: options.any((item) => item.value == route)
                  ? route
                  : null,
              isExpanded: true,
              decoration: InputDecoration(labelText: _t('deviceChannel')),
              hint: Text(_t('unbound')),
              items: options,
              onChanged: options.isEmpty
                  ? null
                  : (value) => setState(() {
                      if (value == null) return;
                      _assignments[index] = value;
                      _confirmedPlayers.remove(index);
                    }),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  _t(
                    index == 0
                        ? 'chooser'
                        : connected
                        ? 'deviceConnected'
                        : 'waitingForDevice',
                  ),
                  style: const TextStyle(color: _muted, fontSize: 11),
                ),
              ),
              SizedBox(
                width: 146,
                height: 46,
                child: OutlinedButton(
                  onPressed: index > 0 && !connected
                      ? null
                      : () => setState(() {
                          if (confirmed) {
                            _confirmedPlayers.remove(index);
                          } else {
                            _confirmedPlayers.add(index);
                          }
                        }),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: confirmed ? _mint : _paper,
                    side: BorderSide(
                      color: confirmed ? _mint : const Color(0x553D1E23),
                    ),
                    padding: EdgeInsets.zero,
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.zero,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        confirmed
                            ? Icons.verified_outlined
                            : Icons.check_circle_outline,
                        size: 16,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          _t(
                            confirmed
                                ? 'confirmed'
                                : index == 0
                                ? 'confirmReady'
                                : 'confirmConnected',
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _settingSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String suffix,
    required ValueChanged<double> onChanged,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: _muted, fontSize: 11),
            ),
          ),
          Flexible(
            child: Text(
              suffix,
              textAlign: TextAlign.end,
              style: const TextStyle(color: _paper, fontSize: 11),
            ),
          ),
        ],
      ),
      Slider(
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        onChanged: onChanged,
        activeColor: _coral,
        inactiveColor: const Color(0x33233348),
      ),
    ],
  );

  Widget _segmented(List<(String, String, _Mode)> items) => Row(
    children: items
        .map(
          (item) => Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() {
                _mode = item.$3;
                if (_mode == _Mode.solo && _rule == Rule.elimination) {
                  _rule = Rule.bomb;
                }
              }),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 11, right: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.$1,
                      style: TextStyle(
                        color: _mode == item.$3 ? _paper : _muted,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (item.$2.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        item.$2,
                        style: const TextStyle(fontSize: 10, color: _muted),
                      ),
                      const SizedBox(height: 10),
                    ] else
                      const SizedBox(height: 8),
                    Container(
                      height: 2,
                      color: _mode == item.$3 ? _mint : Colors.transparent,
                    ),
                  ],
                ),
              ),
            ),
          ),
        )
        .toList(),
  );

  Widget _ruleChip(Rule rule) => GestureDetector(
    onTap: () => setState(() => _rule = rule),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: 142,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: _rule == rule ? _mint.withOpacity(.1) : _navy2,
        border: Border.all(
          color: _rule == rule ? _mint : const Color(0x33233348),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _t(switch (rule) {
              Rule.bomb => 'bombRule',
              Rule.wrongPenalty => 'wrongRule',
              Rule.elimination => 'eliminationRule',
            }),
            style: TextStyle(
              color: _rule == rule ? _mint : _paper,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _t(switch (rule) {
              Rule.bomb => 'bombRuleDescription',
              Rule.wrongPenalty => 'wrongRuleDescription',
              Rule.elimination => 'eliminationRuleDescription',
            }),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _muted, fontSize: 10, height: 1.3),
          ),
        ],
      ),
    ),
  );

  Widget _numberField(String label, TextEditingController controller) =>
      _fieldLabel(
        label,
        TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        ),
      );
  Widget _fieldLabel(String label, Widget child) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label.toUpperCase(),
        style: const TextStyle(fontSize: 10, letterSpacing: 1.1, color: _muted),
      ),
      const SizedBox(height: 8),
      child,
    ],
  );
  Widget _actionButton(String label, VoidCallback? onPressed) => SizedBox(
    width: double.infinity,
    child: ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: _mint,
        foregroundColor: _navy,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          const Icon(Icons.arrow_outward, size: 20),
        ],
      ),
    ),
  );

  Widget _buildChooser() => _shell(
    maxContentWidth: 580,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 580),
      child: _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _t('setBombFor', {'name': _displayPlayerName(_chooser)}),
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w900,
                letterSpacing: -1,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _t('range', {
                'min': _parse(_minController) ?? 0,
                'max': _parse(_maxController) ?? 0,
              }),
              style: const TextStyle(color: _muted, height: 1.5),
            ),
            const SizedBox(height: 30),
            _fieldLabel(
              _t('number'),
              TextField(
                controller: _chooserController,
                readOnly: true,
                showCursor: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
            ),
            const SizedBox(height: 14),
            _numberPad(
              _chooserController,
              onConfirm: _lockBomb,
              confirmLabel: _t('lockBomb'),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _buildGame(BoxConstraints constraints, Color dangerColor) {
    final engine = _engine!;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _t('turn'),
                    style: const TextStyle(color: _muted, fontSize: 14),
                  ),
                ],
              ),
            ),
            AnimatedSwitcher(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : widget.motionPreset.turnDuration,
              transitionBuilder: _motionTextTransition,
              child: Text(
                _displayPlayerName(engine.currentPlayer.name).toUpperCase(),
                key: ValueKey(engine.currentPlayer.name),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  color: _paper,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 15),
            Text(
              '#${engine.history.length + 1}',
              style: const TextStyle(
                color: _muted,
                fontFamily: 'monospace',
                fontSize: 10,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _dangerMeter(engine, dangerColor),
        const SizedBox(height: 9),
        _shockIntensityStatus(),
        if (_ble.snapshot.value.outputActive || !_devicesReady) ...[
          const SizedBox(height: 13),
          _shockBar(),
          if (_ble.snapshot.value.outputActive && _showWaveform) ...[
            const SizedBox(height: 10),
            _shockWavePanel(),
          ],
        ],
        const SizedBox(height: 16),
        if (constraints.maxWidth >= 700)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _rangeStage(engine, dangerColor)),
              const SizedBox(width: 65),
              Expanded(child: _guessColumn(engine)),
            ],
          )
        else
          Column(
            children: [
              _rangeStage(engine, dangerColor),
              const SizedBox(height: 16),
              _guessColumn(engine),
            ],
          ),
        if (_mode == _Mode.group) ...[
          const SizedBox(height: 14),
          _playersStrip(engine),
        ],
        TextButton.icon(
          onPressed: _reset,
          icon: const Icon(Icons.arrow_back, size: 17),
          label: Text(_t('backToSetup')),
          style: TextButton.styleFrom(
            foregroundColor: _muted,
            padding: EdgeInsets.zero,
          ),
        ),
      ],
    );
    return _shell(
      maxContentWidth: 1160,
      child: content,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
    );
  }

  Widget _motionTextTransition(Widget child, Animation<double> animation) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final shift = switch (widget.motionPreset) {
      MotionPreset.original => 0.0,
      MotionPreset.light => 0.0,
      MotionPreset.tense => .08,
      MotionPreset.arcade => .14,
    };
    return FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: Offset(0, shift),
          end: Offset.zero,
        ).animate(animation),
        child: child,
      ),
    );
  }

  Widget _dangerMeter(GameEngine engine, Color dangerColor) => Row(
    children: [
      Text(
        _t('danger'),
        style: const TextStyle(fontSize: 10, letterSpacing: 1.5, color: _muted),
      ),
      const SizedBox(width: 13),
      Expanded(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: .07, end: max(.07, engine.danger)),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : widget.motionPreset.meterDuration,
          builder: (context, width, _) => ClipRect(
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: width,
                child: Container(height: 4, color: dangerColor),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(width: 13),
      Text(
        _t(
          engine.danger >= .72
              ? 'dangerCritical'
              : engine.danger >= .43
              ? 'dangerRising'
              : 'dangerLow',
        ),
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 10,
          color: dangerColor,
        ),
      ),
    ],
  );

  Widget _shockIntensityStatus() {
    final next = nextShockIntensity(_currentShockIntensity);
    final atMax = _currentShockIntensity >= shockIntensityMax;
    final increasesOnMiss = _rule == Rule.wrongPenalty;
    const accent = _coral;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 360),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: accent.withOpacity(.06),
        border: Border.all(color: accent.withOpacity(.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.bolt_rounded, color: accent, size: 17),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _t('currentIntensity', {
                    'value': _currentShockIntensity,
                    'max': shockIntensityMax,
                  }),
                  style: TextStyle(
                    color: _paper,
                    fontFamily: 'monospace',
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _t('outputToCurrentPlayer'),
                  style: const TextStyle(color: _muted, fontSize: 10),
                ),
              ],
            ),
          ),
          Text(
            increasesOnMiss
                ? atMax
                      ? _t('maxIntensity')
                      : _t('nextIntensity', {'value': next})
                : _t('fixedIntensity'),
            style: TextStyle(color: accent, fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _shockBar() {
    final ble = _ble.snapshot.value;
    final remaining = ble.outputRemaining.inMilliseconds <= 0
        ? 0
        : (ble.outputRemaining.inMilliseconds / 1000).ceil();
    final disconnected = !_devicesReady;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      decoration: BoxDecoration(
        color: (disconnected ? _coral : _yellow).withOpacity(.08),
        border: Border.all(
          color: (disconnected ? _coral : _yellow).withOpacity(.45),
        ),
      ),
      child: Row(
        children: [
          Icon(
            disconnected ? Icons.bluetooth_disabled : Icons.bolt,
            color: disconnected ? _coral : _yellow,
            size: 18,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              disconnected
                  ? _t('deviceDisconnectedPause')
                  : _t('playerOutput', {
                      'name': _displayPlayerName(_lastOutputPlayer),
                      'intensity': _lastOutputIntensity,
                      'seconds': remaining,
                    }),
              style: TextStyle(
                color: disconnected ? _coral : _yellow,
                fontSize: 12,
              ),
            ),
          ),
          if (!disconnected && ble.outputActive)
            IconButton(
              tooltip: _t('emergencyStop'),
              onPressed: _emergencyStop,
              icon: const Icon(Icons.stop_circle_outlined),
              color: _coral,
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }

  Widget _shockWavePanel() {
    final ble = _ble.snapshot.value;
    final remaining = ble.outputRemaining.inMilliseconds <= 0
        ? 0
        : (ble.outputRemaining.inMilliseconds / 1000).ceil();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 9),
      decoration: BoxDecoration(
        color: const Color(0xFF101B2B),
        border: Border.all(color: _coral.withOpacity(.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.monitor_heart_outlined, color: _coral, size: 17),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _t('shockWave'),
                  style: const TextStyle(color: _paper, fontSize: 12),
                ),
              ),
              Text(
                _t('remainingSeconds', {'seconds': remaining}),
                style: const TextStyle(color: _coral, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 7),
          SizedBox(
            height: 62,
            width: double.infinity,
            child: AnimatedBuilder(
              animation: _waveController,
              builder: (context, _) => CustomPaint(
                painter: _ShockWavePainter(
                  phase: _waveController.value,
                  active: ble.outputActive,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _rangeStage(GameEngine engine, Color dangerColor) => AnimatedBuilder(
    animation: _waveController,
    builder: (context, _) {
      final ui = _ResponsiveSpec.of(context);
      final reduceMotion = MediaQuery.disableAnimationsOf(context);
      final motion = widget.motionPreset;
      final urgent = _motionUrgent && !reduceMotion;
      final phase = _waveController.value;
      final pulse = reduceMotion || motion == MotionPreset.light
          ? .5
          : (sin(phase * 2 * pi) + 1) / 2;
      final singleValue = engine.remaining == 1;
      final bombAsset = engine.danger >= .84
          ? 'assets/bomb/bomb_burst.png'
          : engine.danger >= .38
          ? 'assets/bomb/bomb_hot.png'
          : 'assets/bomb/bomb_idle.png';
      final bombScale =
          .92 +
          engine.danger * .12 +
          (reduceMotion
              ? 0
              : max(0, sin(phase * 2 * pi)) * motion.bombPulse(urgent));
      final shake = Offset(
        sin(phase * 4 * pi) *
            (reduceMotion ? 0 : motion.shake(engine.danger, urgent: urgent)),
        0,
      );
      return Transform.translate(
        offset: motion == MotionPreset.original ? shake : Offset.zero,
        child: AnimatedContainer(
          duration: reduceMotion ? Duration.zero : motion.stageDuration,
          constraints: BoxConstraints(minHeight: ui.rangeMinHeight + 6),
          padding: const EdgeInsets.fromLTRB(13, 12, 13, 8),
          decoration: BoxDecoration(
            color: Color.lerp(
              const Color(0xFF100B0D),
              const Color(0xFF321016),
              engine.danger,
            ),
            border: Border.all(
              color: dangerColor.withOpacity(singleValue ? .7 : .45),
              width: singleValue ? 1.5 : 1,
            ),
            boxShadow:
                singleValue ||
                    (urgent &&
                        motion != MotionPreset.original &&
                        motion != MotionPreset.light)
                ? [
                    BoxShadow(
                      color: _coral.withOpacity(.12 + pulse * .2),
                      blurRadius: 18 + pulse * 12,
                    ),
                  ]
                : null,
          ),
          child: Stack(
            children: [
              Positioned(
                top: 0,
                left: 2,
                right: 2,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _t('coreRange'),
                        style: const TextStyle(
                          color: _muted,
                          fontSize: 10,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${(engine.danger * 100).round()}% ${_t('danger')}',
                      style: TextStyle(
                        color: dangerColor,
                        fontFamily: 'monospace',
                        fontSize: 9,
                        letterSpacing: .8,
                      ),
                    ),
                  ],
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: Transform.translate(
                    offset: motion == MotionPreset.arcade ? shake : Offset.zero,
                    child: CustomPaint(
                      painter: _BombHudPainter(
                        danger: engine.danger,
                        pulse: pulse,
                        rotation: motion == MotionPreset.arcade && !reduceMotion
                            ? phase * 2 * pi
                            : 0,
                      ),
                    ),
                  ),
                ),
              ),
              // 用户提供的素材只保留亮部，黑色背景透明后可继续看到 HUD 环。
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 24, 18, 22),
                  child: IgnorePointer(
                    child: AnimatedSwitcher(
                      duration: reduceMotion
                          ? Duration.zero
                          : motion.imageDuration,
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      child: Transform.translate(
                        offset: motion == MotionPreset.arcade
                            ? shake
                            : Offset.zero,
                        child: Transform.scale(
                          scale: bombScale,
                          child: ColorFiltered(
                            colorFilter: const ColorFilter.matrix([
                              1,
                              0,
                              0,
                              0,
                              0,
                              0,
                              1,
                              0,
                              0,
                              0,
                              0,
                              0,
                              1,
                              0,
                              0,
                              .34,
                              .34,
                              .34,
                              0,
                              -.06,
                            ]),
                            child: Image.asset(
                              bombAsset,
                              key: ValueKey(bombAsset),
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.high,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    const SizedBox(height: 38),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: AnimatedSwitcher(
                            duration: reduceMotion
                                ? Duration.zero
                                : motion.textDuration,
                            transitionBuilder: _motionTextTransition,
                            child: Text(
                              '${engine.lower}',
                              key: ValueKey(engine.lower),
                              textAlign: TextAlign.right,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: ui.rangeSize * .62,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -4,
                              ),
                            ),
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 9),
                          child: Text(
                            '—',
                            style: TextStyle(color: _yellow, fontSize: 22),
                          ),
                        ),
                        Flexible(
                          child: AnimatedSwitcher(
                            duration: reduceMotion
                                ? Duration.zero
                                : motion.textDuration,
                            transitionBuilder: _motionTextTransition,
                            child: Text(
                              '${engine.upper}',
                              key: ValueKey(engine.upper),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: ui.rangeSize * .62,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -4,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _t(singleValue ? 'lastNumber' : 'guessRange'),
                      style: TextStyle(
                        color: singleValue ? dangerColor : _muted,
                        fontSize: 9,
                        letterSpacing: .7,
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                right: 2,
                bottom: 1,
                child: Text(
                  _t('guessCount', {'count': engine.history.length}),
                  style: const TextStyle(
                    color: _muted,
                    fontFamily: 'monospace',
                    fontSize: 8,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _guessColumn(GameEngine engine) {
    final canGuess =
        _devicesReady && !_ble.snapshot.value.outputActive && !_shockBusy;
    final prompt = Container(
      key: ValueKey(_promptTitle),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _mint.withOpacity(.07),
        border: const Border(left: BorderSide(color: _mint, width: 3)),
      ),
      child: Row(
        children: [
          Container(
            width: 31,
            height: 31,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: _mint),
            ),
            child: Center(
              child: Text(
                _prompt == _Prompt.hit ? '!' : '?',
                style: const TextStyle(color: _mint, fontSize: 18),
              ),
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _promptTitle,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  _promptText,
                  style: const TextStyle(color: _muted, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    final input = TextField(
      controller: _guessController,
      focusNode: _guessFocus,
      readOnly: true,
      showCursor: true,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      enabled: canGuess,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedSwitcher(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : widget.motionPreset.promptDuration,
          transitionBuilder: _motionTextTransition,
          child: prompt,
        ),
        const SizedBox(height: 25),
        _fieldLabel(_t('enterNumber'), input),
        const SizedBox(height: 8),
        Row(
          children: [
            AnimatedBuilder(
              animation: _waveController,
              builder: (context, _) {
                final urgent =
                    _motionUrgent && !MediaQuery.disableAnimationsOf(context);
                final pulse = max(0, sin(_waveController.value * 2 * pi));
                final amount = switch (widget.motionPreset) {
                  MotionPreset.original => 0.0,
                  MotionPreset.light => 0.0,
                  MotionPreset.tense => .12,
                  MotionPreset.arcade => .22,
                };
                return Transform.scale(
                  scale: 1 + (urgent ? pulse * amount : 0),
                  child: Icon(
                    Icons.timer_outlined,
                    size: 14,
                    color: _guessSecondsRemaining <= 2 && canGuess
                        ? _coral
                        : _muted,
                  ),
                );
              },
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                canGuess && _guessSecondsRemaining > 0
                    ? _t('inputCountdown', {'seconds': _guessSecondsRemaining})
                    : _ble.snapshot.value.outputActive || _shockBusy
                    ? _t('penaltyOutput')
                    : canGuess
                    ? _t('nextRound')
                    : _devicesReady
                    ? _t('waitingDevice')
                    : _t('connectDeviceFirst'),
                style: TextStyle(
                  color: _guessSecondsRemaining <= 2 && canGuess
                      ? _coral
                      : _muted,
                  fontFamily: 'monospace',
                  fontSize: 10,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        Text(
          canGuess
              ? '${engine.lower} — ${engine.upper}'
              : _devicesReady
              ? _t('outputInProgress')
              : _t('connectDeviceFirst'),
          style: const TextStyle(
            color: _muted,
            fontFamily: 'monospace',
            fontSize: 10,
          ),
        ),
        const SizedBox(height: 12),
        _numberPad(
          _guessController,
          onConfirm: canGuess ? _submitGuess : null,
          confirmLabel: _t('guessNumber'),
        ),
        const SizedBox(height: 20),
        _history(engine),
      ],
    );
  }

  Widget _history(GameEngine engine) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Divider(color: Color(0x24233348)),
      const SizedBox(height: 13),
      Row(
        children: [
          Expanded(
            child: Text(
              _t('guessHistory'),
              style: const TextStyle(
                color: _muted,
                fontSize: 10,
                letterSpacing: 1.2,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '${engine.history.length} / ${engine.maximum - engine.minimum}',
            style: const TextStyle(
              color: _muted,
              fontFamily: 'monospace',
              fontSize: 10,
            ),
          ),
        ],
      ),
      const SizedBox(height: 11),
      if (engine.history.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 19),
          child: Text(
            _t('noGuesses'),
            style: const TextStyle(color: _muted, fontSize: 12),
          ),
        )
      else
        ...engine.history.reversed
            .take(3)
            .map(
              (guess) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_displayPlayerName(guess.player)} · ${guess.timeout ? _t('timeout') : guess.value}',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                        ),
                      ),
                    ),
                    Text(
                      guess.hit ? 'BOOM' : _guessHint(guess),
                      style: TextStyle(
                        color: guess.hit ? _coral : _mint,
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
    ],
  );

  String _playerChannelLabel(String name) {
    final route = _assignments[_names.indexOf(name)];
    if (route == null) return _t('unassigned');
    final id = route.deviceId;
    final shortId = id.length > 8 ? id.substring(id.length - 8) : id;
    return '$shortId/${route.channel.name.toUpperCase()}';
  }

  Widget _playersStrip(GameEngine engine) => LayoutBuilder(
    builder: (context, constraints) {
      final twoColumns = constraints.maxWidth >= 560;
      final itemWidth = twoColumns
          ? (constraints.maxWidth - 8) / 2
          : constraints.maxWidth;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _t('playerTurns'),
            style: const TextStyle(color: _muted, fontSize: 11),
          ),
          const SizedBox(height: 9),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (index, player) in engine.players.indexed)
                SizedBox(
                  width: itemWidth,
                  child: AnimatedContainer(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : widget.motionPreset.turnDuration,
                    constraints: const BoxConstraints(minHeight: 64),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color:
                          player == engine.currentPlayer && !player.eliminated
                          ? _mint.withOpacity(.08)
                          : _navy2,
                      border: Border.all(
                        color:
                            player == engine.currentPlayer && !player.eliminated
                            ? _mint
                            : const Color(0x33233348),
                      ),
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 15,
                          backgroundColor: player.eliminated
                              ? _muted
                              : player == engine.currentPlayer
                              ? _mint
                              : _yellow,
                          child: Text(
                            '${index + 2}',
                            style: const TextStyle(
                              color: _navy,
                              fontSize: 12,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _displayPlayerName(player.name),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: player.eliminated ? _muted : _paper,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                _playerChannelLabel(player.name),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: _muted,
                                  fontFamily: 'monospace',
                                  fontSize: 10,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          player.eliminated
                              ? _t('eliminated')
                              : player == engine.currentPlayer
                              ? _t('currentTurn')
                              : _t('missCount', {'count': player.misses}),
                          style: TextStyle(
                            color:
                                player == engine.currentPlayer &&
                                    !player.eliminated
                                ? _mint
                                : _muted,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      );
    },
  );

  Widget _buildResult() {
    final engine = _engine!;
    final last = engine.history.isNotEmpty ? engine.history.last : null;
    final winner = _displayPlayerName(
      engine.winner ?? last?.player ?? _t('playerFallback'),
    );
    final headline = engine.rule == Rule.elimination && engine.winner != null
        ? _t('survivorWins')
        : '💥 BOOM！';
    final resultCopy = engine.rule == Rule.elimination && engine.winner != null
        ? _t('survivorResult', {'name': winner})
        : _t('hitResult', {'name': winner});
    final resultNumber = Container(
      padding: const EdgeInsets.symmetric(horizontal: 37, vertical: 16),
      decoration: BoxDecoration(
        color: _coral.withOpacity(.08),
        border: Border.all(color: _coral.withOpacity(.45)),
      ),
      child: Column(
        children: [
          Text(
            _t('hiddenNumber'),
            style: const TextStyle(
              color: Color(0xFFBE8D83),
              fontFamily: 'monospace',
              fontSize: 10,
              letterSpacing: 1.3,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${engine.revealedTarget}',
            style: const TextStyle(
              color: _coral,
              fontSize: 60,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
    final playAgainButton = _actionButton(_t('playAgain'), _start);
    final setupAgainButton = OutlinedButton(
      onPressed: _reset,
      style: OutlinedButton.styleFrom(
        foregroundColor: _muted,
        side: const BorderSide(color: Color(0x33233348)),
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      ),
      child: Text(_t('setupAgain')),
    );
    return _shell(
      maxContentWidth: 670,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 670),
        child: Column(
          children: [
            const SizedBox(height: 28),
            Text(
              _t('countdownEnds'),
              style: const TextStyle(
                fontSize: 10,
                letterSpacing: 1.5,
                color: _mint,
              ),
            ),
            const SizedBox(height: 22),
            Text(
              headline,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 58,
                height: .98,
                color: _coral,
                fontWeight: FontWeight.w900,
                letterSpacing: -3,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              resultCopy,
              style: const TextStyle(color: Color(0xFFB4BECC), fontSize: 15),
            ),
            const SizedBox(height: 28),
            resultNumber,
            const SizedBox(height: 15),
            _resultShockPanel(),
            if (_ble.snapshot.value.outputActive && _showWaveform) ...[
              const SizedBox(height: 10),
              _shockWavePanel(),
            ],
            const SizedBox(height: 28),
            LayoutBuilder(
              builder: (context, constraints) => constraints.maxWidth < 364
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        playAgainButton,
                        const SizedBox(height: 8),
                        setupAgainButton,
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(child: playAgainButton),
                        const SizedBox(width: 8),
                        Expanded(child: setupAgainButton),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultShockPanel() {
    final ble = _ble.snapshot.value;
    final remaining = ble.outputRemaining.inMilliseconds <= 0
        ? 0
        : (ble.outputRemaining.inMilliseconds / 1000).ceil();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color(0x0AFFFFFF),
        border: Border.all(color: const Color(0x33233348)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              ble.outputActive
                  ? _t('deviceOutputRemaining', {'seconds': remaining})
                  : _t('outputStopped'),
              style: const TextStyle(color: _muted, fontSize: 12),
            ),
          ),
          if (ble.outputActive)
            OutlinedButton.icon(
              onPressed: _emergencyStop,
              icon: const Icon(Icons.stop_circle_outlined, size: 16),
              label: Text(_t('emergencyStop')),
              style: OutlinedButton.styleFrom(
                foregroundColor: _coral,
                side: const BorderSide(color: _coral),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFooter() => const SizedBox(height: 12);
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(27),
    decoration: BoxDecoration(
      color: _navy2.withOpacity(.96),
      border: Border.all(color: const Color(0x38233348)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x88000000),
          blurRadius: 24,
          offset: Offset(0, 12),
        ),
      ],
    ),
    child: child,
  );
}

class _GridBackdrop extends StatelessWidget {
  const _GridBackdrop();
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: CustomPaint(painter: _GridPainter(), size: Size.infinite),
  );
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(.045)
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 48)
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    for (var y = 0.0; y < size.height; y += 48)
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// 炸弹危险度轨道：用三个固定状态让玩家一眼看懂“远离、接近、快爆炸”。
class _BombHudPainter extends CustomPainter {
  const _BombHudPainter({
    required this.danger,
    required this.pulse,
    required this.rotation,
  });

  final double danger;
  final double pulse;
  final double rotation;

  @override
  void paint(Canvas canvas, Size size) {
    final level = danger.clamp(0.0, 1.0).toDouble();
    final center = Offset(size.width / 2, size.height * .47);
    final base = min(size.width, size.height) * .34;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = _coral.withOpacity(.24 + level * .3);
    for (var index = 0; index < 3; index++) {
      canvas.drawCircle(center, base * (1.0 + index * .13), ring);
    }
    final tick = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.square
      ..color = _yellow.withOpacity(.35 + level * .4);
    final tickRect = Rect.fromCircle(center: center, radius: base * 1.08);
    for (var index = 0; index < 32; index++) {
      final start = -pi / 2 + index * 2 * pi / 32 + pulse * .035 + rotation;
      canvas.drawArc(tickRect, start, index.isEven ? .08 : .035, false, tick);
    }
    final ray = Paint()
      ..strokeWidth = 1
      ..color = _coral.withOpacity(.12 + level * .22);
    for (var index = 0; index < 18; index++) {
      final angle = index * 2 * pi / 18 + pulse * .02 + rotation;
      final inner = base * 1.18;
      final outer = inner + (index.isEven ? 12 : 6);
      canvas.drawLine(
        center + Offset(cos(angle), sin(angle)) * inner,
        center + Offset(cos(angle), sin(angle)) * outer,
        ray,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BombHudPainter oldDelegate) =>
      oldDelegate.danger != danger ||
      oldDelegate.pulse != pulse ||
      oldDelegate.rotation != rotation;
}

class _ExplosionOverlay extends StatelessWidget {
  const _ExplosionOverlay({required this.preset});

  final MotionPreset preset;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 820),
          curve: Curves.easeOutCubic,
          builder: (context, progress, _) {
            final inverse = 1 - progress;
            final flash = (1 - progress * 4).clamp(0.0, 1.0);
            return Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  color: Colors.white.withOpacity(
                    flash * preset.explosionFlash,
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: ColorFiltered(
                      colorFilter: const ColorFilter.matrix([
                        1,
                        0,
                        0,
                        0,
                        0,
                        0,
                        1,
                        0,
                        0,
                        0,
                        0,
                        0,
                        1,
                        0,
                        0,
                        .34,
                        .34,
                        .34,
                        0,
                        -.06,
                      ]),
                      child: Opacity(
                        opacity: inverse * .82,
                        child: Image.asset(
                          'assets/bomb/bomb_burst.png',
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: CustomPaint(
                    painter: _ExplosionPainter(
                      progress: progress,
                      spread: preset.explosionSpread,
                    ),
                  ),
                ),
                for (final scale in [0.72, 1.08, 1.48])
                  Transform.scale(
                    scale: .3 + progress * scale * preset.explosionSpread,
                    child: Container(
                      width: 190,
                      height: 190,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _coral.withOpacity(inverse * .66),
                          width: 4 - progress * 2,
                        ),
                      ),
                    ),
                  ),
                Transform.scale(
                  scale: .45 + progress * .8,
                  child: Opacity(
                    opacity: inverse,
                    child: const Text(
                      'BOOM',
                      style: TextStyle(
                        color: _coral,
                        fontSize: 34,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 3,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// 爆炸裂片只在命中后出现，使用固定角度保证每次播放都稳定且不会乱跳。
class _ExplosionPainter extends CustomPainter {
  const _ExplosionPainter({required this.progress, required this.spread});

  final double progress;
  final double spread;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final shardPaint = Paint()
      ..color = _yellow.withOpacity((1 - progress) * .85)
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    final count = 18;
    for (var index = 0; index < count; index++) {
      final angle = -pi / 2 + index * 2 * pi / count;
      final startRadius = 25 + progress * 40;
      final endRadius = 78 + progress * 190 * spread + (index % 3) * 18;
      final start = center + Offset(cos(angle), sin(angle)) * startRadius;
      final end = center + Offset(cos(angle), sin(angle)) * endRadius;
      canvas.drawLine(start, end, shardPaint);
      canvas.save();
      canvas.translate(end.dx, end.dy);
      canvas.rotate(angle + pi / 4);
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset.zero,
          width: 5 + progress * 3,
          height: 5 + progress * 3,
        ),
        shardPaint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ExplosionPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.spread != spread;
}

class _ShockWavePainter extends CustomPainter {
  const _ShockWavePainter({required this.phase, required this.active});

  final double phase;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = const Color(0x33233348)
      ..strokeWidth = 1;
    for (var x = 0.0; x <= size.width; x += 32) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var y = 0.0; y <= size.height; y += 20) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    final wave = Paint()
      ..color = active ? _coral : _muted
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    final path = Path();
    final center = size.height / 2;
    for (var index = 0; index <= size.width; index++) {
      final x = index.toDouble();
      final normalized = x / size.width;
      final pulse = sin((normalized * 18 * pi) + phase * 2 * pi);
      final envelope = .35 + .65 * sin(normalized * pi).abs();
      final y = center - pulse * (size.height * .28) * envelope;
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, wave);
  }

  @override
  bool shouldRepaint(covariant _ShockWavePainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.active != active;
}
