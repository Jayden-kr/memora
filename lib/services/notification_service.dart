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
    // 알림 탭 시 앱 열기 (앱이 이미 실행 중이면 foreground로)
  }

  static Future<void> scheduleDailyNotification({
    required int id,
    required int hour,
    required int minute,
  }) async {
    // 랜덤 카드 선택
    String body = '카드를 복습할 시간입니다!';
    try {
      final cards = await DatabaseHelper.instance.getAllCards(limit: 100);
      if (cards.isNotEmpty) {
        final card = cards[Random().nextInt(cards.length)];
        body = card.question.isNotEmpty ? card.question : '(내용 없음)';
      }
    } catch (_) {}

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
      '암기왕',
      body,
      scheduled,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'review_notification_channel',
          '복습 알림',
          channelDescription: '설정한 시간에 랜덤 카드 알림',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  static Future<void> cancelNotification(int id) async {
    await _plugin.cancel(id);
  }

  static Future<void> cancelAllNotifications() async {
    await _plugin.cancelAll();
  }
}
