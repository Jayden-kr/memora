import 'package:flutter/material.dart';

import 'app.dart';
import 'database/database_helper.dart';
import 'models/folder.dart';
import 'screens/card_list_screen.dart';
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

  // 알림 탭 → 카드 네비게이션 콜백 등록
  NotificationService.onNavigate = _handleNotificationNav;

  runApp(const MemoraApp());

  // Cold-start: 위젯 트리 빌드 완료 후 보류 이벤트 처리
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final pending = NotificationService.consumePendingEvent();
    if (pending != null) {
      debugPrint('[MAIN] processing cold-start pending event');
      _handleNotificationNav(pending);
    }
  });
}

Future<void> _handleNotificationNav(NotificationNavEvent event) async {
  debugPrint(
      '[MAIN] _handleNotificationNav: folder=${event.folderId} card=${event.cardId}');

  final nav = navigatorKey.currentState;
  if (nav == null) {
    debugPrint('[MAIN] navigatorKey not ready, retrying in 500ms');
    // 위젯 트리가 아직 준비 안 됨 → 짧은 딜레이 후 재시도
    await Future.delayed(const Duration(milliseconds: 500));
    final retryNav = navigatorKey.currentState;
    if (retryNav == null) {
      debugPrint('[MAIN] navigatorKey still null after retry, giving up');
      return;
    }
    return _doNavigate(retryNav, event);
  }

  return _doNavigate(nav, event);
}

Future<void> _doNavigate(
    NavigatorState nav, NotificationNavEvent event) async {
  // DB에서 해당 카드를 직접 조회
  final card =
      await DatabaseHelper.instance.getCardById(event.cardId);
  if (card == null) {
    debugPrint('[MAIN] card not found for id=${event.cardId}');
    return;
  }

  // 폴더 조회
  final folder =
      await DatabaseHelper.instance.getFolderById(card.folderId);
  if (folder == null) {
    debugPrint('[MAIN] folder not found for id=${card.folderId}');
    return;
  }

  debugPrint('[MAIN] navigating to folder="${folder.name}" scrollToCard=${card.id}');
  nav.popUntil((route) => route.isFirst);
  nav.push(MaterialPageRoute(
    builder: (_) => CardListScreen(
      folder: folder,
      scrollToCardId: card.id,
    ),
  ));
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
