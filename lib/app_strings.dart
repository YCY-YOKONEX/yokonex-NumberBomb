import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class AppLanguage {
  const AppLanguage(this.code, this.nativeName, this.shortLabel);

  final String code;
  final String nativeName;
  final String shortLabel;
}

class AppStrings {
  AppStrings(this.locale, this._values);

  final Locale locale;
  final Map<String, String> _values;

  static const delegate = _AppStringsDelegate();
  static const languages = <AppLanguage>[
    AppLanguage('zh', '中文', '中'),
    AppLanguage('en', 'English', 'EN'),
    AppLanguage('fr', 'Français', 'FR'),
    AppLanguage('de', 'Deutsch', 'DE'),
    AppLanguage('nl', 'Nederlands', 'NL'),
    AppLanguage('es', 'Español', 'ES'),
    AppLanguage('ko', '한국어', 'KO'),
    AppLanguage('ja', '日本語', 'JA'),
    AppLanguage('it', 'Italiano', 'IT'),
    AppLanguage('ru', 'Русский', 'RU'),
  ];

  static bool supportsCode(String? code) =>
      languages.any((language) => language.code == code);

  static AppLanguage languageFor(String code) => languages.firstWhere(
    (language) => language.code == code,
    orElse: () => languages.first,
  );

  static Future<void> preload() async {
    // 首屏前加载所有语言，游戏中切换时不会出现空白帧。
    await Future.wait(
      languages.map((language) => delegate.load(Locale(language.code))),
    );
  }

  static AppStrings of(BuildContext context) =>
      Localizations.of<AppStrings>(context, AppStrings)!;

  String text(String key, [Map<String, Object> values = const {}]) {
    var result = _values[key];
    assert(
      result != null,
      'Missing translation: $key (${locale.languageCode})',
    );
    result ??= key;
    for (final entry in values.entries) {
      result = result!.replaceAll('{${entry.key}}', '${entry.value}');
    }
    return result!;
  }
}

class _AppStringsDelegate extends LocalizationsDelegate<AppStrings> {
  const _AppStringsDelegate();

  static final Map<String, AppStrings> _cache = {};

  @override
  bool isSupported(Locale locale) =>
      AppStrings.supportsCode(locale.languageCode);

  @override
  Future<AppStrings> load(Locale locale) {
    final language = isSupported(locale) ? locale.languageCode : 'zh';
    final cached = _cache[language];
    if (cached != null) return SynchronousFuture(cached);
    return rootBundle.loadString('assets/l10n/$language.json').then((source) {
      final values = (jsonDecode(source) as Map<String, dynamic>).map(
        (key, value) => MapEntry(key, value as String),
      );
      return _cache[language] = AppStrings(Locale(language), values);
    });
  }

  @override
  bool shouldReload(_AppStringsDelegate old) => false;
}
