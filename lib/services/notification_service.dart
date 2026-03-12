import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../database/database_helper.dart';

class NotificationNavEvent {
  final int folderId;
  final int cardId;
  NotificationNavEvent(this.folderId, this.cardId);
}

class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();

  /// 알림 탭 → 직접 네비게이션 콜백 (main.dart에서 등록)
  static Future<void> Function(NotificationNavEvent)? onNavigate;

  /// Cold-start 시 보류 이벤트
  static NotificationNavEvent? _pendingEvent;
  static NotificationNavEvent? consumePendingEvent() {
    final e = _pendingEvent;
    _pendingEvent = null;
    return e;
  }

  static Future<void> initialize() async {
    tz.initializeTimeZones();
    _setLocalTimezone();

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

  static void _setLocalTimezone() {
    final offset = DateTime.now().timeZoneOffset.inMilliseconds;
    for (final entry in tz.timeZoneDatabase.locations.entries) {
      if (entry.value.currentTimeZone.offset == offset) {
        tz.setLocalLocation(entry.value);
        return;
      }
    }
  }

  static void _onNotificationTap(NotificationResponse response) {
    debugPrint('[NOTIF] _onNotificationTap payload=${response.payload}');
    final payload = response.payload;
    if (payload == null || !payload.contains(':')) return;
    final event = _parsePayload(payload);
    if (event != null) {
      debugPrint('[NOTIF] nav event folder=${event.folderId} card=${event.cardId}');
      if (onNavigate != null) {
        debugPrint('[NOTIF] calling onNavigate callback');
        onNavigate!(event);
      } else {
        debugPrint('[NOTIF] onNavigate null, saving as pending');
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

  /// 즉시 테스트 알림 전송 (푸시알림 설정의 폴더 반영)
  static Future<void> showTestNotification() async {
    String? title;
    String body = '카드를 복습할 시간입니다!';
    String? payload;

    try {
      // 푸시알림 설정에서 폴더 가져오기
      final alarms = await DatabaseHelper.instance.getAllPushAlarms();
      int? folderId;
      if (alarms.isNotEmpty) {
        folderId = alarms.first['folder_id'] as int?;
      }

      final List cards;
      if (folderId != null) {
        cards = await DatabaseHelper.instance.getCardsByFolderId(folderId,
            limit: 100);
      } else {
        cards = await DatabaseHelper.instance.getAllCards(limit: 100);
      }

      if (cards.isNotEmpty) {
        final card = cards[Random().nextInt(cards.length)];
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
      ),
    );

    await _plugin.show(99999, title, body, notificationDetails,
        payload: payload);
  }

  /// 앱 시작 시 저장된 알람을 다시 스케줄링 (카드 내용 갱신)
  static Future<void> rescheduleAll() async {
    await cancelAllNotifications();

    final settings = await DatabaseHelper.instance.getAllSettings();
    final enabledStr = settings['notification_enabled'];
    if (enabledStr == 'false') return;

    final alarms = await DatabaseHelper.instance.getAllPushAlarms();
    for (final alarm in alarms) {
      if ((alarm['enabled'] as int? ?? 1) != 1) continue;

      final id = alarm['id'] as int;
      final daysStr = alarm['days'] as String?;
      Set<int>? days;
      if (daysStr != null && daysStr.isNotEmpty) {
        days = daysStr
            .split(',')
            .map((d) => int.tryParse(d.trim()))
            .whereType<int>()
            .toSet();
      }
      final folderId = alarm['folder_id'] as int?;
      final soundEnabled = (alarm['sound_enabled'] as int? ?? 1) == 1;
      final mode = alarm['mode'] as String? ?? 'fixed';

      if (mode == 'interval') {
        final startTime = alarm['start_time'] as String?;
        final endTime = alarm['end_time'] as String?;
        final intervalMin = alarm['interval_min'] as int?;
        if (startTime == null || endTime == null || intervalMin == null) continue;

        final sp = startTime.split(':');
        final ep = endTime.split(':');
        await scheduleIntervalNotifications(
          id: id,
          startHour: int.parse(sp[0]),
          startMinute: int.parse(sp[1]),
          endHour: int.parse(ep[0]),
          endMinute: int.parse(ep[1]),
          intervalMin: intervalMin,
          days: days,
          folderId: folderId,
          soundEnabled: soundEnabled,
        );
      } else {
        final timeStr = alarm['time'] as String;
        final parts = timeStr.split(':');
        await scheduleDailyNotification(
          id: id,
          hour: int.parse(parts[0]),
          minute: int.parse(parts[1]),
          days: days,
          folderId: folderId,
          soundEnabled: soundEnabled,
        );
      }
    }
  }

  static Future<void> scheduleDailyNotification({
    required int id,
    required int hour,
    required int minute,
    Set<int>? days,
    int? folderId,
    bool soundEnabled = true,
  }) async {
    String? title;
    String body = '카드를 복습할 시간입니다!';
    String? payload;

    try {
      final List cards;
      if (folderId != null) {
        cards = await DatabaseHelper.instance.getCardsByFolderId(folderId,
            limit: 100);
      } else {
        cards = await DatabaseHelper.instance.getAllCards(limit: 100);
      }
      if (cards.isNotEmpty) {
        final card = cards[Random().nextInt(cards.length)];
        body = card.question.isNotEmpty ? card.question : '(내용 없음)';
        payload = '${card.folderId}:${card.id}';
      }
    } catch (_) {}

    final notificationDetails = NotificationDetails(
      android: AndroidNotificationDetails(
        'review_notification_channel',
        '복습 알림',
        channelDescription: '설정한 시간에 랜덤 카드 알림',
        importance: Importance.high,
        priority: Priority.high,
        playSound: soundEnabled,
        enableVibration: true,
      ),
    );

    if (days == null || days.isEmpty || days.length == 7) {
      final now = tz.TZDateTime.now(tz.local);
      var scheduled = tz.TZDateTime(
        tz.local,
        now.year,
        now.month,
        now.day,
        hour,
        minute,
      );
      if (scheduled.isBefore(now)) {
        scheduled = scheduled.add(const Duration(days: 1));
      }

      await _plugin.zonedSchedule(
        id,
        title,
        body,
        scheduled,
        notificationDetails,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
        payload: payload,
      );
    } else {
      for (final day in days) {
        final dartWeekday = day == 0 ? DateTime.sunday : day;

        final now = tz.TZDateTime.now(tz.local);
        var scheduled = _nextInstanceOfWeekdayTime(
          dartWeekday,
          hour,
          minute,
          now,
        );

        final notifId = id * 10 + day;
        await _plugin.zonedSchedule(
          notifId,
          title,
          body,
          scheduled,
          notificationDetails,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
          payload: payload,
        );
      }
    }
  }

  static tz.TZDateTime _nextInstanceOfWeekdayTime(
    int weekday,
    int hour,
    int minute,
    tz.TZDateTime now,
  ) {
    var scheduled = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    );
    while (scheduled.weekday != weekday) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    if (scheduled.isBefore(now)) {
      scheduled = scheduled.add(const Duration(days: 7));
    }
    return scheduled;
  }

  /// 간격 반복 알림 스케줄링
  static Future<void> scheduleIntervalNotifications({
    required int id,
    required int startHour,
    required int startMinute,
    required int endHour,
    required int endMinute,
    required int intervalMin,
    Set<int>? days,
    int? folderId,
    bool soundEnabled = true,
  }) async {
    // 시간 슬롯 계산
    final startTotal = startHour * 60 + startMinute;
    final endTotal = endHour * 60 + endMinute;
    if (endTotal <= startTotal || intervalMin < 5) return;

    final List<({int hour, int minute})> slots = [];
    for (int m = startTotal; m <= endTotal; m += intervalMin) {
      slots.add((hour: m ~/ 60, minute: m % 60));
    }

    // 카드 풀 가져오기
    List cards = [];
    try {
      if (folderId != null) {
        cards = await DatabaseHelper.instance.getCardsByFolderId(folderId,
            limit: 200);
      } else {
        cards = await DatabaseHelper.instance.getAllCards(limit: 200);
      }
    } catch (_) {}

    final notificationDetails = NotificationDetails(
      android: AndroidNotificationDetails(
        'review_notification_channel',
        '복습 알림',
        channelDescription: '설정한 시간에 랜덤 카드 알림',
        importance: Importance.high,
        priority: Priority.high,
        playSound: soundEnabled,
        enableVibration: true,
      ),
    );

    final rng = Random();
    final now = tz.TZDateTime.now(tz.local);

    for (int i = 0; i < slots.length; i++) {
      final slot = slots[i];

      // 랜덤 카드 선택
      String? title;
      String body = '카드를 복습할 시간입니다!';
      String? payload;
      if (cards.isNotEmpty) {
        final card = cards[rng.nextInt(cards.length)];
        body = card.question.isNotEmpty ? card.question : '(내용 없음)';
        payload = '${card.folderId}:${card.id}';
      }

      if (days == null || days.isEmpty || days.length == 7) {
        // 매일 반복
        var scheduled = tz.TZDateTime(
          tz.local, now.year, now.month, now.day, slot.hour, slot.minute,
        );
        if (scheduled.isBefore(now)) {
          scheduled = scheduled.add(const Duration(days: 1));
        }

        final notifId = id * 10000 + i;
        await _plugin.zonedSchedule(
          notifId, title, body, scheduled, notificationDetails,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          matchDateTimeComponents: DateTimeComponents.time,
          payload: payload,
        );
      } else {
        // 특정 요일만
        for (final day in days) {
          final dartWeekday = day == 0 ? DateTime.sunday : day;
          final scheduled = _nextInstanceOfWeekdayTime(
            dartWeekday, slot.hour, slot.minute, now,
          );

          final notifId = id * 10000 + i * 10 + day;
          await _plugin.zonedSchedule(
            notifId, title, body, scheduled, notificationDetails,
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
            matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
            payload: payload,
          );
        }
      }
    }
  }

  static Future<void> cancelAlarm(int id, {Set<int>? days}) async {
    if (days != null && days.isNotEmpty && days.length < 7) {
      for (final day in days) {
        await _plugin.cancel(id * 10 + day);
      }
    } else {
      await _plugin.cancel(id);
    }
  }

  static Future<void> cancelNotification(int id) async {
    await _plugin.cancel(id);
    for (int day = 0; day <= 6; day++) {
      await _plugin.cancel(id * 10 + day);
    }
    // 간격 모드 알림 취소 (최대 300 슬롯)
    for (int slot = 0; slot < 300; slot++) {
      await _plugin.cancel(id * 10000 + slot);
      for (int day = 0; day <= 6; day++) {
        await _plugin.cancel(id * 10000 + slot * 10 + day);
      }
    }
  }

  static Future<void> cancelAllNotifications() async {
    await _plugin.cancelAll();
  }
}
