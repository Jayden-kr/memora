// 시간대 규칙(PushSchedule) "실전 조합" 시뮬레이션 — v1.3.9 통합 이후 사용자가 실제
// UI에서 만들 법한 규칙 조합을 이름 붙여 나열하고, 1440분 전수를 프로덕션 함수
// (decode/activeRule/effectiveRanges/gapRanges/overlappingIndices) 그대로에 태워
// 검증한다.
//
// push_schedule_test.dart의 기존 4~6번 그룹과 다른 점: 그쪽은 "무작위 조합 대조
// 프로퍼티"이고, 여기는 "사용자가 실제로 만들 법한 이름 붙은 시나리오"다 — 겹침,
// gap, 완전분할, 완전포함(가려짐), 동시시작 타이브레이크, 이중 자정넘김 겹침,
// 최대 규칙(12개) 스트레스 등을 개별적으로 이름 붙여 각각의 함의를 명시적으로
// 검증한다.
//
// ⚠️ UI 슬롯 개수 상한: PushSchedule.maxRules는 12다(순수로직 상수). 사용자가 이
// 기능을 "5개 슬롯"이라 부른 적이 있으나 실제 UI(_onAddPushRuleTapped)는
// `_rules.length >= PushSchedule.maxRules`(=12)에서만 막고, 안내 문구도
// "최대 12개"(app_ko.arb/app_en.arb pushScheduleMaxReached)다 — 5는 실제 제한이
// 아니다. 이 파일의 시나리오는 실제 UI 상한인 12를 기준으로 삼는다(S13 스트레스
// 시나리오가 정확히 12개를 채운다).
//
// interval 전환의 "다음 TICK부터 지연되며 그 지연이 나가는 슬롯 1주기 이내"라는
// 주장은 AlarmManager 기반 스케줄링(PushNotificationService.kt)의 문제라 순수
// Dart 모델엔 대응 개념이 없다 — 그 부분은
// android/app/src/test/kotlin/com/henry/memora/PushScheduleCombinatorialSimTest.kt
// 의 TickSimulator가 검증한다. 이 파일은 "정적" 소유권/겹침/gap 정합성만 다룬다.
import 'package:flutter_test/flutter_test.dart';
import 'package:memora/services/push_schedule.dart';

class _Scenario {
  final String name;
  final String csv;
  const _Scenario(this.name, this.csv);
}

// 5시(300)부터 시작하는 형태로 자정을 걸치는 예도 섞는다. 전부 실제 decode()가
// 받아들이는 4필드 CSV.
final _scenarios = [
  // S1 — 5개 규칙이 하루를 gap 없이 완전히 분할 (06-10/10-14/14-18/18-22/22-06)
  _Scenario('S1_전체분할_gap없음',
      '360:600:1:30,600:840:2:15,840:1080:3:60,1080:1320:4:20,1320:360:5:10'),
  // S2 — 3개 규칙만 채우고 나머지는 무음(gap)
  _Scenario('S2_부분채움_gap있음', '540:720:1:30,900:1020:2:45,1200:1320:3:60'),
  // S3 — 두 쌍이 겹침: 평일 부분겹침(09-15 & 12-18) + 자정넘김 부분겹침(20-02 & 22-04)
  _Scenario('S3_두겹침쌍_평일및자정넘김',
      '540:900:1:30,720:1080:2:20,1200:120:3:15,1320:240:4:25'),
  // S4 — 한 슬롯(12-13)이 다른 슬롯(09-18) 안에 완전히 포함되어 영원히 가려짐
  _Scenario('S4_완전포함_가려짐', '540:1080:1:30,720:780:2:20'),
  // S5 — 5개 전부 같은 시각(10:00)에 시작, 끝나는 시각만 다름 — stable sort 타이브레이크
  _Scenario('S5_동시시작_극단겹침',
      '600:660:1:10,600:720:2:20,600:900:3:30,600:1000:4:40,600:1200:5:50'),
  // S6 — 전체 폴더(-1) 슬롯과 특정 폴더 슬롯이 섞여 하루를 분할
  _Scenario('S6_전체폴더혼합', '0:480:-1:30,480:960:7:45,960:0:12:20'),
  // S7 — 인접한 두 슬롯의 간격이 극단적으로 다름(5분 슬롯 뒤 1440분 슬롯)
  _Scenario('S7_인접간격극단차', '0:5:1:5,5:0:2:1440'),
  // S8 — 슬롯 길이(10분)가 그 슬롯 자신의 간격(30분)보다 짧음 — 정적으로는 유효한
  // 선언(가려짐 없음). "그 안에서 한 번도 안 울릴 수 있다"는 위상(phase) 의존적
  // 주장이라 Kotlin TickSimulator에서 실증한다.
  _Scenario('S8_슬롯보다긴간격', '540:550:1:30'),
  // S9 — 자정을 넘는 슬롯이 "둘 다" 있고 서로 겹침(22-03 & 23-04)
  _Scenario('S9_이중자정넘김겹침', '1320:180:1:20,1380:240:2:25'),
  // S11 — 경계값 극단: start=0, end=1439(거의 하루 전체) + 1439-0(1분짜리 wrap 슬롯)
  _Scenario('S11_경계극단', '0:1439:1:30,1439:0:2:60'),
  // S12 — 실사용 패턴: 기상 직후 복습 30분 + 근무시간 무음 + 저녁 신규카드 + 취침 무음
  _Scenario('S12_실사용패턴', '420:450:1:60,1140:1380:2:20'),
  // S13 — 12개(=실제 UI 상한) 꽉 채움, 슬롯 사이마다 60분 gap
  _Scenario(
    'S13_최대12개스트레스',
    List.generate(12, (i) {
      final start = i * 110;
      final end = start + 50;
      final folderId = i;
      final interval = 5 + i * 3;
      return '$start:$end:$folderId:$interval';
    }).join(','),
  ),
];

