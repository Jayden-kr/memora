import 'package:flutter/foundation.dart';

import '../database/database_helper.dart';
import 'push_schedule.dart';

/// v1.3.8 이하의 두 저장 형태(전역 `push_alarms` 인터벌 알람 + `push_schedule` 오버라이드
/// 슬롯)를 v1.3.9의 단일 `push_rules` 규칙 목록으로 1회 변환한다. 순수 함수([buildRules])
/// + 얇은 DB 래퍼([migrateIfNeeded])로 분리되어 있다 — [buildRules]는 sqflite 없이
/// 유닛테스트 가능하다.
///
/// ⚠️ [migrateIfNeeded]는 절대 [NotificationService]의 재스케줄링 경로(rescheduleAll
/// 등)를 호출하지 않는다 — 저장만 하고 반환한다. rescheduleAll()이 최상단에서 이
/// 함수를 부르므로, 여기서 되돌아 rescheduleAll을 부르면 무한 재귀가 된다.
class PushScheduleMigration {
  /// v1.3.8 오버라이드 슬롯 CSV가 저장돼 있던 키. 마이그레이션 입력으로만 1회 읽는다.
  static const String legacyCsvKey = 'push_schedule';

  /// v1.3.8 "시간대별 폴더·주기 자동 전환" 마스터 스위치가 저장돼 있던 키.
  static const String legacyEnabledKey = 'push_schedule_enabled';

  /// 마이그레이션 1회성 실행을 보장하는 플래그.
  static const String migratedKey = 'push_rules_migrated';

  /// v1.3.8 이전 슬롯 형식(intervalMin==0 이 "전역 인터벌 상속"을 뜻하던 sentinel)을
  /// 그때의 의미 그대로 디코딩한다. 새 [PushSchedule.decode]와는 folderId(< -1만
  /// 드롭 vs < 0 드롭)와 intervalMin(30 강등 vs 0=inherit) 의미가 다르므로 별도
  /// 구현이 필요하다 — 이 파일에서만, 마이그레이션 입력을 읽는 용도로만 쓴다.
  /// 옛 MAX_SLOTS(5) 컷은 의도적으로 적용하지 않는다 — 최종 정규화 단계([buildRules]
  /// 마지막의 encode→decode 라운드트립)가 새 MAX_RULES(12) 컷을 어차피 적용하므로,
  /// 여기서 미리 5개로 잘라내면 6~12번째 레거시 슬롯을 부당하게 잃는다.
  static List<_LegacySlot> _legacyDecodeSlots(String? csv) {
    if (csv == null || csv.isEmpty) return [];
    const legacyInherit = 0;
    final slots = <_LegacySlot>[];
    for (final token in csv.split(',')) {
      if (token.isEmpty) continue;
      final parts = token.split(':');
      if (parts.length != 3 && parts.length != 4) continue;
      final start = int.tryParse(parts[0].trim());
      final end = int.tryParse(parts[1].trim());
      final folderId = int.tryParse(parts[2].trim());
      if (start == null || end == null || folderId == null) continue;
      if (start < 0 || start > 1439 || end < 0 || end > 1439) continue;
      if (start == end) continue;
      if (folderId < 0) continue;
      var intervalMin = legacyInherit;
      if (parts.length == 4) {
        final raw = int.tryParse(parts[3].trim());
        if (raw != null && raw >= 5 && raw <= 1440) intervalMin = raw;
      }
      slots.add(_LegacySlot(start, end, folderId, intervalMin));
    }
    slots.sort((a, b) => a.start.compareTo(b.start));
    return slots;
  }

  static Map<String, dynamic>? _findIntervalAlarm(
      List<Map<String, dynamic>> alarms) {
    for (final alarm in alarms) {
      final mode = alarm['mode'] as String? ?? 'fixed';
      final enabled = (alarm['enabled'] as int? ?? 1) == 1;
      if (mode == 'interval' && enabled) return alarm;
    }
    return null;
  }

  /// 첫 `mode=='interval' && enabled==1` 알람의 interval_min(5..1440 밖이면 30) —
  /// 없으면 30. v1.3.8 슬롯의 intervalMin==0(레거시 INHERIT)을 채우는 값.
  static int _legacyIntervalFromAlarms(List<Map<String, dynamic>> alarms) {
    final alarm = _findIntervalAlarm(alarms);
    if (alarm == null) return PushSchedule.defaultIntervalMin;
    final raw = alarm['interval_min'] as int?;
    if (raw != null && raw >= 5 && raw <= 1440) return raw;
    return PushSchedule.defaultIntervalMin;
  }

  /// "HH:MM" → 자정부터의 분. 길이 2, 정수, 0..23/0..59 엄격 검증(기존
  /// NotificationService._rescheduleAllImpl의 interval 알람 파싱 규칙 재사용). 실패
  /// 시 null.
  static int? _parseStrictHHMM(String? timeStr) {
    if (timeStr == null) return null;
    final parts = timeStr.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    if (h < 0 || h > 23 || m < 0 || m > 59) return null;
    return h * 60 + m;
  }

