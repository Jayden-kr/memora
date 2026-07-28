import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 사용자 선택 언어 영구 저장 + 전역 ValueNotifier 노출.
/// null = 시스템 기본값 따라가기.
///
/// 이 값은 Flutter UI뿐 아니라 **네이티브(잠금화면·푸시·Import/Export 알림, PDF)에도
/// 그대로 전달된다**([_syncToNative]). 네이티브가 시스템 언어를 따라가면 앱 언어를
/// 영어로 바꿔도 알림만 한국어로 남는 문제가 생긴다.
class LocaleService {
  /// 네이티브 미러링 채널 (MainActivity의 APP_LANG_CHANNEL과 같아야 함).
  static const MethodChannel _channel =
      MethodChannel('com.henry.memora/app_lang');

  /// 현재 활성 언어 코드 — context 없는 곳(서비스/알림)에서 사용.
  /// 사용자 설정값이 있으면 그것, 없으면 시스템 locale.
  static String currentLanguageCode() {
    final saved = localeNotifier.value;
    if (saved != null) return saved.languageCode;
    final sys = ui.PlatformDispatcher.instance.locale.languageCode;
    // 미지원 시스템 언어면 'en' — MaterialApp이 supportedLocales의 첫 항목(en)으로
    // 해석하는 것과 같은 규칙이다. 여기만 'ko'였을 때 화면은 영어인데 알림은
    // 한국어로 갈리는 불일치가 있었다.
    return supportedLocales.any((l) => l.languageCode == sys) ? sys : 'en';
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
    } else if (supportedLocales.any((l) => l.languageCode == code)) {
      localeNotifier.value = Locale(code);
    } else {
      localeNotifier.value = null;
    }
    await _syncToNative();
  }

  /// languageCode == null → 시스템 기본값으로 되돌림.
  static Future<void> setLocale(String? languageCode) async {
    final prefs = await SharedPreferences.getInstance();
    if (languageCode == null || languageCode.isEmpty) {
      await prefs.remove(_kLocaleCode);
      localeNotifier.value = null;
    } else {
      await prefs.setString(_kLocaleCode, languageCode);
      localeNotifier.value = Locale(languageCode);
    }
    await _syncToNative();
  }

  /// 네이티브에 현재 언어를 알린다.
  ///
  /// 명시 선택이 없으면(시스템 따라가기) null을 보낸다 — 해석된 코드를 박아두면
  /// 나중에 폰 언어를 바꿔도 네이티브 알림이 안 따라오기 때문. 네이티브는 저장값이
  /// 없을 때 시스템 언어를 다시 본다.
  ///
  /// 실패해도 앱 동작에는 영향이 없다(다음 실행에서 다시 시도).
  static Future<void> _syncToNative() async {
    try {
      await _channel.invokeMethod<bool>(
        'setLanguage',
        {'lang': localeNotifier.value?.languageCode},
      );
    } catch (e) {
      debugPrint('[LOCALE] 네이티브 언어 동기화 실패: $e');
    }
  }
}
