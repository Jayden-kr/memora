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

  // 알림 ID 계산용 상수 (충돌 방지)
  // id는 _maxAlarmId로 모듈로 연산하여 Android 32비트 int 범위 내 유지
  // 최대 ID: 100000 + 9999 * 10000 + 99 * 10 + 7 ≈ 100M (32비트 int 2.1B 내)
  static const _maxAlarmId = 10000;           // 안전 상한: autoincrement 10000까지 충돌 없음
  static const _dayMultiplier = 10;           // 고정 알림: id * _dayMultiplier + day(0~6)
  static const _intervalBase = 100000;        // 간격 알림 기본 오프셋 (고정 알림 범위 0~99997과 충돌 방지)
  static const _intervalMultiplier = 10000;   // 간격 알림: _intervalBase + id * _intervalMultiplier + slot
  static const _intervalDayMultiplier = 10;   // 간격+요일: _intervalBase + id * _intervalMultiplier + slot * _intervalDayMultiplier + day

  /// alarm ID를 안전 범위로 정규화
  static int _safeId(int id) => id % _maxAlarmId;

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
    // 1차: 시스템 timezone 이름으로 정확한 IANA timezone 매칭
    final tzName = DateTime.now().timeZoneName;
    final locations = tz.timeZoneDatabase.locations;
    if (locations.containsKey(tzName)) {
      tz.setLocalLocation(locations[tzName]!);
      return;
    }

    // 2차: 잘 알려진 약어 → IANA 매핑 (한국/일본 등 주요 타임존)
    const abbreviationMap = {
      'KST': 'Asia/Seoul',
      'JST': 'Asia/Tokyo',
      'CST': 'Asia/Shanghai',
      'IST': 'Asia/Kolkata',
      'EST': 'America/New_York',
      'PST': 'America/Los_Angeles',
      'CET': 'Europe/Berlin',
      'GMT': 'Europe/London',
    };
    final mapped = abbreviationMap[tzName];
    if (mapped != null && locations.containsKey(mapped)) {
      tz.setLocalLocation(locations[mapped]!);
      return;
    }

    // 3차: UTC offset으로 매칭 (fallback)
    final offset = DateTime.now().timeZoneOffset.inMilliseconds;
    for (final entry in locations.entries) {
      if (entry.value.currentTimeZone.offset == offset) {
        tz.setLocalLocation(entry.value);
        return;
      }
    }

    // 모두 실패 시 UTC fallback
    debugPrint('[NOTIF] WARNING: timezone matching failed '
        '(name=$tzName, offset=${offset}ms), falling back to UTC. '
        'Notifications may fire at wrong times.');
    tz.setLocalLocation(tz.UTC);
  }

  static void _onNotificationTap(NotificationResponse response) {
    debugPrint('[NOTIF] _onNotificationTap payload=${response.payload}');
    final payload = response.payload;
    if (payload == null || !payload.contains(':')) return;
    final event = _parsePayload(payload);
    if (event != null) {
      debugPrint('[NOTIF] nav event folder=${event.folderId} card=${event.cardId}');
      // 알림 탭 시 다음 알림에 새로운 카드가 표시되도록 전체 재스케줄링
      rescheduleAll();
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
    String title = '';
    String body = '카드를 복습할 시간입니다!';
    String? payload;

    try {
      // 푸시알림 설정에서 폴더 가져오기
      final alarms = await DatabaseHelper.instance.getAllPushAlarms();
      int? folderId;
      if (alarms.isNotEmpty) {
        folderId = alarms.first['folder_id'] as int?;
      }

      // DB에서 랜덤 1개만 효율적으로 조회
      final card = await DatabaseHelper.instance.getRandomCard(folderId: folderId);

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

    await _plugin.show(99999, title, body, notificationDetails,
        payload: payload);
  }

  /// 앱 시작 시 저장된 알람을 다시 스케줄링 (카드 내용 갱신)
  static bool _rescheduling = false;

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
        if (sp.length < 2 || ep.length < 2) continue;
        await scheduleIntervalNotifications(
          id: id,
          startHour: int.tryParse(sp[0]) ?? 0,
          startMinute: int.tryParse(sp[1]) ?? 0,
          endHour: int.tryParse(ep[0]) ?? 0,
          endMinute: int.tryParse(ep[1]) ?? 0,
          intervalMin: intervalMin,
          days: days,
          folderId: folderId,
          soundEnabled: soundEnabled,
        );
      } else {
        final timeStr = alarm['time'] as String? ?? '08:00';
        final parts = timeStr.split(':');
        if (parts.length < 2) continue;
        await scheduleDailyNotification(
          id: id,
          hour: int.tryParse(parts[0]) ?? 0,
          minute: int.tryParse(parts[1]) ?? 0,
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
    final content = await _buildNotificationContent(folderId: folderId);

    final notificationDetails = NotificationDetails(
      android: AndroidNotificationDetails(
        'review_notification_channel',
        '복습 알림',
        channelDescription: '설정한 시간에 랜덤 카드 알림',
        importance: Importance.high,
        priority: Priority.high,
        icon: '@drawable/ic_notification',
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

      // all-days용 ID: safeId * _dayMultiplier + 7 (day 0~6과 충돌 방지)
      final notifId = _safeId(id) * _dayMultiplier + 7;
      await _plugin.zonedSchedule(
        notifId,
        content.title,
        content.body,
        scheduled,
        notificationDetails,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
        payload: content.payload,
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

        final notifId = _safeId(id) * _dayMultiplier + day;
        await _plugin.zonedSchedule(
          notifId,
          content.title,
          content.body,
          scheduled,
          notificationDetails,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
          payload: content.payload,
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
    // Dart DateTime.weekday: 1(월)~7(일). 범위 밖이면 무한 루프 방지
    if (weekday < DateTime.monday || weekday > DateTime.sunday) {
      return now;
    }
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

  /// 알림용 카드 정보 조회 (중복 코드 제거용 헬퍼)
  static Future<({String title, String body, String? payload})>
      _buildNotificationContent({int? folderId}) async {
    String title = '';
    String body = '카드를 복습할 시간입니다!';
    String? payload;
    try {
      final card = await DatabaseHelper.instance.getRandomCard(folderId: folderId);
      if (card != null) {
        body = card.question.isNotEmpty ? card.question : '(내용 없음)';
        payload = '${card.folderId}:${card.id}';
      }
    } catch (_) {}
    return (title: title, body: body, payload: payload);
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
    // 시간 슬롯 계산 (범위 보정)
    final safeStartHour = startHour.clamp(0, 23);
    final safeStartMinute = startMinute.clamp(0, 59);
    final safeEndHour = endHour.clamp(0, 23);
    final safeEndMinute = endMinute.clamp(0, 59);
    final startTotal = safeStartHour * 60 + safeStartMinute;
    final endTotal = safeEndHour * 60 + safeEndMinute;
    if (endTotal <= startTotal || intervalMin < 5) return;

    final List<({int hour, int minute})> slots = [];
    for (int m = startTotal; m <= endTotal; m += intervalMin) {
      slots.add((hour: m ~/ 60, minute: m % 60));
    }

    // Android exact alarm 제한(~500개) 초과 방지
    // 요일별 스케줄 시 슬롯 × 요일 수 만큼 알림이 생성되므로 총합 기준으로 제한
    final dayCount = (days == null || days.isEmpty || days.length == 7)
        ? 1
        : days.length;
    final maxSlots = 400 ~/ dayCount; // 총 알림 수 ≤ 400
    if (slots.length > maxSlots) {
      debugPrint('[NOTIF] Interval slots trimmed: ${slots.length} → $maxSlots '
          '(days=$dayCount, total would be ${slots.length * dayCount})');
      slots.removeRange(maxSlots, slots.length);
    }

    final notificationDetails = NotificationDetails(
      android: AndroidNotificationDetails(
        'review_notification_channel',
        '복습 알림',
        channelDescription: '설정한 시간에 랜덤 카드 알림',
        importance: Importance.high,
        priority: Priority.high,
        icon: '@drawable/ic_notification',
        playSound: soundEnabled,
        enableVibration: true,
      ),
    );

    final now = tz.TZDateTime.now(tz.local);

    for (int i = 0; i < slots.length; i++) {
      final slot = slots[i];
      final content = await _buildNotificationContent(folderId: folderId);

      if (days == null || days.isEmpty || days.length == 7) {
        var scheduled = tz.TZDateTime(
          tz.local, now.year, now.month, now.day, slot.hour, slot.minute,
        );
        if (scheduled.isBefore(now)) {
          scheduled = scheduled.add(const Duration(days: 1));
        }

        final notifId = _intervalBase + _safeId(id) * _intervalMultiplier + i * _intervalDayMultiplier + 8;
        await _plugin.zonedSchedule(
          notifId, content.title, content.body, scheduled, notificationDetails,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          matchDateTimeComponents: DateTimeComponents.time,
          payload: content.payload,
        );
      } else {
        for (final day in days) {
          final dartWeekday = day == 0 ? DateTime.sunday : day;
          final scheduled = _nextInstanceOfWeekdayTime(
            dartWeekday, slot.hour, slot.minute, now,
          );

          final notifId = _intervalBase + _safeId(id) * _intervalMultiplier + i * _intervalDayMultiplier + day; // day 0-6, all-days=8 → 충돌 없음
          await _plugin.zonedSchedule(
            notifId, content.title, content.body, scheduled, notificationDetails,
            androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
            matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
            payload: content.payload,
          );
        }
      }
    }
  }

  /// 특정 알람의 모든 알림 취소 (fixed + interval + per-day 모두)
  /// DB에서 해당 알람이 이미 삭제/비활성화된 후 호출할 것
  static Future<void> cancelAlarm(int id, {Set<int>? days}) async {
    // rescheduleAll() 내부에서 cancelAll → 재스케줄을 수행하므로 별도 cancelAll 불필요
    await rescheduleAll();
  }

  /// 단일 알림 삭제 후 나머지 재스케줄
  static Future<void> cancelNotification(int id) async {
    await rescheduleAll();
  }

  static Future<void> cancelAllNotifications() async {
    await _plugin.cancelAll();
  }
}