/// effectiveRanges/gapRanges가 반환하는 [start, end) 구간 표기의 실제 계약: end==0은
/// "자정까지"를 뜻하고, start > end는 병합된 자정래핑 구간(예: [1200,120] = 20:00부터
/// 자정을 넘어 02:00까지)을 뜻한다 — PushRule/LockScreenSlot의 반열림+자정래핑 계약과
/// 동일하다. start == end는 이 파일의 어떤 시나리오에서도 나오지 않는다(전 규칙이
/// 빈 목록일 때만 gapRanges가 [[0,0]]을 내는데, 이 파일 시나리오는 전부 규칙 1개
/// 이상이라 해당 없음).
void _forEachMinuteInRange(List<int> range, void Function(int minute) body) {
  final start = range[0];
  final end = range[1];
  if (start < end) {
    for (var m = start; m < end; m++) {
      body(m);
    }
  } else if (start > end) {
    for (var m = start; m < 1440; m++) {
      body(m);
    }
    for (var m = 0; m < end; m++) {
      body(m);
    }
  }
}

/// effectiveRanges 결과로부터 owner[m] = 그 분을 소유하는 규칙의 인덱스(없으면 -1)를
/// 만든다.
List<int> _ownerFromEffectiveRanges(List<List<List<int>>> effRanges) {
  final owner = List<int>.filled(1440, -1);
  for (var i = 0; i < effRanges.length; i++) {
    for (final range in effRanges[i]) {
      _forEachMinuteInRange(range, (m) => owner[m] = i);
    }
  }
  return owner;
}

bool _minuteInRanges(List<List<int>> ranges, int minute) {
  for (final r in ranges) {
    var found = false;
    _forEachMinuteInRange(r, (m) {
      if (m == minute) found = true;
    });
    if (found) return true;
  }
  return false;
}

/// `contains([a,b])`는 `List<int>`가 ==를 오버라이드하지 않아 값이 같아도 항상
/// 실패한다(identity 비교) — gaps/ranges 목록에 특정 [start,end] 쌍이 값으로
/// 들어있는지는 이 헬퍼로 확인한다.
bool _rangesContainPair(List<List<int>> ranges, int start, int end) {
  return ranges.any((r) => r.length == 2 && r[0] == start && r[1] == end);
}

