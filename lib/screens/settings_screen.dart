import 'package:flutter/material.dart';

import '../database/database_helper.dart';
import '../utils/constants.dart';

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
    final settings = await DatabaseHelper.instance.getAllSettings();
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _loading = false;
    });
  }

  String _getSetting(String key, String defaultValue) {
    return _settings[key] ?? defaultValue;
  }

  Future<void> _setSetting(String key, String value) async {
    await DatabaseHelper.instance.upsertSetting(key, value);
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
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('설정')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final answerFold =
        _getSetting(AppConstants.settingAnswerFold, 'expanded');
    final answerVisibility =
        _getSetting(AppConstants.settingAnswerVisibility, 'visible');
    final cardPositionMemory =
        _getSetting(AppConstants.settingCardPositionMemory, 'false');
    final cardNumber =
        _getSetting(AppConstants.settingCardNumber, 'false');
    final cardScroll =
        _getSetting(AppConstants.settingCardScroll, 'false');
    final imageQuality =
        _getSetting(AppConstants.settingImageQuality, 'medium');
    final themeMode =
        _getSetting(AppConstants.settingThemeMode, 'system');

    return Scaffold(
      appBar: AppBar(title: const Text('설정')),
      body: ListView(
        children: [
          // 정답 접기 펼치기 기본값
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('정답 접기 펼치기 기본값',
                style: Theme.of(context).textTheme.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'expanded', label: Text('펼치기')),
                ButtonSegment(value: 'collapsed', label: Text('접기')),
              ],
              selected: {answerFold},
              onSelectionChanged: (v) =>
                  _setSetting(AppConstants.settingAnswerFold, v.first),
            ),
          ),
          const Divider(),

          // 정답 보이고 가리기 기본값
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('정답 보이고 가리기 기본값',
                style: Theme.of(context).textTheme.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'visible', label: Text('보이기')),
                ButtonSegment(value: 'hidden', label: Text('가리기')),
              ],
              selected: {answerVisibility},
              onSelectionChanged: (v) =>
                  _setSetting(AppConstants.settingAnswerVisibility, v.first),
            ),
          ),
          const Divider(),

          // 카드 위치 기억
          SwitchListTile(
            title: const Text('카드 위치 기억'),
            value: cardPositionMemory == 'true',
            onChanged: (v) => _setSetting(
                AppConstants.settingCardPositionMemory, v.toString()),
          ),
          const Divider(),

          // 카드 번호 표시
          SwitchListTile(
            title: const Text('카드 번호 표시'),
            value: cardNumber == 'true',
            onChanged: (v) =>
                _setSetting(AppConstants.settingCardNumber, v.toString()),
          ),
          const Divider(),

          // 카드 목록 스크롤바
          SwitchListTile(
            title: const Text('카드 목록 스크롤바'),
            value: cardScroll == 'true',
            onChanged: (v) =>
                _setSetting(AppConstants.settingCardScroll, v.toString()),
          ),
          const Divider(),

          // 이미지 품질
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('이미지 품질',
                style: Theme.of(context).textTheme.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'high', label: Text('상')),
                ButtonSegment(value: 'medium', label: Text('중')),
                ButtonSegment(value: 'low', label: Text('하')),
              ],
              selected: {imageQuality},
              onSelectionChanged: (v) =>
                  _setSetting(AppConstants.settingImageQuality, v.first),
            ),
          ),
          const Divider(),

          // 테마
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child:
                Text('테마', style: Theme.of(context).textTheme.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'system', label: Text('시스템')),
                ButtonSegment(value: 'light', label: Text('라이트')),
                ButtonSegment(value: 'dark', label: Text('다크')),
              ],
              selected: {themeMode},
              onSelectionChanged: (v) =>
                  _setSetting(AppConstants.settingThemeMode, v.first),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
