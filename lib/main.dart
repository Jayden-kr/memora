import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'database/database_helper.dart';
import 'l10n/app_localizations.dart';
import 'models/card.dart';
import 'models/folder.dart';
import 'screens/card_edit_screen.dart';
import 'screens/card_list_screen.dart';
import 'screens/export_screen.dart';
import 'screens/import_screen.dart';
import 'screens/lock_screen_settings.dart' show LockScreenSettingsScreen;
import 'screens/push_notification_settings.dart' show PushNotificationSettingsScreen;
import 'services/import_export_controller.dart';
import 'services/locale_service.dart';
import 'services/lock_screen_service.dart';
import 'services/notification_service.dart';
import 'utils/constants.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.initialize();
  await LocaleService.load();

  // 이전 실행에서 남은 stale 상태 정리(import_in_progress 마커 등). 반드시 아래 GC보다
  // 먼저 끝나야 한다 — 둘 다 fire-and-forget이면 마커를 지우는 쪽과 검사하는 쪽의 순서가
  // 실행마다 달라져 "import 중이면 GC 스킵" 가드가 랜덤으로 켜졌다 꺼졌다 했다.
  await ImportExportController.instance.cleanupStaleState();

  // 앱 시작 시 1회 (fire-and-forget — 첫 프레임을 막지 않는다): ①파일 없는 카드의 깨진
  //   경로 복구/blank 처리 + ②어느 카드도 참조하지 않는 고아 미디어 파일 정리("흔적 0").
  //   UI와 동시에 돌므로 GC 쪽에 최근 파일 보호·마커 배치별 재검사·스캔 시점 id 상한
  //   안전장치가 있다(database_helper 참고).
  _startupMediaCleanupOnce();
  // 폴더 card_count 캐시를 실제 COUNT와 맞춘다(fire-and-forget) — 홈 타일(캐시)과 카드 목록
  // 앱바(실시간)가 다른 숫자를 보이던 어긋남 정리(X3-06).
  _resyncFolderCardCountsOnce();

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

  // 잠금화면이 참조하는 삭제된 폴더를 정리한 뒤 서비스를 복원한다. 폴더 삭제 직후의 정리는
  // fire-and-forget이라 그 창에서 앱이 죽거나 채널이 한 번 실패하면 "켜져 있는데 영원히 안 뜨는"
  // 상태가 영구히 남았다 — 시작할 때마다 대조해 스스로 낫게 한다(감사 D1-06).
  _reconcileLockScreenFoldersOnce().whenComplete(_restoreLockScreenService);

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
          // 결과를 그대로 돌려준다 — 네이티브는 false를 "아직 준비 안 됨"으로 읽고
          // 재시도한다. 예전엔 무조건 success라 콜드스타트 딥링크가 유실됐다(감사 D4-11).
          return await _handleNotificationNav(
              NotificationNavEvent(folderId, cardId));
        }
      }
    } else if (call.method == 'navigateToEditCard') {
      final args = call.arguments as Map?;
      if (args != null) {
        final folderId = (args['folderId'] as num?)?.toInt();
        final cardId = (args['cardId'] as num?)?.toInt();
        if (folderId != null && cardId != null) {
          return await _handleEditCardNav(folderId, cardId);
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

/// 앱 시작 시 미디어 정리 2단계를 순서대로 수행 (fire-and-forget).
/// ①깨진 경로 정리(참조는 있는데 파일 없음) → ②고아 파일 정리(파일은 있는데 참조 없음).
Future<void> _resyncFolderCardCountsOnce() async {
  try {
    final fixed = await DatabaseHelper.instance.resyncFolderCardCounts();
    if (fixed > 0) debugPrint('[STARTUP] folder card_count resynced: $fixed');
  } catch (e) {
    debugPrint('[STARTUP] folder card_count resync failed: $e');
  }
}

Future<void> _startupMediaCleanupOnce() async {
  await _cleanupBrokenImagePathsOnce();
  await _cleanupOrphanMediaFilesOnce();
}

/// 앱 시작 시 1회, 어느 카드도 참조하지 않는 images/ 고아 미디어 파일 정리.
/// import 진행 중이면 건너뜀 — import가 복사한 파일을 카드 insert 전에 지우지 않도록
/// (_cleanupBrokenImagePathsOnce와 동일 가드).
Future<void> _cleanupOrphanMediaFilesOnce() async {
  try {
    final settings = await DatabaseHelper.instance.getAllSettings();
    final importInProgress = settings['import_in_progress'];
    if (importInProgress != null && importInProgress.isNotEmpty) {
      debugPrint('[MAIN] import 진행 중, cleanupOrphanMediaFiles 건너뜀');
      return;
    }
    final deleted = await DatabaseHelper.instance.cleanupOrphanMediaFiles();
    if (deleted > 0) {
      debugPrint('[MAIN] cleanupOrphanMediaFiles: $deleted개 고아 파일 삭제됨');
    }
  } catch (e) {
    debugPrint('[MAIN] cleanupOrphanMediaFiles 실패: $e');
  }
}

/// 앱 시작 시 1회, 깨진 이미지/음성 경로 정리 (fire-and-forget).
/// import 진행 중이면 건너뜀 — insertCardsBatch 재복구가 빈 경로를 채우는
/// 방식으로 동작하므로, 진행 중인 import의 임시 상태와 경합하지 않도록 한다.
Future<void> _cleanupBrokenImagePathsOnce() async {
  try {
    final settings = await DatabaseHelper.instance.getAllSettings();
    final importInProgress = settings['import_in_progress'];
    if (importInProgress != null && importInProgress.isNotEmpty) {
      debugPrint('[MAIN] import 진행 중, cleanupBrokenImagePaths 건너뜀');
      return;
    }
    final cleaned = await DatabaseHelper.instance.cleanupBrokenImagePaths();
    if (cleaned > 0) {
      debugPrint('[MAIN] cleanupBrokenImagePaths: $cleaned개 경로 정리됨');
    }
  } catch (e) {
    debugPrint('[MAIN] cleanupBrokenImagePaths 실패: $e');
  }
}

/// Cold-start 시 navigator 준비 전에 도착한 설정 네비게이션 대상
String? _pendingSettingsTarget;

/// 편집 화면이 열려 있어 화면 이동을 건너뛰었다는 안내. 예전엔 탭해도 아무 일이
/// 일어나지 않아 사용자에겐 알림이 고장 난 것처럼 보였다(감사: 조용한 무시).
/// 화면 밖에서 호출되므로 전역 [scaffoldMessengerKey]를 쓴다.
void _notifyNavSkippedByEditor() {
  final messenger = scaffoldMessengerKey.currentState;
  final context = navigatorKey.currentContext;
  if (messenger == null || context == null) return;
  messenger.showSnackBar(
    SnackBar(content: Text(AppLocalizations.of(context).navSkippedWhileEditing)),
  );
}

/// 반환값 false = "아직 못 갔다, 다시 불러라"(네이티브 콜드스타트 재시도 신호, 감사 D4-11).
/// 의도적으로 건너뛴 경우(편집 화면이 열려 있음 등)는 재시도해도 소용없으므로 true다.
Future<bool> _handleNotificationNav(NotificationNavEvent event) async {
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
      return false;
    }
    return _doNavigate(retryNav, event);
  }

  return _doNavigate(nav, event);
}

Future<bool> _doNavigate(
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
      return true; // 카드가 없는 건 재시도해도 그대로다
    }

    // 카드가 다른 폴더로 이동된 경우 → 현재 폴더로 보정
    if (card.folderId != event.folderId) {
      folder = await DatabaseHelper.instance.getFolderById(card.folderId);
    }

    final resolvedFolder = folder;
    if (resolvedFolder == null) {
      debugPrint('[MAIN] folder not found');
      return true;
    }

    // 편집 화면이 열려 있으면 popUntil이 PopScope의 미저장-변경 가드를 우회해
    // 편집 중인 내용을 조용히 날려버린다 — 편집 중엔 알림 네비게이션을 건너뛴다.
    if (CardEditScreen.isOpen) {
      debugPrint('[MAIN] CardEditScreen open, skipping notification navigation');
      _notifyNavSkippedByEditor();
      return true; // 의도적 건너뜀 — 재시도 대상 아님
    }
    debugPrint('[MAIN] navigating to folder="${resolvedFolder.name}" scrollToCard=${card.id}');
    nav.popUntil((route) => route.isFirst);
    nav.push(MaterialPageRoute(
      builder: (_) => CardListScreen(
        folder: resolvedFolder,
        scrollToCardId: card.id,
      ),
    ));
    return true;
  } catch (e) {
    debugPrint('[MAIN] _doNavigate 오류 (DB 연결 등): $e');
    return false; // DB가 아직 안 열렸을 수 있다 — 네이티브가 몇 번 더 부른다.
  }
}

