import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'database/database_helper.dart';
import 'models/card.dart';
import 'models/folder.dart';
import 'screens/card_list_screen.dart';
import 'screens/export_screen.dart';
import 'screens/import_screen.dart';
import 'screens/lock_screen_settings.dart' show LockScreenSettingsScreen;
import 'screens/push_notification_settings.dart' show PushNotificationSettingsScreen;
import 'services/import_export_controller.dart';
import 'services/lock_screen_service.dart';
import 'services/notification_service.dart';
import 'utils/constants.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.initialize();

  // 이전 실행에서 남은 stale 상태 정리 (앱 강제 종료 시 foreground 알림 잔류 방지)
  ImportExportController.instance.cleanupStaleState();

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
  } catch (e) {
    debugPrint('Failed to load theme setting: $e');
  }

  // 잠금화면 서비스 자동 재시작 (enabled 상태면)
  _restoreLockScreenService();

  // 알림 권한 요청 + 재스케줄링
  NotificationService.requestPermission().then((_) async {
    try {
      await NotificationService.rescheduleAll();
    } catch (_) {}
  });

  // 알림 탭 → 카드 네비게이션 콜백 등록
  NotificationService.onNavigate = _handleNotificationNav;

  // Import/Export 알림 탭 → ImportScreen 네비게이션
  const importExportChannel =
      MethodChannel('com.henry.memora/import_export');
  importExportChannel.setMethodCallHandler((call) async {
    if (call.method == 'navigateToImport') {
      _handleImportNotificationTap();
    } else if (call.method == 'navigateToExport') {
      _handleExportNotificationTap();
    } else if (call.method == 'navigateToPushCard') {
      final args = call.arguments as Map?;
      if (args != null) {
        final folderId = (args['folderId'] as num?)?.toInt();
        final cardId = (args['cardId'] as num?)?.toInt();
        if (folderId != null && cardId != null) {
          _handleNotificationNav(NotificationNavEvent(folderId, cardId));
        }
      }
    } else if (call.method == 'navigateToSettings') {
      final target = call.arguments as String?;
      if (target != null) {
        _handleSettingsNavigation(target);
      }
    } else if (call.method == 'pdfProgress') {
      final args = call.arguments as Map?;
      if (args != null) {
        ImportExportController.instance.handleNativePdfProgress(
          (args['current'] as num?)?.toInt() ?? 0,
          (args['total'] as num?)?.toInt() ?? 0,
          (args['message'] as String?) ?? '',
        );
      }
    }
  });

  runApp(const MemoraApp());

  // Cold-start: 위젯 트리 빌드 완료 후 보류 이벤트 처리
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final pending = NotificationService.consumePendingEvent();
    if (pending != null) {
      debugPrint('[MAIN] processing cold-start pending event');
      _handleNotificationNav(pending);
    }
    // 포그라운드 서비스 알림 탭 → 설정 화면 pending 처리
    final settingsTarget = _pendingSettingsTarget;
    if (settingsTarget != null) {
      _pendingSettingsTarget = null;
      debugPrint('[MAIN] processing cold-start pending settings: $settingsTarget');
      _handleSettingsNavigation(settingsTarget);
    }
  });
}

/// Cold-start 시 navigator 준비 전에 도착한 설정 네비게이션 대상
String? _pendingSettingsTarget;

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
  try {
    // 카드 조회 + 폴더 조회 병렬 실행 (event.folderId 활용)
    final results = await Future.wait([
      DatabaseHelper.instance.getCardById(event.cardId),
      DatabaseHelper.instance.getFolderById(event.folderId),
    ]);
    final card = results[0] as CardModel?;
    var folder = results[1] as Folder?;

    if (card == null) {
      debugPrint('[MAIN] card not found for id=${event.cardId}');
      return;
    }

    // 카드가 다른 폴더로 이동된 경우 → 현재 폴더로 보정
    if (card.folderId != event.folderId) {
      folder = await DatabaseHelper.instance.getFolderById(card.folderId);
    }

    final resolvedFolder = folder;
    if (resolvedFolder == null) {
      debugPrint('[MAIN] folder not found');
      return;
    }

    debugPrint('[MAIN] navigating to folder="${resolvedFolder.name}" scrollToCard=${card.id}');
    nav.popUntil((route) => route.isFirst);
    nav.push(MaterialPageRoute(
      builder: (_) => CardListScreen(
        folder: resolvedFolder,
        scrollToCardId: card.id,
      ),
    ));
  } catch (e) {
    debugPrint('[MAIN] _doNavigate 오류 (DB 연결 등): $e');
  }
}

void _handleImportNotificationTap() {
  // ImportScreen이 이미 열려 있으면 중복 push 방지
  if (ImportScreen.isOpen) return;

  final nav = navigatorKey.currentState;
  if (nav == null) return;

  nav.push(MaterialPageRoute(
    builder: (_) => const ImportScreen(filePath: '', progressOnly: true),
  ));
}

void _handleExportNotificationTap() {
  // ExportScreen이 이미 열려 있으면 중복 push 방지
  if (ExportScreen.isOpen) return;

  final nav = navigatorKey.currentState;
  if (nav == null) return;

  nav.push(MaterialPageRoute(
    builder: (_) => const ExportScreen(progressOnly: true),
  ));
}

void _handleSettingsNavigation(String target) {
  final nav = navigatorKey.currentState;
  if (nav == null) {
    // Cold-start: navigator 아직 준비 안 됨 → addPostFrameCallback에서 처리
    _pendingSettingsTarget = target;
    return;
  }

  Widget screen;
  switch (target) {
    case 'lock_screen_settings':
      screen = const LockScreenSettingsScreen();
    case 'push_notification_settings':
      screen = const PushNotificationSettingsScreen();
    default:
      return;
  }

  nav.popUntil((route) => route.isFirst);
  nav.push(MaterialPageRoute(builder: (_) => screen));
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
  } catch (e) {
    debugPrint('Failed to restore lock screen service: $e');
  }
}
