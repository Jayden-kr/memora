import 'package:flutter/material.dart';

import '../database/database_helper.dart';
import '../l10n/app_localizations.dart';
import '../services/locale_service.dart';
import '../utils/constants.dart';
import '../widgets/soft_segmented_control.dart';

class SettingsScreen extends StatefulWidget {
  final ValueNotifier<ThemeMode>? themeModeNotifier;

  const SettingsScreen({super.key, this.themeModeNotifier});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Map<String, String> _settings = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final settings = await DatabaseHelper.instance.getAllSettings();
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      final t = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.settingsLoadFailed(e.toString()))),
      );
    }
  }

  String _getSetting(String key, String defaultValue,
      [Set<String>? validValues]) {
    final value = _settings[key] ?? defaultValue;
    if (validValues != null && !validValues.contains(value)) {
      return defaultValue;
    }
    return value;
  }

  Future<void> _setSetting(String key, String value) async {
    try {
      await DatabaseHelper.instance.upsertSetting(key, value);
      if (!mounted) return;
      setState(() => _settings[key] = value);

      // 테마 변경 즉시 반영
      if (key == AppConstants.settingThemeMode &&
          widget.themeModeNotifier != null) {
        switch (value) {
          case 'light':
            widget.themeModeNotifier!.value = ThemeMode.light;
          case 'dark':
            widget.themeModeNotifier!.value = ThemeMode.dark;
          default:
            widget.themeModeNotifier!.value = ThemeMode.system;
        }
      }
    } catch (e) {
      if (!mounted) return;
      final t = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.settingsSaveFailed(e.toString()))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);

    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(t.settingsTitle)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final answerFold = _getSetting(
        AppConstants.settingAnswerFold, 'expanded', {'expanded', 'collapsed'});
    final answerVisibility = _getSetting(
        AppConstants.settingAnswerVisibility, 'visible', {'visible', 'hidden'});
    final cardNumber =
        _getSetting(AppConstants.settingCardNumber, 'false', {'true', 'false'});
    final cardScroll =
        _getSetting(AppConstants.settingCardScroll, 'false', {'true', 'false'});
    final themeMode = _getSetting(
        AppConstants.settingThemeMode, 'system', {'light', 'dark', 'system'});

    return Scaffold(
      appBar: AppBar(title: Text(t.settingsTitle)),
      body: ListView(
        children: [
          // 정답 접기 펼치기 기본값
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(t.settingsAnswerFoldDefault,
                style: Theme.of(context).textTheme.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: SoftSegmentedControl<String>(
              segments: [
                SoftSegment(
                    value: 'expanded',
                    label: t.settingsAnswerFoldExpanded),
                SoftSegment(
                    value: 'collapsed',
                    label: t.settingsAnswerFoldCollapsed),
              ],
              selected: answerFold,
              onChanged: (v) =>
                  _setSetting(AppConstants.settingAnswerFold, v),
            ),
          ),
          const Divider(),

          // 정답 보이고 가리기 기본값
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(t.settingsAnswerVisibilityDefault,
                style: Theme.of(context).textTheme.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: SoftSegmentedControl<String>(
              segments: [
                SoftSegment(
                    value: 'visible', label: t.settingsAnswerVisible),
                SoftSegment(
                    value: 'hidden', label: t.settingsAnswerHidden),
              ],
              selected: answerVisibility,
              onChanged: (v) =>
                  _setSetting(AppConstants.settingAnswerVisibility, v),
            ),
          ),
          const Divider(),

          // 카드 번호 표시
          ListTile(
            title: Text(t.settingsCardNumber),
            trailing: Transform.scale(
              scale: 0.8,
              child: Switch(
                value: cardNumber == 'true',
                onChanged: (v) =>
                    _setSetting(AppConstants.settingCardNumber, v.toString()),
              ),
            ),
          ),
          const Divider(),

          // 카드 목록 스크롤바
          ListTile(
            title: Text(t.settingsCardScroll),
            trailing: Transform.scale(
              scale: 0.8,
              child: Switch(
                value: cardScroll == 'true',
                onChanged: (v) =>
                    _setSetting(AppConstants.settingCardScroll, v.toString()),
              ),
            ),
          ),
          const Divider(),

          // 테마
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(t.settingsTheme,
                style: Theme.of(context).textTheme.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: SoftSegmentedControl<String>(
              segments: [
                SoftSegment(
                    value: 'system', label: t.settingsThemeSystem),
                SoftSegment(
                    value: 'light', label: t.settingsThemeLight),
                SoftSegment(
                    value: 'dark', label: t.settingsThemeDark),
              ],
              selected: themeMode,
              onChanged: (v) =>
                  _setSetting(AppConstants.settingThemeMode, v),
            ),
          ),
          const Divider(),

          // 언어
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(t.settingsLanguage,
                style: Theme.of(context).textTheme.titleSmall),
          ),
          ValueListenableBuilder<Locale?>(
            valueListenable: LocaleService.localeNotifier,
            builder: (context, locale, _) {
              final selected = locale?.languageCode ?? 'system';
              return Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: SoftSegmentedControl<String>(
                  segments: [
                    SoftSegment(
                        value: 'system', label: t.settingsLanguageSystem),
                    SoftSegment(
                        value: 'ko', label: t.settingsLanguageKorean),
                    SoftSegment(
                        value: 'en', label: t.settingsLanguageEnglish),
                  ],
                  selected: selected,
                  onChanged: (v) {
                    LocaleService.setLocale(v == 'system' ? null : v);
                  },
                ),
              );
            },
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
