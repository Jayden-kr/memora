import 'package:flutter/material.dart';

import 'app.dart';
import 'database/database_helper.dart';
import 'services/notification_service.dart';
import 'utils/constants.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.initialize();

  // 저장된 테마 모드 로드
  try {
    final settings = await DatabaseHelper.instance.getAllSettings();
    final themeStr = settings[AppConstants.settingThemeMode];
    switch (themeStr) {
      case 'light':
        themeModeNotifier.value = ThemeMode.light;
      case 'dark':
        themeModeNotifier.value = ThemeMode.dark;
      default:
        themeModeNotifier.value = ThemeMode.system;
    }
  } catch (_) {}

  runApp(const MemoraApp());
}