/// 한 시나리오에 대해 (a) activeRule ↔ effectiveRanges 소유권 100% 일치
/// (b) gap 분에서 activeRule==null && gapRanges에 포함 (c: 경계 전환은 개별 named
/// 테스트에서 하드코딩 확인) 를 1440분 전수로 검증한다.
void _verifyOwnershipAndGapConsistency(_Scenario s) {
  final rules = PushSchedule.decode(s.csv);
  final effRanges = PushSchedule.effectiveRanges(rules);
  final gaps = PushSchedule.gapRanges(rules);
  final owner = _ownerFromEffectiveRanges(effRanges);

  // gap 커버리지 합 + effectiveRanges 커버리지 합 == 1440 (전 분 계산 안에 포함됨,
  // 아래 루프가 이미 이를 함의하지만 명시적으로도 한 번 확인).
  var coveredCount = 0;
  var gapCount = 0;

  for (var m = 0; m < 1440; m++) {
    final active = PushSchedule.activeRule(m, rules);
    final ownerIdx = owner[m];
    final isGapMinute = _minuteInRanges(gaps, m);

    if (active == null) {
      expect(ownerIdx, -1,
          reason:
              '${s.name} minute=$m: activeRule=null인데 effectiveRanges는 규칙[$ownerIdx]이 소유한다고 함');
      expect(isGapMinute, isTrue,
          reason: '${s.name} minute=$m: activeRule=null인데 gapRanges에 없음');
      gapCount++;
    } else {
      final activeIdx = rules.indexOf(active);
      expect(ownerIdx, isNot(-1),
          reason:
              '${s.name} minute=$m: activeRule=규칙[$activeIdx]인데 effectiveRanges는 아무도 소유하지 않는다고 함');
      expect(ownerIdx, activeIdx,
          reason:
              '${s.name} minute=$m: activeRule 소유자(규칙[$activeIdx])와 effectiveRanges 소유자(규칙[$ownerIdx])가 다름');
      expect(isGapMinute, isFalse,
          reason:
              '${s.name} minute=$m: activeRule이 있는데(규칙[$activeIdx]) 그 분이 gapRanges에도 포함됨(모순)');
      coveredCount++;
    }
  }

  expect(coveredCount + gapCount, 1440,
      reason: '${s.name}: 커버리지+gap 합이 1440이 아님(중복 계산 버그 의심)');
}

