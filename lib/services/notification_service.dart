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
    const androidSettings =
        AndroidInitializationSettings('@drawable/ic_notification');
    const settings = InitializationSettings(android: androidSettings);
    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: _onNotificationTap,
    );

    // Cold-start: 앱이 알림 탭으로 실행된 경우
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
  }

  static Future<bool> requestPermission() async {
    final status = await Permission.notification.status;
    if (status.isGranted) return true;
    final result = await Permission.notification.request();
    return result.isGranted;
  }

  static void _onNotificationTap(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || !payload.contains(':')) return;
    final event = _parsePayload(payload);
    if (event != null) {
      if (onNavigate != null) {
        onNavigate!(event);
      } else {
        _pendingEvent = event;
      }
    }
  }

  static NotificationNavEvent? _parsePayload(String payload) {
    final parts = payload.split(':');
    if (parts.length < 2) return null;
    final folderId = int.tryParse(parts[0]);
    final cardId = int.tryParse(parts[1]);
    if (folderId == null || cardId == null) return null;
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
    } catch (_) {}

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

    await _plugin.show(99999, 'Memora', body, notificationDetails,
        payload: payload);
  }

  // ─── 스케줄링 (단일 진입점) ───

  static bool _rescheduling = false;

  /// DB 기준으로 모든 알림을 재스케줄링 (유일한 스케줄링 진입점)
  static Future<void> rescheduleAll() async {
    if (_rescheduling) return;
    _rescheduling = true;
    try {
      await _rescheduleAllImpl();
    } finally {
      _rescheduling = false;
    }
  }

  static Future<void> _rescheduleAllImpl() async {
    // 기존 서비스/알림 정리 (실패해도 계속 진행)
    try { await stopIntervalService(); } catch (_) {}
    try { await _plugin.cancelAll(); } catch (_) {}

    // 알림 활성화 여부 확인
    final settings = await DatabaseHelper.instance.getAllSettings();
    final enabledStr = settings['notification_enabled'];
    if (enabledStr == 'false') return;

    final alarms = await DatabaseHelper.instance.getAllPushAlarms();
    debugPrint('[NOTIF] rescheduleAll: ${alarms.length} alarms, enabled=$enabledStr');

    for (final alarm in alarms) {
      if ((alarm['enabled'] as int? ?? 1) != 1) continue;

      final mode = alarm['mode'] as String? ?? 'fixed';
      final folderId = alarm['folder_id'] as int?;
      final soundEnabled = (alarm['sound_enabled'] as int? ?? 1) == 1;

      if (mode == 'interval') {
        final startTime = alarm['start_time'] as String?;
        final endTime = alarm['end_time'] as String?;
        final intervalMin = alarm['interval_min'] as int?;
        if (startTime == null || endTime == null || intervalMin == null) {
          continue;
        }
        final sp = startTime.split(':');
        final ep = endTime.split(':');
        if (sp.length < 2 || ep.length < 2) continue;
        await _startIntervalService(
          startHour: int.tryParse(sp[0]) ?? 0,
          startMinute: int.tryParse(sp[1]) ?? 0,
          endHour: int.tryParse(ep[0]) ?? 0,
          endMinute: int.tryParse(ep[1]) ?? 0,
          intervalMin: intervalMin,
          folderId: folderId,
          soundEnabled: soundEnabled,
        );
      }
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
    final startTotal = startHour.clamp(0, 23) * 60 + startMinute.clamp(0, 59);
    final endTotal = endHour.clamp(0, 23) * 60 + endMinute.clamp(0, 59);
    if (endTotal <= startTotal || intervalMin < 5) return;

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
      }
    } catch (e) {
      debugPrint('[NOTIF] 서비스 중지 실패: $e');
    }
  }

  static Future<void> cancelAllNotifications() async {
    try { await stopIntervalService(); } catch (_) {}
    try { await _plugin.cancelAll(); } catch (_) {}
  }
}
