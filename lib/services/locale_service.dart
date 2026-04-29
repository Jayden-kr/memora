import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 사용자 선택 언어 영구 저장 + 전역 ValueNotifier 노출.
/// null = 시스템 기본값 따라가기.
class LocaleService {
  /// 현재 활성 언어 코드 — context 없는 곳(서비스/알림)에서 사용.
  /// 사용자 설정값이 있으면 그것, 없으면 시스템 locale.
  static String currentLanguageCode() {
    final saved = localeNotifier.value;
    if (saved != null) return saved.languageCode;
    final sys = ui.PlatformDispatcher.instance.locale.languageCode;
    return supportedLocales.any((l) => l.languageCode == sys) ? sys : 'ko';
  }

  static const _kLocaleCode = 'app_locale_code';

  static final ValueNotifier<Locale?> localeNotifier =
      ValueNotifier<Locale?>(null);

  static const supportedLocales = <Locale>[
    Locale('ko'),
    Locale('en'),
  ];

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_kLocaleCode);
    if (code == null || code.isEmpty) {
      localeNotifier.value = null;
      return;
    }
    if (supportedLocales.any((l) => l.languageCode == code)) {
      localeNotifier.value = Locale(code);
    } else {
      localeNotifier.value = null;
    }
  }

  /// languageCode == null → 시스템 기본값으로 되돌림.
  static Future<void> setLocale(String? languageCode) async {
    final prefs = await SharedPreferences.getInstance();
    if (languageCode == null || languageCode.isEmpty) {
      await prefs.remove(_kLocaleCode);
      localeNotifier.value = null;
      return;
    }
    await prefs.setString(_kLocaleCode, languageCode);
    localeNotifier.value = Locale(languageCode);
  }
}
