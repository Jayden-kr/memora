import 'package:flutter/material.dart';

import 'app.dart';
import 'database/database_helper.dart';
import 'services/lock_screen_service.dart';
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

  // 잠금화면 서비스 자동 재시작 (enabled 상태면)
  _restoreLockScreenService();

  // 알림 권한 요청 + 재스케줄링
  NotificationService.requestPermission().then((_) {
    NotificationService.rescheduleAll();
    // 테스트 알림 (3초 후) — 확인 후 제거
    Future.delayed(const Duration(seconds: 3), () {
      NotificationService.showTestNotification();
    });
  });

  runApp(const MemoraApp());
}

Future<void> _restoreLockScreenService() async {
  try {
    final settings = await LockScreenService.getSettings();
    final enabled = settings['enabled'] as bool? ?? false;
    if (!enabled) return;

    final canDraw = await LockScreenService.canDrawOverlays();
    if (!canDraw) return;

    final folderIds = (settings['folderIds'] as List?)
            ?.map((e) => e as int)
            .toList() ??
        [];
    await LockScreenService.startService(
      enabled: true,
      folderIds: folderIds,
      finishedFilter: settings['finishedFilter'] as int? ?? -1,
      randomOrder: settings['randomOrder'] as bool? ?? true,
      reversed: settings['reversed'] as bool? ?? false,
      bgColor: settings['bgColor'] as int? ?? 0xFF1A1A2E,
    );
  } catch (_) {}
}
