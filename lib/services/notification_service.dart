import 'dart:math';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../database/database_helper.dart';

class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();

  static Future<void> initialize() async {
    tz.initializeTimeZones();

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: androidSettings);
    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: _onNotificationTap,
    );
  }

  static void _onNotificationTap(NotificationResponse response) {
    // payload는 "folderId:cardId" 형식
    // 앱이 이미 열려있으면 foreground로 전환됨 (Flutter 기본 동작)
    // 딥링크 네비게이션은 Navigator key 필요 → 현재는 앱 열기만
  }

  /// 특정 요일에만 알림을 스케줄링
  /// [days]: 요일 인덱스 (0=일, 1=월, ..., 6=토)
  /// [folderId]: null이면 전체 카드, 있으면 해당 폴더 카드만
  /// [soundEnabled]: 알림음 사용 여부
  static Future<void> scheduleDailyNotification({
    required int id,
    required int hour,
    required int minute,
    Set<int>? days,
    int? folderId,
    bool soundEnabled = true,
  }) async {
    // 랜덤 카드 선택 (폴더 필터링)
    String title = 'Memora';
    String body = '카드를 복습할 시간입니다!';
    String? payload;

    try {
      final List cards;
      if (folderId != null) {
        cards = await DatabaseHelper.instance.getCardsByFolderId(folderId,
            limit: 100);
        final folder = await DatabaseHelper.instance.getFolderById(folderId);
        if (folder != null) {
          title = folder.name;
        }
      } else {
        cards = await DatabaseHelper.instance.getAllCards(limit: 100);
      }
      if (cards.isNotEmpty) {
        final card = cards[Random().nextInt(cards.length)];
        // PRD 형식: "[폴더명] / [Question]"
        if (folderId != null) {
          body = card.question.isNotEmpty ? card.question : '(내용 없음)';
        } else {
          body = card.question.isNotEmpty ? card.question : '(내용 없음)';
        }
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

    // 요일 지정이 없으면 매일 알림
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
      // 각 요일별로 개별 스케줄링
      // ID를 요일별로 분리: id * 10 + dayOfWeek
      for (final day in days) {
        // Flutter 요일: 0=일, 1=월 ... 6=토
        // DateTime.weekday: 1=월 ... 7=일
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

  /// 다음 특정 요일+시간의 TZDateTime 계산
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
    // 해당 요일까지 날짜 이동
    while (scheduled.weekday != weekday) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    // 이미 지난 시간이면 다음 주로
    if (scheduled.isBefore(now)) {
      scheduled = scheduled.add(const Duration(days: 7));
    }
    return scheduled;
  }

  /// 특정 알람의 모든 요일 알림 취소
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
    // 요일별 알림도 취소 (0~6)
    for (int day = 0; day <= 6; day++) {
      await _plugin.cancel(id * 10 + day);
    }
  }

  static Future<void> cancelAllNotifications() async {
    await _plugin.cancelAll();
  }
}