  /// v1.3.8 저장값들로부터 v1.3.9 규칙 목록을 합성한다(순수 함수, DB 접근 없음).
  ///
  /// 우선순위:
  /// 1. [legacyScheduleEnabled]이고 레거시 오버라이드 슬롯이 비지 않으면 그 슬롯들을
  ///    규칙으로 변환(intervalMin==0인 슬롯만 "레거시 전역 인터벌"로 채움). 전역
  ///    활성시간창 자체는 별도 행으로 추가하지 않는다(이 경로를 탈 수 있는 사용자는
  ///    v1.3.8 개발기기뿐 — 0명이므로 커버리지 차집합 계산은 하지 않는다).
  /// 2. (1 불성립) 첫 `mode=='interval' && enabled==1` 알람을 규칙 1개로 변환.
  ///    양끝포함→반열림 변환은 하지 않는다(09:00~22:00 → [540,1320), 22:00 정각
  ///    1분 손실 수용 — 릴리스 노트에 명시).
  /// 3. (1,2 모두 실패) [notificationEnabled]이면 기본 규칙 1개(09:00-22:00/전체
  ///    폴더/30분). 아니면 빈 목록.
  ///
  /// 최종적으로 encode→decode 1회로 정규화(정렬+12개 컷+간격 재검증)한다.
  static ({List<PushRule> rules}) buildRules({
    required String? legacyScheduleCsv,
    required bool legacyScheduleEnabled,
    required List<Map<String, dynamic>> alarms,
    required bool notificationEnabled,
  }) {
    List<PushRule> rules = [];

    if (legacyScheduleEnabled) {
      final legacySlots = _legacyDecodeSlots(legacyScheduleCsv);
      if (legacySlots.isNotEmpty) {
        final legacyInterval = _legacyIntervalFromAlarms(alarms);
        rules = legacySlots
            .map((s) => PushRule(
                  start: s.start,
                  end: s.end,
                  folderId: s.folderId,
                  intervalMin: s.intervalMin == 0 ? legacyInterval : s.intervalMin,
                ))
            .toList();
      }
    }

    if (rules.isEmpty) {
      final intervalAlarm = _findIntervalAlarm(alarms);
      if (intervalAlarm != null) {
        final start = _parseStrictHHMM(intervalAlarm['start_time'] as String?);
        final end = _parseStrictHHMM(intervalAlarm['end_time'] as String?);
        if (start != null && end != null && start != end) {
          final rawInterval = intervalAlarm['interval_min'] as int?;
          final interval = (rawInterval != null && rawInterval >= 5 && rawInterval <= 1440)
              ? rawInterval
              : PushSchedule.defaultIntervalMin;
          final folderId =
              (intervalAlarm['folder_id'] as int?) ?? PushSchedule.allFolders;
          rules = [
            PushRule(start: start, end: end, folderId: folderId, intervalMin: interval)
          ];
        }
      }
    }

    if (rules.isEmpty && notificationEnabled) {
      rules = [
        const PushRule(
          start: 540,
          end: 1320,
          folderId: PushSchedule.allFolders,
          intervalMin: PushSchedule.defaultIntervalMin,
        )
      ];
    }

    final normalized = PushSchedule.decode(PushSchedule.encode(rules));
    return (rules: normalized);
  }

  /// settings에 아직 `push_rules`가 없고 마이그레이션이 실행된 적 없으면 1회 실행.
  /// 순서: ① push_rules upsert → ② push_rules_migrated='true' upsert (플래그는
  /// 반드시 마지막 — 중간에 죽어도 다음 호출이 안전하게 재시도한다). encoded가 빈
  /// 문자열이어도 플래그는 쓴다(안 그러면 매번 재시도해 알림 비활성 사용자에게 계속
  /// 불필요한 DB 쓰기가 생긴다).
  static Future<void> migrateIfNeeded(Map<String, String> settings) async {
    final alreadyMigrated =
        (settings[migratedKey] ?? '').toLowerCase() == 'true';
    final currentRulesCsv = settings[PushSchedule.settingRulesKey] ?? '';
    if (alreadyMigrated || currentRulesCsv.isNotEmpty) return;

    List<Map<String, dynamic>> alarms;
    try {
      alarms = await DatabaseHelper.instance.getAllPushAlarms();
    } catch (e) {
      debugPrint('[PUSH_MIGRATION] getAllPushAlarms 실패: $e');
      alarms = [];
    }

    final legacyEnabled =
        (settings[legacyEnabledKey] ?? '').toLowerCase() == 'true';
    final legacyCsv = settings[legacyCsvKey];
    final notificationEnabled =
        (settings['notification_enabled'] ?? '').toLowerCase() == 'true';

    final built = buildRules(
      legacyScheduleCsv: legacyCsv,
      legacyScheduleEnabled: legacyEnabled,
      alarms: alarms,
      notificationEnabled: notificationEnabled,
    );

    final encoded = PushSchedule.encode(built.rules);
    try {
      await DatabaseHelper.instance
          .upsertSetting(PushSchedule.settingRulesKey, encoded);
      await DatabaseHelper.instance.upsertSetting(migratedKey, 'true');
    } catch (e) {
      debugPrint('[PUSH_MIGRATION] 저장 실패: $e');
    }
  }
}

class _LegacySlot {
  final int start;
  final int end;
  final int folderId;
  final int intervalMin;
  _LegacySlot(this.start, this.end, this.folderId, this.intervalMin);
}