void main() {
  group('명명된 시나리오 — activeRule ↔ effectiveRanges/gapRanges 1440분 전수 정합성', () {
    for (final s in _scenarios) {
      test(s.name, () => _verifyOwnershipAndGapConsistency(s));
    }
  });

  group('S1 — 전체분할: 매 경계에서 폴더가 정확히 다음 슬롯 것으로 즉시 바뀐다', () {
    test('S1', () {
      final rules = PushSchedule.decode(_scenarios[0].csv);
      // (분, 기대 folderId) — 각 구간의 시작/끝 경계 양쪽을 전부 짚는다.
      const expectations = {
        0: 5, 359: 5, // 22:00~06:00 (wrap) 구간의 자정 이후 쪽
        360: 1, 599: 1, // 06:00~10:00
        600: 2, 839: 2, // 10:00~14:00
        840: 3, 1079: 3, // 14:00~18:00
        1080: 4, 1319: 4, // 18:00~22:00
        1320: 5, 1439: 5, // 22:00~06:00 (wrap) 구간의 자정 이전 쪽
      };
      expectations.forEach((minute, expectedFolder) {
        final rule = PushSchedule.activeRule(minute, rules);
        expect(rule, isNotNull, reason: 'minute=$minute');
        expect(rule!.folderId, expectedFolder, reason: 'minute=$minute');
      });
      // gap이 전혀 없어야 한다.
      expect(PushSchedule.gapRanges(rules), isEmpty);
      // 5개 규칙 중 서로 겹치는 게 하나도 없어야 한다.
      expect(PushSchedule.overlappingIndices(rules), isEmpty);
    });
  });

  group('S2 — 부분채움: gap 구간에서 activeRule==null, minutesUntilNextStart 없이도'
      ' gapRanges로 간격 확인', () {
    test('S2', () {
      final rules = PushSchedule.decode(_scenarios[1].csv);
      // 커버 구간
      expect(PushSchedule.activeRule(540, rules)!.folderId, 1);
      expect(PushSchedule.activeRule(719, rules)!.folderId, 1);
      expect(PushSchedule.activeRule(900, rules)!.folderId, 2);
      expect(PushSchedule.activeRule(1019, rules)!.folderId, 2);
      expect(PushSchedule.activeRule(1200, rules)!.folderId, 3);
      expect(PushSchedule.activeRule(1319, rules)!.folderId, 3);
      // gap 구간 경계 양쪽
      for (final m in [720, 899, 1020, 1199]) {
        expect(PushSchedule.activeRule(m, rules), isNull, reason: 'minute=$m');
      }
      // gap이 4구간이었다가 자정랩 병합으로 3구간이 되어야 한다: [1320,540)
      // (0-540과 1320-1440이 물리적으로 하나), [720,900), [1020,1200).
      final gaps = PushSchedule.gapRanges(rules);
      expect(gaps.length, 3, reason: 'gaps=$gaps');
      expect(_rangesContainPair(gaps, 1320, 540), isTrue, reason: 'gaps=$gaps');
      expect(_rangesContainPair(gaps, 720, 900), isTrue, reason: 'gaps=$gaps');
      expect(_rangesContainPair(gaps, 1020, 1200), isTrue, reason: 'gaps=$gaps');
      expect(PushSchedule.overlappingIndices(rules), isEmpty);
    });
  });

  group('S3 — 두 겹침쌍: 먼저 시작하는 규칙이 항상 이긴다(평일+자정넘김 둘 다)', () {
    test('S3', () {
      final rules = PushSchedule.decode(_scenarios[2].csv);
      // pair A: 09-15(rule0) & 12-18(rule1) 겹침 구간(12:00-15:00=720-899)은
      // 먼저 시작한 rule0(540)가 이긴다.
      expect(PushSchedule.activeRule(540, rules)!.folderId, 1); // 09:00
      expect(PushSchedule.activeRule(750, rules)!.folderId, 1); // 겹침구간 안, rule0 승
      expect(PushSchedule.activeRule(900, rules)!.folderId, 2); // rule0 끝난 뒤 rule1 단독
      expect(PushSchedule.activeRule(1079, rules)!.folderId, 2); // 17:59
      expect(PushSchedule.activeRule(1080, rules), isNull); // 18:00, rule1도 끝남(gap)
      // pair B: 20-02(rule2, 1200-120) & 22-04(rule3, 1320-240) — 겹침구간(22:00-02:00)은
      // 먼저 시작한 rule2(1200)가 이긴다. 자정 양쪽 다 확인.
      expect(PushSchedule.activeRule(1200, rules)!.folderId, 3); // 20:00, rule2 단독
      expect(PushSchedule.activeRule(1319, rules)!.folderId, 3); // 21:59, rule2 단독
      expect(PushSchedule.activeRule(1320, rules)!.folderId, 3); // 22:00, 겹침 시작, rule2 승
      expect(PushSchedule.activeRule(1439, rules)!.folderId, 3); // 23:59, 겹침구간, rule2 승
      expect(PushSchedule.activeRule(0, rules)!.folderId, 3); // 00:00, 겹침구간, rule2 승
      expect(PushSchedule.activeRule(119, rules)!.folderId, 3); // 01:59, 겹침구간, rule2 승
      expect(PushSchedule.activeRule(120, rules)!.folderId, 4); // 02:00, rule2 끝남 → rule3 단독
      expect(PushSchedule.activeRule(239, rules)!.folderId, 4); // 03:59
      expect(PushSchedule.activeRule(240, rules), isNull); // 04:00, gap

      final overlap = PushSchedule.overlappingIndices(rules);
      expect(overlap, {0, 1, 2, 3}, reason: '두 쌍 전부 겹침 경고 대상이어야 함');
    });
  });

  group('S4 — 완전포함: 안쪽 슬롯은 effectiveRanges에서 빈 리스트(영원히 안 뜸)', () {
    test('S4', () {
      final rules = PushSchedule.decode(_scenarios[3].csv);
      expect(rules.length, 2);
      final eff = PushSchedule.effectiveRanges(rules);
      // 바깥 슬롯(09-18)은 그대로 자기 구간 전체를 차지.
      expect(eff[0], [
        [540, 1080]
      ]);
      // 안쪽 슬롯(12-13)은 완전히 가려져 빈 리스트 — UI의 "이 시간대에는 절대
      // 적용되지 않습니다" 경고(pushScheduleNeverApplies)와 정확히 같은 판정.
      expect(eff[1], isEmpty);
      // activeRule로도 12:00~13:00 사이 내내 바깥 슬롯(folder=1)만 보여야 한다.
      for (final m in [720, 750, 779]) {
        expect(PushSchedule.activeRule(m, rules)!.folderId, 1, reason: 'minute=$m');
      }
      expect(PushSchedule.overlappingIndices(rules), {0, 1});
    });
  });

  group('S5 — 동시시작: stable sort로 목록 순서가 유지되고, 먼저 등록된 규칙이 자기'
      ' 구간 동안 완전히 이기며, 끝나는 순서대로 다음 규칙에 바통이 넘어간다', () {
    test('S5', () {
      final rules = PushSchedule.decode(_scenarios[4].csv);
      // decode는 stable sort이므로 start가 전부 600으로 같으면 원래 CSV 순서
      // (folderId 1,2,3,4,5)가 그대로 유지되어야 한다.
      expect(rules.map((r) => r.folderId).toList(), [1, 2, 3, 4, 5]);

      // 텔레스코핑 소유권: 매 순간 "아직 안 끝난 것 중 목록에서 가장 앞선" 규칙이 이긴다.
      const expectations = {
        600: 1, 659: 1, // rule1(600-660) 단독구간
        660: 2, 719: 2, // rule1 끝, rule2(600-720)가 이어받음
        720: 3, 899: 3, // rule2 끝, rule3(600-900)
        900: 4, 999: 4, // rule3 끝, rule4(600-1000)
        1000: 5, 1199: 5, // rule4 끝, rule5(600-1200)
      };
      expectations.forEach((minute, expectedFolder) {
        final rule = PushSchedule.activeRule(minute, rules);
        expect(rule, isNotNull, reason: 'minute=$minute');
        expect(rule!.folderId, expectedFolder, reason: 'minute=$minute');
      });
      // 1200 이후 및 0~599는 어느 규칙도 커버하지 않음(전부 600 이후 시작).
      expect(PushSchedule.activeRule(1200, rules), isNull);
      expect(PushSchedule.activeRule(0, rules), isNull);
      expect(PushSchedule.activeRule(599, rules), isNull);

      // 전부 서로 겹치므로 5개 전부 경고 대상.
      expect(PushSchedule.overlappingIndices(rules), {0, 1, 2, 3, 4});
    });
  });

  group('S6 — 전체 폴더(-1)와 특정 폴더가 섞여도 targetFolderId 변환이 매 전환마다 정확', () {
    test('S6', () {
      final rules = PushSchedule.decode(_scenarios[5].csv);
      int? targetFolderId(int minute) {
        final r = PushSchedule.activeRule(minute, rules);
        if (r == null) return -999; // 편의상 gap을 -999로 표시(실제 folderId와 안 겹침)
        return r.folderId == PushSchedule.allFolders ? null : r.folderId;
      }

      expect(targetFolderId(0), isNull); // 00:00~08:00, 전체 폴더
      expect(targetFolderId(479), isNull);
      expect(targetFolderId(480), 7); // 08:00~16:00, 폴더7
      expect(targetFolderId(959), 7);
      expect(targetFolderId(960), 12); // 16:00~24:00(wrap), 폴더12
      expect(targetFolderId(1439), 12);
      expect(PushSchedule.gapRanges(rules), isEmpty); // 하루 전체가 커버됨
    });
  });

  group('S7 — 인접 슬롯 간 간격 극단차: 정적 소유권은 경계에서 즉시 전환(간격 자체의'
      ' 지연은 Kotlin TickSimulator에서 검증)', () {
    test('S7', () {
      final rules = PushSchedule.decode(_scenarios[6].csv);
      expect(PushSchedule.activeRule(0, rules)!.folderId, 1);
      expect(PushSchedule.activeRule(4, rules)!.folderId, 1);
      expect(PushSchedule.activeRule(5, rules)!.folderId, 2); // 경계, 즉시 전환
      expect(PushSchedule.activeRule(1439, rules)!.folderId, 2);
      expect(PushSchedule.gapRanges(rules), isEmpty);
    });
  });

  group('S8 — 슬롯(10분)이 자기 간격(30분)보다 짧아도 정적 선언 자체는 유효(가려짐'
      ' 없음) — "그 안에서 한 번도 안 울릴 수 있다"는 위상 의존적 주장이라 여기선'
      ' 확인하지 않는다', () {
    test('S8', () {
      final rules = PushSchedule.decode(_scenarios[7].csv);
      expect(rules.length, 1);
      final eff = PushSchedule.effectiveRanges(rules);
      expect(eff[0], [
        [540, 550]
      ]); // 가려지지 않고 선언한 그대로 적용됨 — 버그 아님
      expect(PushSchedule.overlappingIndices(rules), isEmpty);
    });
  });

  group('S9 — 이중 자정넘김 겹침: 반열림+자정래핑이 겹침판정과 함께 정확', () {
    test('S9', () {
      final rules = PushSchedule.decode(_scenarios[8].csv);
      // rule0=22:00-03:00(1320-180), rule1=23:00-04:00(1380-240). 둘 다 자정을
      // 넘는다. 겹침구간은 23:00~03:00(1380~1440 ∪ 0~180) — 먼저 시작한 rule0 승.
      expect(PushSchedule.activeRule(1320, rules)!.folderId, 1); // 22:00, rule0 단독
      expect(PushSchedule.activeRule(1379, rules)!.folderId, 1); // 22:59, rule0 단독
      expect(PushSchedule.activeRule(1380, rules)!.folderId, 1); // 23:00, 겹침 시작, rule0 승
      expect(PushSchedule.activeRule(1439, rules)!.folderId, 1); // 23:59, 겹침, rule0 승
      expect(PushSchedule.activeRule(0, rules)!.folderId, 1); // 00:00, 겹침, rule0 승
      expect(PushSchedule.activeRule(179, rules)!.folderId, 1); // 02:59, 겹침, rule0 승
      expect(PushSchedule.activeRule(180, rules)!.folderId, 2); // 03:00, rule0 끝 → rule1 단독
      expect(PushSchedule.activeRule(239, rules)!.folderId, 2); // 03:59
      expect(PushSchedule.activeRule(240, rules), isNull); // 04:00, gap
      expect(PushSchedule.overlappingIndices(rules), {0, 1});
    });
  });

  group('S11 — 경계 극단: start=0/end=1439의 거의 하루짜리 슬롯 + 1분짜리 wrap 슬롯', () {
    test('S11', () {
      final rules = PushSchedule.decode(_scenarios[9].csv);
      // rule0 = 0~1439(반열림, 0..1438 커버), rule1 = 1439~0(반열림, 자정래핑,
      // 오직 1439분만 커버).
      expect(PushSchedule.activeRule(0, rules)!.folderId, 1);
      expect(PushSchedule.activeRule(1438, rules)!.folderId, 1);
      expect(PushSchedule.activeRule(1439, rules)!.folderId, 2); // 1분짜리 슬롯 단독
      expect(PushSchedule.gapRanges(rules), isEmpty); // 둘이 합쳐 하루 전체를 정확히 분할
      expect(PushSchedule.overlappingIndices(rules), isEmpty); // 겹치지 않음(반열림 경계 존중)
    });
  });

  group('S12 — 실사용 패턴(기상복습/근무무음/저녁신규/취침무음)에서 gap이 정확히 계산됨', () {
    test('S12', () {
      final rules = PushSchedule.decode(_scenarios[10].csv);
      expect(PushSchedule.activeRule(420, rules)!.folderId, 1); // 07:00 기상복습
      expect(PushSchedule.activeRule(449, rules)!.folderId, 1);
      expect(PushSchedule.activeRule(450, rules), isNull); // 07:30, 근무 무음 시작
      expect(PushSchedule.activeRule(1139, rules), isNull); // 18:59, 아직 무음
      expect(PushSchedule.activeRule(1140, rules)!.folderId, 2); // 19:00 저녁 신규
      expect(PushSchedule.activeRule(1379, rules)!.folderId, 2); // 22:59
      expect(PushSchedule.activeRule(1380, rules), isNull); // 23:00 취침 무음
      final gaps = PushSchedule.gapRanges(rules);
      // 취침(23:00~07:00)과 근무(07:30~19:00) 두 구간의 gap이어야 한다(자정랩 병합 없음
      // — 두 gap 모두 자정을 걸치지 않거나 이미 하나로 표현되는지 확인).
      expect(gaps.length, 2, reason: 'gaps=$gaps');
      expect(_rangesContainPair(gaps, 1380, 420), isTrue,
          reason: 'gaps=$gaps (23:00~07:00, wrap 병합됨)');
      expect(_rangesContainPair(gaps, 450, 1140), isTrue,
          reason: 'gaps=$gaps (07:30~19:00)');
    });
  });

  group('S13 — 12개(실제 UI 상한) 꽉 채운 스트레스: 전수 정합성 + 슬롯 사이 gap 확인', () {
    test('S13', () {
      final rules = PushSchedule.decode(_scenarios[11].csv);
      expect(rules.length, 12, reason: 'decode가 12개를 전부 받아들여야 함(상한 이내)');
      // 각 슬롯: start=i*110, end=start+50 → 슬롯 사이(end~다음 start)는 60분 gap.
      for (var i = 0; i < 12; i++) {
        final start = i * 110;
        final mid = start + 25;
        expect(PushSchedule.activeRule(mid, rules)!.folderId, i,
            reason: 'slot $i 중간(minute=$mid)');
        final gapMid = start + 50 + 30; // 슬롯 끝나고 30분 뒤(60분 gap의 중간)
        if (gapMid < 1440) {
          expect(PushSchedule.activeRule(gapMid, rules), isNull,
              reason: 'slot $i 뒤 gap 중간(minute=$gapMid)');
        }
      }
      expect(PushSchedule.overlappingIndices(rules), isEmpty);
    });
  });

  group('S10 — 연쇄 편집: 5슬롯 꽉 채운 상태에서 하나 삭제→gap 발생→다른 규칙으로'
      ' 재충전', () {
    String timingKey(List<PushRule> rules) => 'v2:${PushSchedule.encode(rules)}';

    test('S10', () {
      // 1단계: S1과 동일한 5규칙 완전분할 상태로 시작.
      final phase1 = PushSchedule.decode(_scenarios[0].csv);
      expect(PushSchedule.gapRanges(phase1), isEmpty);
      final key1 = timingKey(phase1);

      // 2단계: 3번째 규칙(14:00-18:00, folder3)을 삭제 → 840-1080에 gap 발생.
      final phase2 = List<PushRule>.from(phase1)..removeAt(2);
      // CSV 라운드트립(실제 UI가 삭제 후 저장할 때와 동일 경로).
      final phase2FromRoundTrip =
          PushSchedule.decode(PushSchedule.encode(phase2));
      expect(phase2FromRoundTrip.map((r) => r.folderId).toList(), [1, 2, 4, 5]);
      final gapsAfterDelete = PushSchedule.gapRanges(phase2FromRoundTrip);
      expect(gapsAfterDelete, [
        [840, 1080]
      ]);
      expect(PushSchedule.activeRule(900, phase2FromRoundTrip), isNull);
      final key2 = timingKey(phase2FromRoundTrip);
      expect(key2, isNot(key1), reason: '규칙 목록이 바뀌었으니 timingKey도 달라져야 함(전체 타이머 리셋 트리거)');

      // 3단계: 그 gap을 새 규칙(folder=99, interval=5)으로 다시 채움.
      final refillCsv =
          '${PushSchedule.encode(phase2FromRoundTrip)},840:1080:99:5';
      final phase3 = PushSchedule.decode(refillCsv);
      expect(phase3.length, 5);
      expect(PushSchedule.gapRanges(phase3), isEmpty,
          reason: 'gap을 새 규칙으로 다시 채웠으니 gap이 없어야 함');
      expect(PushSchedule.activeRule(900, phase3)!.folderId, 99);
      expect(PushSchedule.activeRule(900, phase3)!.intervalMin, 5);
      final key3 = timingKey(phase3);
      expect(key3, isNot(key2));
      expect(key3, isNot(key1),
          reason: '커버리지는 phase1과 같아 보여도 folderId(99 vs 3)/interval(5 vs 60)이 달라'
              ' 실제로는 다른 설정 — timingKey가 phase1과 우연히 같아지면 안 됨');

      // 라운드트립 안정성: phase3을 다시 encode/decode해도 그대로(PushRule은 ==를
      // 오버라이드하지 않으므로 encode() 문자열로 비교 — 필드값이 전부 같으면 같은
      // 문자열이 나온다).
      expect(PushSchedule.encode(PushSchedule.decode(PushSchedule.encode(phase3))),
          PushSchedule.encode(phase3));
    });
  });
}
