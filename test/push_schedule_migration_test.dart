// PushScheduleMigration.buildRules — v1.3.8 저장값(push_alarms 전역 인터벌 알람 +
// push_schedule 오버라이드 슬롯) → v1.3.9 push_rules 규칙 목록 변환의 순수 함수
// 검증. sqflite 없이 실행 가능(DB 접근은 migrateIfNeeded에만 있고, 여기서는
// buildRules만 직접 호출한다).
import 'package:flutter_test/flutter_test.dart';
import 'package:memora/services/push_schedule.dart';
import 'package:memora/services/push_schedule_migration.dart';

Map<String, dynamic> _intervalAlarm({
  String mode = 'interval',
  int enabled = 1,
  String? startTime = '09:00',
  String? endTime = '22:00',
  int? intervalMin = 30,
  int? folderId,
  int? soundEnabled,
}) {
  return {
    'mode': mode,
    'enabled': enabled,
    'start_time': startTime,
    'end_time': endTime,
    'interval_min': intervalMin,
    'folder_id': folderId,
    'sound_enabled': ?soundEnabled,
  };
}

void main() {
  group('buildRules — 알람 경로(레거시 슬롯 없음)', () {
    test('알람 1개를 규칙 1개로 변환', () {
      final result = PushScheduleMigration.buildRules(
        legacyScheduleCsv: null,
        legacyScheduleEnabled: false,
        alarms: [_intervalAlarm()],
        notificationEnabled: true,
      );
      expect(result.rules, hasLength(1));
      final rule = result.rules.single;
      expect(rule.start, 540);
      expect(rule.end, 1320);
      expect(rule.folderId, PushSchedule.allFolders);
      expect(rule.intervalMin, 30);
    });

    test('folder_id가 지정된 알람은 그 폴더로 변환(전체 폴더 아님)', () {
      final result = PushScheduleMigration.buildRules(
        legacyScheduleCsv: null,
        legacyScheduleEnabled: false,
        alarms: [_intervalAlarm(folderId: 7)],
        notificationEnabled: true,
      );
      expect(result.rules.single.folderId, 7);
    });

    test('interval_min이 범위 밖이면 30으로 강등', () {
      final result = PushScheduleMigration.buildRules(
        legacyScheduleCsv: null,
        legacyScheduleEnabled: false,
        alarms: [_intervalAlarm(intervalMin: 9999)],
        notificationEnabled: true,
      );
      expect(result.rules.single.intervalMin, 30);
    });

    test('interval_min이 null이면 30으로 강등', () {
      final result = PushScheduleMigration.buildRules(
        legacyScheduleCsv: null,
        legacyScheduleEnabled: false,
        alarms: [_intervalAlarm(intervalMin: null)],
        notificationEnabled: true,
      );
      expect(result.rules.single.intervalMin, 30);
    });

    test('시각 파싱 실패(잘못된 HH:MM)면 알람을 무시하고 다음 단계로 폴백', () {
      final result = PushScheduleMigration.buildRules(
        legacyScheduleCsv: null,
        legacyScheduleEnabled: false,
        alarms: [_intervalAlarm(startTime: '25:99', endTime: '22:00')],
        notificationEnabled: true,
      );
      // 알람의 시각이 무효라 알람 경로가 실패 → notificationEnabled=true이므로
      // 기본 규칙(09:00-22:00/전체/30분)으로 폴백.
      expect(result.rules, hasLength(1));
      expect(result.rules.single.start, 540);
      expect(result.rules.single.end, 1320);
      expect(result.rules.single.folderId, PushSchedule.allFolders);
    });

    test('start==end로 파싱되는 알람도 무효 처리되어 폴백', () {
      final result = PushScheduleMigration.buildRules(
        legacyScheduleCsv: null,
        legacyScheduleEnabled: false,
        alarms: [_intervalAlarm(startTime: '09:00', endTime: '09:00')],
        notificationEnabled: true,
      );
      expect(result.rules, hasLength(1));
      expect(result.rules.single.start, 540);
      expect(result.rules.single.end, 1320);
    });

    test('enabled=0인 알람은 무시하고 그 다음 유효한 알람을 찾는다', () {
      final result = PushScheduleMigration.buildRules(
        legacyScheduleCsv: null,
        legacyScheduleEnabled: false,
        alarms: [
          _intervalAlarm(enabled: 0, startTime: '01:00', endTime: '02:00'),
          _intervalAlarm(enabled: 1, folderId: 3),
        ],
        notificationEnabled: true,
      );
      expect(result.rules, hasLength(1));
      expect(result.rules.single.folderId, 3);
      expect(result.rules.single.start, 540);
    });

    test('mode!=interval인 알람은 무시된다', () {
      final result = PushScheduleMigration.buildRules(
        legacyScheduleCsv: null,
        legacyScheduleEnabled: false,
        alarms: [_intervalAlarm(mode: 'fixed')],
        notificationEnabled: false,
      );
      expect(result.rules, isEmpty);
    });
  });

  group('buildRules — 알람도 레거시 슬롯도 없을 때', () {
    test('알람 없음 + notificationEnabled=true → 기본 규칙 1개', () {
      final result = PushScheduleMigration.buildRules(
        legacyScheduleCsv: null,
        legacyScheduleEnabled: false,
        alarms: const [],
        notificationEnabled: true,
      );
      expect(result.rules, hasLength(1));
      final rule = result.rules.single;
      expect(rule.start, 540);
      expect(rule.end, 1320);
      expect(rule.folderId, PushSchedule.allFolders);
      expect(rule.intervalMin, PushSchedule.defaultIntervalMin);
    });

    test('알람 없음 + notificationEnabled=false → 빈 목록', () {
      final result = PushScheduleMigration.buildRules(
        legacyScheduleCsv: null,
        legacyScheduleEnabled: false,
        alarms: const [],
        notificationEnabled: false,
      );
      expect(result.rules, isEmpty);
    });
  });

  group('buildRules — 레거시 오버라이드 슬롯 경로', () {
    test('레거시 슬롯 3개(일부 intervalMin==0) + enabled → 전역 인터벌로 채움', () {
      // 슬롯: 09-12(간격 명시 15), 12-18(간격 생략=레거시 INHERIT=0), 18-22(간격 생략=0).
      // 알람의 interval_min(45)이 "레거시 전역 인터벌"로 0인 것들을 채워야 한다.
      final result = PushScheduleMigration.buildRules(
        legacyScheduleCsv: '540:720:1:15,720:1080:2,1080:1320:3',
        legacyScheduleEnabled: true,
        alarms: [_intervalAlarm(intervalMin: 45)],
        notificationEnabled: true,
      );
      expect(result.rules, hasLength(3));
      expect(result.rules[0].intervalMin, 15); // 명시값 유지
      expect(result.rules[1].intervalMin, 45); // 0 → 전역 인터벌로 채움
      expect(result.rules[2].intervalMin, 45);
      expect(result.rules.map((r) => r.folderId).toList(), [1, 2, 3]);
    });

    test('레거시 슬롯이 있어도 legacyScheduleEnabled=false면 슬롯 경로를 타지 않고 알람 경로로 감', () {
      final result = PushScheduleMigration.buildRules(
        legacyScheduleCsv: '540:720:1:15',
        legacyScheduleEnabled: false,
        alarms: [_intervalAlarm(folderId: 9)],
        notificationEnabled: true,
      );
      expect(result.rules, hasLength(1));
      expect(result.rules.single.folderId, 9);
      expect(result.rules.single.start, 540);
      expect(result.rules.single.end, 1320);
    });

    test('레거시 슬롯이 비어있으면(잘못된 CSV) enabled여도 알람 경로로 폴백', () {
      final result = PushScheduleMigration.buildRules(
        legacyScheduleCsv: 'garbage',
        legacyScheduleEnabled: true,
        alarms: [_intervalAlarm(folderId: 4)],
        notificationEnabled: true,
      );
      expect(result.rules, hasLength(1));
      expect(result.rules.single.folderId, 4);
    });

    test('레거시 슬롯 13개(옛 MAX_SLOTS=5를 넘는 값) → 최종 정규화가 12개로 컷', () {
      final tokens =
          List.generate(13, (i) => '${i * 60}:${i * 60 + 30}:$i:20').join(',');
      final result = PushScheduleMigration.buildRules(
        legacyScheduleCsv: tokens,
        legacyScheduleEnabled: true,
        alarms: const [],
        notificationEnabled: true,
      );
      expect(result.rules, hasLength(PushSchedule.maxRules));
      expect(result.rules.map((r) => r.start).toList(),
          List.generate(12, (i) => i * 60));
    });
  });

  group('buildRules — soundEnabled', () {
    test('알람의 sound_enabled==0이면 false로 보존', () {
      final result = PushScheduleMigration.buildRules(
        legacyScheduleCsv: null,
        legacyScheduleEnabled: false,
        alarms: [_intervalAlarm(soundEnabled: 0)],
        notificationEnabled: true,
      );
      expect(result.soundEnabled, isFalse);
    });

    test('알람의 sound_enabled==1이면 true로 보존', () {
      final result = PushScheduleMigration.buildRules(
        legacyScheduleCsv: null,
        legacyScheduleEnabled: false,
        alarms: [_intervalAlarm(soundEnabled: 1)],
        notificationEnabled: true,
      );
      expect(result.soundEnabled, isTrue);
    });

    test('알람이 없으면 기본값 true', () {
      final result = PushScheduleMigration.buildRules(
        legacyScheduleCsv: null,
        legacyScheduleEnabled: false,
        alarms: const [],
        notificationEnabled: true,
      );
      expect(result.soundEnabled, isTrue);
    });
  });

  group('buildRules — 순수성', () {
    test('동일 입력으로 2회 호출해도 동일한 결과(부작용 없음)', () {
      final alarms = [_intervalAlarm(folderId: 5)];
      final once = PushScheduleMigration.buildRules(
        legacyScheduleCsv: '540:720:1:15',
        legacyScheduleEnabled: true,
        alarms: alarms,
        notificationEnabled: true,
      );
      final twice = PushScheduleMigration.buildRules(
        legacyScheduleCsv: '540:720:1:15',
        legacyScheduleEnabled: true,
        alarms: alarms,
        notificationEnabled: true,
      );
      expect(once.soundEnabled, twice.soundEnabled);
      expect(once.rules.length, twice.rules.length);
      for (var i = 0; i < once.rules.length; i++) {
        expect(once.rules[i].start, twice.rules[i].start);
        expect(once.rules[i].end, twice.rules[i].end);
        expect(once.rules[i].folderId, twice.rules[i].folderId);
        expect(once.rules[i].intervalMin, twice.rules[i].intervalMin);
      }
    });
  });
}