/// 잠금화면 좌측 슬라이드 → 해당 카드 편집 화면 이동.
/// CardListScreen에 autoEditCardId를 전달해 _editCard() 경로로 편집 → pop 시 refresh 보장.
/// 반환값 규약은 [_handleNotificationNav]와 같다(false=재시도 요청, 감사 D4-11).
Future<bool> _handleEditCardNav(int folderId, int cardId) async {
  debugPrint('[MAIN] _handleEditCardNav: folder=$folderId card=$cardId');
  final nav = navigatorKey.currentState;
  if (nav == null) {
    await Future.delayed(const Duration(milliseconds: 500));
    final retryNav = navigatorKey.currentState;
    if (retryNav == null) {
      debugPrint('[MAIN] navigatorKey still null, giving up edit nav');
      return false;
    }
    return _doEditNavigate(retryNav, folderId, cardId);
  }
  return _doEditNavigate(nav, folderId, cardId);
}

Future<bool> _doEditNavigate(
    NavigatorState nav, int folderId, int cardId) async {
  try {
    final results = await Future.wait([
      DatabaseHelper.instance.getCardById(cardId),
      DatabaseHelper.instance.getFolderById(folderId),
    ]);
    final card = results[0] as CardModel?;
    var folder = results[1] as Folder?;
    if (card == null) {
      debugPrint('[MAIN] edit card not found for id=$cardId');
      return true;
    }
    if (card.folderId != folderId) {
      folder = await DatabaseHelper.instance.getFolderById(card.folderId);
    }
    final resolvedFolder = folder;
    if (resolvedFolder == null) {
      debugPrint('[MAIN] edit folder not found');
      return true;
    }
    // 이미 편집 화면이 열려 있으면 popUntil이 PopScope의 미저장-변경 가드를
    // 우회해 편집 중인 내용을 조용히 날려버린다 — 이 경우 편집 네비게이션을 건너뛴다.
    if (CardEditScreen.isOpen) {
      debugPrint('[MAIN] CardEditScreen open, skipping edit navigation');
      _notifyNavSkippedByEditor();
      return true; // 의도적 건너뜀
    }
    nav.popUntil((route) => route.isFirst);
    nav.push(MaterialPageRoute(
      builder: (_) => CardListScreen(
        folder: resolvedFolder,
        scrollToCardId: card.id,
        autoEditCardId: card.id,
      ),
    ));
    nav.push(MaterialPageRoute(
      builder: (_) => CardEditScreen(
        folderId: card.folderId,
        existingCard: card,
      ),
    ));
    return true;
  } catch (e) {
    debugPrint('[MAIN] _doEditNavigate 오류: $e');
    return false;
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
    // Import/Export 완료 알림 탭(콜드스타트) — MainActivity가 같은 pending 경로로 넘긴다.
    case 'import':
      _handleImportNotificationTap();
      return;
    case 'export':
      _handleExportNotificationTap();
      return;
    default:
      return;
  }

  // 편집 화면이 열려 있으면 popUntil이 PopScope의 미저장-변경 가드를 우회해
  // 편집 중인 내용을 조용히 날려버린다 — 편집 중엔 설정 네비게이션을 건너뛴다.
  if (CardEditScreen.isOpen) {
    debugPrint('[MAIN] CardEditScreen open, skipping settings navigation');
    _notifyNavSkippedByEditor();
    return;
  }

  nav.popUntil((route) => route.isFirst);
  nav.push(MaterialPageRoute(builder: (_) => screen));
}

