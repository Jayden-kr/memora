import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

import '../database/database_helper.dart';

class NotificationNavEvent {
  final int folderId;
  final int cardId;
  NotificationNavEvent(this.folderId, this.cardId);
}

class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static final _pushNotifChannel =
      const MethodChannel('com.henry.amki_wang/push_notif');

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

  /// 즉시 테스트 알림 전송
  static Future<void> showTestNotification() async {
    String body = '카드를 복습할 시간입니다!';
    String? payload;

    try {
      final alarms = await DatabaseHelper.instance.getAllPushAlarms();
      int? folderId;
      if (alarms.isNotEmpty) {
        folderId = alarms.first['folder_id'] as int?;
      }
      final card =
          await DatabaseHelper.instance.getRandomCard(folderId: folderId);
      if (card != null) {
        body = card.question.isNotEmpty ? card.question : '(내용 없음)';
        payload = '${card.folderId}:${card.id}';
      }
    } catch (e) {
      debugPrint('[NOTIF] showTestNotification DB 오류: $e');
    }

    const notificationDetails = NotificationDetails(
      android: AndroidNotificationDetails(
        'review_notification_channel',
        '복습 알림',
        channelDescription: '설정한 시간에 랜덤 카드 알림',
        importance: Importance.high,
        priority: Priority.high,
        icon: '@drawable/ic_notification',
      ),
    );

    try {
      await _plugin.show(99999, 'Memora', body, notificationDetails,
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
    // flutter_local_notifications 정리 (실패해도 계속 진행)
    try { await _plugin.cancelAll(); } catch (_) {}

    // 알람 먼저 조회 (설정 마이그레이션에 필요)
    List<Map<String, dynamic>> alarms;
    try {
      alarms = await DatabaseHelper.instance.getAllPushAlarms();
    } catch (e) {
      debugPrint('[NOTIF] rescheduleAll: getAllPushAlarms 실패: $e');
      return;
    }

    if (alarms.isEmpty) {
      debugPrint('[NOTIF] rescheduleAll: 설정된 알람 없음');
      return;
    }

    // 알림 활성화 여부 확인
    Map<String, String> settings;
    try {
      settings = await DatabaseHelper.instance.getAllSettings();
    } catch (e) {
      debugPrint('[NOTIF] rescheduleAll: getAllSettings 실패: $e');
      return;
    }

    var enabledStr =
        (settings['notification_enabled'] ?? '').toLowerCase();

    // 마이그레이션: 알람이 존재하지만 notification_enabled가 미설정인 경우
    // (이전 버전에서 업데이트된 사용자) → 자동으로 'true' 설정
    if (enabledStr.isEmpty && alarms.isNotEmpty) {
      debugPrint('[NOTIF] 마이그레이션: 알람 존재하나 설정 미지정 → 자동 활성화');
      try {
        await DatabaseHelper.instance
            .upsertSetting('notification_enabled', 'true');
        enabledStr = 'true';
      } catch (e) {
        debugPrint('[NOTIF] 마이그레이션 실패: $e');
      }
    }

    if (enabledStr != 'true') {
      debugPrint('[NOTIF] rescheduleAll: 알림 비활성화 (enabled=$enabledStr)');
      // 비활성화 시에만 서비스 중지
      try { await stopIntervalService(); } catch (_) {}
      return;
    }

    // 활성화 + 알람 있음 → interval 알람 찾아서 서비스 (재)시작
    // NOTE: onStartCommand가 내부에서 handler.removeCallbacks 후 재스케줄하므로
    //       별도 stopService 없이 바로 startService하면 됨 (STOP 인텐트 레이스 방지)
    bool hasInterval = false;
    debugPrint('[NOTIF] rescheduleAll: ${alarms.length}개 알람 처리');

    for (final alarm in alarms) {
      if ((alarm['enabled'] as int? ?? 1) != 1) continue;

      final mode = alarm['mode'] as String? ?? 'fixed';
      final folderId = alarm['folder_id'] as int?;
      final soundEnabled = (alarm['sound_enabled'] as int? ?? 1) == 1;

      if (mode == 'interval') {
        final startTime = alarm['start_time'] as String?;
        final endTime = alarm['end_time'] as String?;
        final intervalMin = alarm['interval_min'] as int?;

        // 필수 필드 검증
        if (startTime == null || endTime == null || intervalMin == null) {
          debugPrint('[NOTIF] 잘못된 interval 알람 (id=${alarm['id']}): '
              'start=$startTime, end=$endTime, interval=$intervalMin');
          continue;
        }
        if (intervalMin < 5 || intervalMin > 1440) {
          debugPrint('[NOTIF] interval 범위 밖 (id=${alarm['id']}): $intervalMin분');
          continue;
        }

        // 시간 파싱 (엄격한 HH:MM 형식)
        final sp = startTime.split(':');
        final ep = endTime.split(':');
        if (sp.length != 2 || ep.length != 2) {
          debugPrint('[NOTIF] 시간 형식 오류 (id=${alarm['id']}): $startTime ~ $endTime');
          continue;
        }

        final startHour = int.tryParse(sp[0]);
        final startMinute = int.tryParse(sp[1]);
        final endHour = int.tryParse(ep[0]);
        final endMinute = int.tryParse(ep[1]);
        if (startHour == null || startMinute == null ||
            endHour == null || endMinute == null) {
          debugPrint('[NOTIF] 시간 파싱 실패 (id=${alarm['id']}): $startTime ~ $endTime');
          continue;
        }

        // 범위 검증
        if (startHour < 0 || startHour > 23 || startMinute < 0 || startMinute > 59 ||
            endHour < 0 || endHour > 23 || endMinute < 0 || endMinute > 59) {
          debugPrint('[NOTIF] 시간 범위 초과 (id=${alarm['id']}): $startTime ~ $endTime');
          continue;
        }

        hasInterval = true;
        await _startIntervalService(
          startHour: startHour,
          startMinute: startMinute,
          endHour: endHour,
          endMinute: endMinute,
          intervalMin: intervalMin,
          folderId: folderId,
          soundEnabled: soundEnabled,
        );
      }
    }

    // interval 알람이 하나도 시작되지 않았으면 기존 서비스 정리
    if (!hasInterval) {
      try { await stopIntervalService(); } catch (_) {}
    }
  }

  // ─── Foreground Service 제어 ───

  static Future<void> _startIntervalService({
    required int startHour,
    required int startMinute,
    required int endHour,
    required int endMinute,
    required int intervalMin,
    int? folderId,
    bool soundEnabled = true,
  }) async {
    final startTotal = startHour * 60 + startMinute;
    final endTotal = endHour * 60 + endMinute;
    if (endTotal <= startTotal || intervalMin < 5) {
      debugPrint('[NOTIF] 서비스 시작 건너뜀: '
          'start=$startTotal, end=$endTotal, interval=$intervalMin');
      return;
    }

    try {
      await _pushNotifChannel.invokeMethod('startService', {
        'intervalMin': intervalMin,
        'startTotal': startTotal,
        'endTotal': endTotal,
        'folderId': folderId ?? -1,
        'soundEnabled': soundEnabled,
      });
      debugPrint('[NOTIF] 서비스 시작: '
          '${startHour.toString().padLeft(2, "0")}:${startMinute.toString().padLeft(2, "0")}'
          '~${endHour.toString().padLeft(2, "0")}:${endMinute.toString().padLeft(2, "0")}'
          ', $intervalMin분');
    } catch (e) {
      debugPrint('[NOTIF] 서비스 시작 실패: $e');
    }
  }

  static Future<void> stopIntervalService() async {
    try {
      final running =
          await _pushNotifChannel.invokeMethod<bool>('isRunning') ?? false;
      if (running) {
        await _pushNotifChannel.invokeMethod('stopService');
        debugPrint('[NOTIF] 서비스 중지 완료');
      }
    } catch (e) {
      debugPrint('[NOTIF] 서비스 중지 실패: $e');
    }
  }

  static Future<void> cancelAllNotifications() async {
    final errors = <String>[];
    try { await stopIntervalService(); } catch (e) { errors.add('stopService: $e'); }
    try { await _plugin.cancelAll(); } catch (e) { errors.add('cancelAll: $e'); }
    if (errors.isNotEmpty) {
      debugPrint('[NOTIF] cancelAllNotifications 오류: $errors');
    }
  }
}
