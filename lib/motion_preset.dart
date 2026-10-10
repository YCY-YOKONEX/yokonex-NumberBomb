enum MotionPreset {
  original,
  light,
  tense,
  arcade;

  static MotionPreset fromCode(String code) => switch (code) {
    'original' => MotionPreset.original,
    'light' => MotionPreset.light,
    'tense' => MotionPreset.tense,
    'arcade' => MotionPreset.arcade,
    _ => MotionPreset.arcade,
  };

  Duration get meterDuration => switch (this) {
    MotionPreset.original => Duration.zero,
    MotionPreset.light => const Duration(milliseconds: 320),
    MotionPreset.tense => const Duration(milliseconds: 440),
    MotionPreset.arcade => const Duration(milliseconds: 260),
  };

  Duration get textDuration => switch (this) {
    MotionPreset.original => Duration.zero,
    MotionPreset.light => const Duration(milliseconds: 170),
    MotionPreset.tense => const Duration(milliseconds: 280),
    MotionPreset.arcade => const Duration(milliseconds: 210),
  };

  Duration get turnDuration => switch (this) {
    MotionPreset.original => Duration.zero,
    MotionPreset.light => const Duration(milliseconds: 180),
    MotionPreset.tense => const Duration(milliseconds: 360),
    MotionPreset.arcade => const Duration(milliseconds: 240),
  };

  Duration pulsePeriod(double danger, {required bool urgent}) {
    if (this == MotionPreset.original || this == MotionPreset.light) {
      return const Duration(milliseconds: 900);
    }
    if (this == MotionPreset.arcade) {
      return Duration(
        milliseconds: urgent
            ? 320
            : danger >= .72
            ? 460
            : 620,
      );
    }
    return Duration(
      milliseconds: urgent
          ? 480
          : danger >= .72
          ? 650
          : 900,
    );
  }

  double bombPulse(bool urgent) => switch (this) {
    MotionPreset.original => 0,
    MotionPreset.light => 0,
    MotionPreset.tense => urgent ? .023 : .012,
    MotionPreset.arcade => urgent ? .065 : .032,
  };

  double shake(double danger, {required bool urgent}) => switch (this) {
    MotionPreset.original => danger >= .8 ? .7 : 0,
    MotionPreset.light => 0,
    MotionPreset.tense => 0,
    MotionPreset.arcade => urgent ? 4.0 : 0,
  };

  double get explosionFlash => switch (this) {
    MotionPreset.original => .3,
    MotionPreset.light => .12,
    MotionPreset.tense => .3,
    MotionPreset.arcade => .56,
  };

  double get explosionSpread => switch (this) {
    MotionPreset.original => 1.0,
    MotionPreset.light => .84,
    MotionPreset.tense => 1.0,
    MotionPreset.arcade => 1.38,
  };

  Duration get stageDuration => switch (this) {
    MotionPreset.original ||
    MotionPreset.tense => const Duration(milliseconds: 560),
    MotionPreset.light => const Duration(milliseconds: 320),
    MotionPreset.arcade => const Duration(milliseconds: 260),
  };

  Duration get imageDuration => switch (this) {
    MotionPreset.original ||
    MotionPreset.tense => const Duration(milliseconds: 420),
    MotionPreset.light => const Duration(milliseconds: 170),
    MotionPreset.arcade => const Duration(milliseconds: 210),
  };

  Duration get promptDuration => switch (this) {
    MotionPreset.original => const Duration(milliseconds: 220),
    _ => textDuration,
  };
}