/// 잠금화면 설정(기본 폴더 + 시간대 슬롯)이 가리키는 폴더 중 DB에 더는 없는 것을 정리한다.
/// 폴더 삭제 경로의 정리가 실패했거나 그 전에 프로세스가 죽었어도 다음 실행에서 회복된다.
Future<void> _reconcileLockScreenFoldersOnce() async {
  try {
    final settings = await LockScreenService.getSettings();
    final referenced = <int>{};
    final rawIds = settings['folderIds'];
    if (rawIds is List) {
      for (final v in rawIds) {
        final id = v is int ? v : int.tryParse(v.toString());
        if (id != null) referenced.add(id);
      }
    }
    for (final slot
        in LockScreenSchedule.decode(settings['scheduleCsv'] as String?)) {
      referenced.add(slot.folderId);
    }
    if (referenced.isEmpty) return;

    final folders = await DatabaseHelper.instance.getAllFolders();
    final alive = folders.map((f) => f.id).whereType<int>().toSet();
    final stale = referenced.difference(alive).toList();
    if (stale.isEmpty) return;

    debugPrint('[STARTUP] 잠금화면이 없는 폴더 참조 중: $stale → 정리');
    await LockScreenService.removeFoldersFromSettingsBatch(stale);
  } catch (e) {
    debugPrint('[STARTUP] 잠금화면 폴더 대조 실패: $e');
  }
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
    final rawSort = settings['sortOrder'];
    final sortOrder = rawSort is String && rawSort.isNotEmpty
        ? rawSort
        : ((settings['randomOrder'] as bool? ?? false) ? 'random' : 'sequence');
    await LockScreenService.startService(
      enabled: true,
      folderIds: folderIds,
      finishedFilter: settings['finishedFilter'] as int? ?? -1,
      sortOrder: sortOrder,
      reversed: settings['reversed'] as bool? ?? false,
      bgColor: settings['bgColor'] as int? ?? 0xFF1A1A2E,
    );
  } catch (e) {
    debugPrint('Failed to restore lock screen service: $e');
  }
}
