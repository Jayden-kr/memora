import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

import '../database/database_helper.dart';
import 'locale_service.dart';
import 'push_schedule.dart';
import 'push_schedule_migration.dart';

class NotificationNavEvent {
  final int folderId;
  final int cardId;
  NotificationNavEvent(this.folderId, this.cardId);
}

class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static final _pushNotifChannel =
      const MethodChannel('com.henry.memora/push_notif');

  /// 알림 탭 → 네비게이션 콜백 (main.dart에서 등록)
  static Future<void> Function(NotificationNavEvent)? onNavigate;

  /// Cold-start 시 보류 이벤트
  static NotificationNavEvent? _pendingEvent;
  static NotificationNavEvent? consumePendingEvent() {
    final e = _pendingEvent;
    _pendingEvent = null;
    return e;
  }

  static Future<void> initialize() async {
    try {
      const androidSettings =
          AndroidInitializationSettings('@drawable/ic_notification');
      const settings = InitializationSettings(android: androidSettings);
      await _plugin.initialize(
        settings,
        onDidReceiveNotificationResponse: _onNotificationTap,
      );

      // Cold-start: 앱이 알림 탭으로 실행된 경우
      try {
        final launchDetails = await _plugin.getNotificationAppLaunchDetails();
        if (launchDetails != null &&
            launchDetails.didNotificationLaunchApp &&
            launchDetails.notificationResponse != null) {
          final payload = launchDetails.notificationResponse!.payload;
          if (payload != null && payload.contains(':')) {
            final event = _parsePayload(payload);
            if (event != null) {
              _pendingEvent = event;
            }
          }
        }
      } catch (e) {
        debugPrint('[NOTIF] launchDetails 처리 실패: $e');
      }
    } catch (e) {
      debugPrint('[NOTIF] initialize 실패: $e');
    }
  }

  // ─── 권한 ───

  static bool _requestingPermission = false;

  static Future<bool> requestPermission() async {
    if (_requestingPermission) return false;
    _requestingPermission = true;
    try {
      final status = await Permission.notification.status;
      if (status.isGranted) return true;
      final result = await Permission.notification.request();
      return result.isGranted;
    } catch (e) {
      debugPrint('[NOTIF] requestPermission 실패: $e');
      return false;
    } finally {
      _requestingPermission = false;
    }
  }

  /// SCHEDULE_EXACT_ALARM이 실제로 허용되어 있는지 확인 (API 31+에서만 의미 있음,
  /// API 31 미만은 네이티브 쪽에서 항상 true 반환)
  static Future<bool> canScheduleExactAlarms() async {
    try {
      final result =
          await _pushNotifChannel.invokeMethod<bool>('canScheduleExactAlarms');
      return result ?? false;
    } catch (e) {
      debugPrint('[NOTIF] canScheduleExactAlarms 실패: $e');
      return false;
    }
  }

  /// '알람 및 리마인더' 정확한 알림 설정 화면 열기 (API 31+)
  static Future<void> openExactAlarmSettings() async {
    try {
      await _pushNotifChannel.invokeMethod('openExactAlarmSettings');
    } catch (e) {
      debugPrint('[NOTIF] openExactAlarmSettings 실패: $e');
    }
  }

  // ─── 알림 탭 처리 ───

  static void _onNotificationTap(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || !payload.contains(':')) return;
    final event = _parsePayload(payload);
    if (event == null) return;
    if (onNavigate != null) {
      // onNavigate 등록됨 → 즉시 전달, pending 설정 안 함 (double navigation 방지)
      onNavigate!(event).catchError((e) {
        debugPrint('[NOTIF] onNavigate 실패: $e — pending으로 저장');
        _pendingEvent = event;
      });
    } else {
      // onNavigate 미등록 → pending에 저장 (cold-start 등)
      _pendingEvent = event;
    }
  }

  static NotificationNavEvent? _parsePayload(String payload) {
    final parts = payload.split(':');
    if (parts.length != 2) {
      debugPrint('[NOTIF] 잘못된 payload 형식: $payload');
      return null;
    }
    final folderId = int.tryParse(parts[0]);
    final cardId = int.tryParse(parts[1]);
    if (folderId == null || cardId == null) {
      debugPrint('[NOTIF] payload 파싱 실패: $payload');
      return null;
    }
    return NotificationNavEvent(folderId, cardId);
  }

  /// 즉시 테스트 알림 전송. 지금 이 순간의 활성 규칙(없으면 목록의 첫 규칙, 그마저도
  /// 없으면 전체 폴더)의 폴더에서 카드를 뽑는다 — gap 시간대에 테스트를 눌러도
  /// "규칙이 하나라도 있으면 그중 대표를 쓴다"는 정의된 동작을 갖는다(무동작이 아님).
  static Future<void> showTestNotification() async {
    final isEn = LocaleService.currentLanguageCode() == 'en';
    String body = isEn ? 'Time to review your cards!' : '카드를 복습할 시간입니다!';
    String? payload;

    try {
      final settings = await DatabaseHelper.instance.getAllSettings();
      final rules = PushSchedule.decode(settings[PushSchedule.settingRulesKey]);
      final now = DateTime.now();
      final nowMinutes = now.hour * 60 + now.minute;
      final rule = PushSchedule.activeRule(nowMinutes, rules) ??
          (rules.isEmpty ? null : rules.first);
      final folderId =
          (rule == null || rule.folderId == PushSchedule.allFolders)
              ? null
              : rule.folderId;
      final card =
          await DatabaseHelper.instance.getRandomCard(folderId: folderId);
      if (card != null) {
        // 빈 질문이면 기본 복습 문구 유지(예약 푸시 PushNotificationService와 동일 폴백,
        // '(내용 없음)' 플레이스홀더는 제거). 빈 알림 방지 + 테스트=실제 일치.
        if (card.question.isNotEmpty) body = card.question;
        payload = '${card.folderId}:${card.id}';
      }
    } catch (e) {
      debugPrint('[NOTIF] showTestNotification DB error: $e');
    }

    final notificationDetails = NotificationDetails(
      android: AndroidNotificationDetails(
        'review_notification_channel',
        isEn ? 'Review notification' : '복습 알림',
        channelDescription: isEn
            ? 'Random card notification at scheduled time'
            : '설정한 시간에 랜덤 카드 알림',
        importance: Importance.high,
        priority: Priority.high,
        icon: '@drawable/ic_notification',
        autoCancel: true,
      ),
    );

    try {
      await _plugin.show(99999, null, body, notificationDetails,
          payload: payload);
    } catch (e) {
      debugPrint('[NOTIF] 테스트 알림 표시 실패: $e');
    }
  }

  // ─── 스케줄링 (단일 진입점) ───

  static bool _rescheduling = false;
  static bool _pendingReschedule = false;

  /// DB 기준으로 모든 알림을 재스케줄링 (유일한 스케줄링 진입점)
  /// 동시 호출 시 현재 작업 완료 후 1회 재실행
  static Future<void> rescheduleAll() async {
    if (_rescheduling) {
      _pendingReschedule = true;
      return;
    }
    _rescheduling = true;
    try {
      await _rescheduleAllImpl();
    } catch (e) {
      debugPrint('[NOTIF] rescheduleAll 실패: $e');
    } finally {
      _rescheduling = false;
      // 대기 중인 재스케줄 요청이 있으면 1회 더 실행
      if (_pendingReschedule) {
        _pendingReschedule = false;
        await rescheduleAll();
      }
    }
  }

  static Future<void> _rescheduleAllImpl() async {
    // NOTE: _plugin.cancelAll()은 NotificationManager.cancelAll()을 호출하여
    // 네이티브 PushNotificationService 카드 알림(50000+)까지 전부 삭제함.
    // 이 앱은 flutter_local_notifications 스케줄링을 사용하지 않으므로 cancelAll() 불필요.

    Map<String, String> settings;
    try {
      settings = await DatabaseHelper.instance.getAllSettings();
    } catch (e) {
      debugPrint('[NOTIF] rescheduleAll: getAllSettings 실패: $e');
      return;
    }

    // v1.3.8 이하 저장값(push_alarms 전역 인터벌 알람 + push_schedule 오버라이드
    // 슬롯)을 push_rules 규칙 목록으로 1회 변환. 마이그레이션은 저장만 하고
    // 돌아온다(rescheduleAll을 다시 부르지 않음 — 무한재귀 방지).
    try {
      await PushScheduleMigration.migrateIfNeeded(settings);
    } catch (e) {
      debugPrint('[NOTIF] rescheduleAll: migrateIfNeeded 실패: $e');
    }

    // 마이그레이션이 push_rules/push_sound_enabled/push_rules_migrated를 새로
    // 썼을 수 있으므로 재조회.
    try {
      settings = await DatabaseHelper.instance.getAllSettings();
    } catch (e) {
      debugPrint('[NOTIF] rescheduleAll: getAllSettings(재조회) 실패: $e');
      return;
    }

    final rules = PushSchedule.decode(settings[PushSchedule.settingRulesKey]);

    var enabledStr = (settings['notification_enabled'] ?? '').toLowerCase();

    // 마이그레이션 이전 버전에서 업데이트된 사용자를 위한 자동 활성화 — 규칙이
    // 존재하는데 notification_enabled가 미설정인 경우.
    if (enabledStr.isEmpty && rules.isNotEmpty) {
      debugPrint('[NOTIF] 마이그레이션: 규칙 존재하나 설정 미지정 → 자동 활성화');
      try {
        await DatabaseHelper.instance
            .upsertSetting('notification_enabled', 'true');
        enabledStr = 'true';
      } catch (e) {
        debugPrint('[NOTIF] 자동 활성화 실패: $e');
      }
    }

    if (enabledStr != 'true' || rules.isEmpty) {
      debugPrint(
          '[NOTIF] rescheduleAll: 비활성화 또는 규칙 없음 (enabled=$enabledStr, rules=${rules.length})');
      // 비활성화 시(또는 규칙이 하나도 없을 때) 서비스 중지 — 자가 치유.
      try { await stopIntervalService(); } catch (_) {}
      return;
    }

    final soundEnabledStr = settings[PushSchedule.settingSoundKey];
    final soundEnabled = (soundEnabledStr ?? 'true').toLowerCase() != 'false';

    await _startPushService(
      rulesCsv: PushSchedule.encode(rules),
      soundEnabled: soundEnabled,
    );
  }

  // ─── Foreground Service 제어 ───

  static Future<void> _startPushService({
    required String rulesCsv,
    required bool soundEnabled,
  }) async {
    try {
      await _pushNotifChannel.invokeMethod('startService', {
        'rulesCsv': rulesCsv,
        'soundEnabled': soundEnabled,
        'lang': LocaleService.currentLanguageCode(),
      });
      debugPrint('[NOTIF] 서비스 시작: rules=$rulesCsv');
    } catch (e) {
      debugPrint('[NOTIF] 서비스 시작 실패: $e');
    }
  }

  static Future<void> stopIntervalService() async {
    try {
      // isRunning 게이트 제거: 'running' 플래그는 :push 별도 프로세스가 기록하고 여기(메인
      // 프로세스)는 SharedPreferences의 프로세스별 캐시 때문에 stale false를 볼 수 있어,
      // 서비스가 실제로 켜져 있어도 stop을 건너뛰어 OFF 후에도 알림이 지속됐다(#3).
      // stop은 미실행 서비스에도 무해하다: 네이티브 ACTION_STOP 핸들러가 startForeground로
      // 콜드스타트 안전성을 확보한 뒤 즉시 정리한다. 따라서 무조건 stop을 보낸다.
      await _pushNotifChannel.invokeMethod('stopService');
      debugPrint('[NOTIF] 서비스 중지 요청 전송');
    } catch (e) {
      debugPrint('[NOTIF] 서비스 중지 실패: $e');
    }
  }

  static Future<void> cancelAllNotifications() async {
    // 서비스 중지만 수행. _plugin.cancelAll()은 네이티브 push 알림까지 삭제하므로 사용하지 않음.
    try {
      await stopIntervalService();
    } catch (e) {
      debugPrint('[NOTIF] cancelAllNotifications 오류: $e');
    }
  }

  /// 삭제된 폴더 ID 목록을 푸시 알림 규칙(push_rules) 목록에서 제거.
  ///
  /// home_screen의 폴더 삭제 사후 정리에서 `needsPushReschedule` 플래그와 무관하게
  /// 항상 호출돼야 한다 — 그 플래그는 push_alarms.folder_id(옛 전역 기본 폴더)만
  /// 추적해서, 규칙 하나가 가리키던 폴더만 지운 경우를 놓친다.
  static Future<void> removeFoldersFromPushSchedule(
      List<int> folderIdsToRemove) async {
    if (folderIdsToRemove.isEmpty) return;
    try {
      final settings = await DatabaseHelper.instance.getAllSettings();
      final rules = PushSchedule.decode(settings[PushSchedule.settingRulesKey]);
      if (rules.isEmpty) return;

      final removeSet = folderIdsToRemove.toSet();
      // folderId == allFolders(-1)은 실제 폴더 id가 아니므로 removeSet에 절대
      // 포함되지 않는다 — "전체 폴더" 규칙은 이 pruning으로 지워지지 않는다.
      final prunedRules =
          rules.where((r) => !removeSet.contains(r.folderId)).toList();
      if (prunedRules.length == rules.length) {
        return; // 변경 없음 — 이 삭제와 무관
      }

      await DatabaseHelper.instance.upsertSetting(
          PushSchedule.settingRulesKey, PushSchedule.encode(prunedRules));

      // 규칙이 있었는데 이번 pruning으로 전부 사라진 경우에만 마스터 스위치를 끈다
      // — 규칙 0개인데 스위치 ON인 상태는 불변식 위반이기 때문. 그 외(규칙이 하나라도
      // 남는 경우)엔 사용자가 설정한 enabled 값을 그대로 둔다.
      if (prunedRules.isEmpty) {
        await DatabaseHelper.instance
            .upsertSetting('notification_enabled', 'false');
      }

      await rescheduleAll();
    } catch (e) {
      debugPrint('[NOTIF] removeFoldersFromPushSchedule 실패: $e');
    }
  }
}
