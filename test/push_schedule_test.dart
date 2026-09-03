// PushSchedule(푸시 알림 시간대 규칙 목록)의 decode/encode/어댑터 로직 검증.
//
// v1.3.9 재설계: 마스터 활성시간창·전역 폴더·전역 인터벌·inherit sentinel이 전부
// 사라졌다 — 어떤 규칙에도 걸리지 않는 시각엔 알림이 안 온다(의도적 동작 변경).
//
// 드롭 규칙 스펙(android/app/src/main/kotlin/com/henry/memora/PushSchedule.kt의
// parse()와 반드시 동일):
// - 토큰이 ':' 기준 3개 또는 4개로 안 쪼개지면 드롭
// - start/end가 0..1439 범위 밖이면 드롭
// - start == end면 드롭
// - folderId < -1이면 드롭 (-1 = 전체 폴더는 허용)
// - intervalMin이 5..1440 범위 밖(파싱 실패·누락·0 포함)이면 드롭하지 않고
//   PushSchedule.defaultIntervalMin(30)으로 강등한다
// - 3필드 토큰(간격 생략)도 동일하게 30으로 채운다
// - start 오름차순 정렬 후 최대 maxRules(12)개로 컷(가장 이른 시작들만 유지)
// - 어떤 입력에도 절대 throw하지 않는다
//
// 테스트 대상:
// 1. decode — 드롭 규칙 개별 검증 + 3필드 관대수용 + interval 강등(드롭 아님)
// 2. encode/decode 라운드트립, 4필드 고정
// 3. maxRules == 12
// 4. overlappingIndices/effectiveRanges 어댑터 — LockScreenSchedule 위임이
//    1440분 브루트포스와 일치하는지
// 5. activeRule — effectiveRanges가 만드는 소유권과 1440분 전수 일치
// 6. gapRanges — 커버리지+gap 합이 1440, 자정랩 병합
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:memora/services/push_schedule.dart';

// ─── 브루트포스 기준(스펙 그 자체) ───

bool _covers(PushRule rule, int minute) {
  if (rule.start < rule.end) {
    return minute >= rule.start && minute < rule.end;
  }
  if (rule.start > rule.end) {
    return minute >= rule.start || minute < rule.end;
  }
  return false;
}

bool _bruteForceOverlaps(PushRule a, PushRule b) {
  for (var m = 0; m < 1440; m++) {
    if (_covers(a, m) && _covers(b, m)) return true;
  }
  return false;
}

void main() {
  group('decode — 드롭 규칙 개별 검증', () {
    test('start == end 이면 드롭', () {
      expect(PushSchedule.decode('540:540:3:10'), isEmpty);
    });

    test('start < 0 이면 드롭', () {
      expect(PushSchedule.decode('-1:100:3:10'), isEmpty);
    });

    test('start > 1439 이면 드롭', () {
      expect(PushSchedule.decode('1440:100:3:10'), isEmpty);
    });

    test('end < 0 이면 드롭', () {
      expect(PushSchedule.decode('100:-1:3:10'), isEmpty);
    });

    test('end > 1439 이면 드롭 (1440은 범위 밖)', () {
      expect(PushSchedule.decode('100:1440:3:10'), isEmpty);
    });

    test('folderId < -1 이면 드롭', () {
      expect(PushSchedule.decode('540:1080:-2:10'), isEmpty);
    });

    test('folderId == -1 은 전체 폴더로 유효(드롭 대상 아님)', () {
      final result = PushSchedule.decode('540:1080:-1:10');
      expect(result, hasLength(1));
      expect(result.single.folderId, PushSchedule.allFolders);
    });

    test('folderId == 0 은 유효(드롭 대상 아님)', () {
      final result = PushSchedule.decode('540:1080:0:10');
      expect(result, hasLength(1));
      expect(result.single.folderId, 0);
    });

    test('숫자가 아닌 토큰(start/end/folderId)이 섞이면 드롭', () {
      expect(PushSchedule.decode('abc:1080:3:10'), isEmpty);
      expect(PushSchedule.decode('540:abc:3:10'), isEmpty);
      expect(PushSchedule.decode('540:1080:abc:10'), isEmpty);
    });

    test("':' 기준 2개 토큰이면 드롭 (3개도 4개도 아님)", () {
      expect(PushSchedule.decode('540:1080'), isEmpty);
    });

    test("':' 기준 5개 토큰이면 드롭 (3개도 4개도 아님)", () {
      expect(PushSchedule.decode('540:1080:3:10:99'), isEmpty);
    });

    test('trailing comma는 빈 토큰을 만들고, 빈 토큰은 드롭 — 나머지는 살아남음', () {
      final result = PushSchedule.decode('540:1080:3:10,');
      expect(result, hasLength(1));
      expect(result.single.start, 540);
    });

    test('빈 문자열("")은 빈 리스트', () {
      expect(PushSchedule.decode(''), isEmpty);
    });

    test('null은 빈 리스트', () {
      expect(PushSchedule.decode(null), isEmpty);
    });

    test('숫자 주변 공백은 trim되어 허용됨', () {
      final result = PushSchedule.decode(' 540 : 1080 : 3 : 10 ');
      expect(result, hasLength(1));
      expect(result.single.start, 540);
      expect(result.single.end, 1080);
      expect(result.single.folderId, 3);
      expect(result.single.intervalMin, 10);
    });

    test('start 기준 오름차순으로 정렬됨', () {
      final result =
          PushSchedule.decode('600:700:1:10,100:200:2:10,900:1000:3:10');
      expect(result.map((s) => s.start).toList(), [100, 600, 900]);
    });

    test('12개 초과 시 정렬 후 앞의 12개(가장 이른 시작)만 유지', () {
      final all = List.generate(
          20,
          (i) => PushRule(
              start: i * 60,
              end: i * 60 + 10,
              folderId: i,
              intervalMin: 10));
      final shuffled = List<PushRule>.from(all)..shuffle(Random(42));
      final csv = shuffled
          .map((s) => '${s.start}:${s.end}:${s.folderId}:${s.intervalMin}')
          .join(',');

      final decoded = PushSchedule.decode(csv);

      expect(decoded, hasLength(PushSchedule.maxRules));
      for (var i = 1; i < decoded.length; i++) {
        expect(decoded[i].start, greaterThanOrEqualTo(decoded[i - 1].start));
      }
      final keptStarts = decoded.map((s) => s.start).toSet();
      final expectedStarts = List.generate(12, (i) => i * 60).toSet();
      expect(keptStarts, expectedStarts);
    });
  });

  group('decode — 3필드 관대 수용 + interval 강등(드롭 아님)', () {
    test('3필드 토큰(간격 생략)은 intervalMin=defaultIntervalMin(30)으로 수용', () {
      final result = PushSchedule.decode('540:600:3');
      expect(result, hasLength(1));
      expect(result.single.intervalMin, PushSchedule.defaultIntervalMin);
      expect(PushSchedule.defaultIntervalMin, 30);
    });

    test('간격이 0이면 슬롯을 드롭하지 않고 defaultIntervalMin으로 강등', () {
      final result = PushSchedule.decode('540:600:3:0');
      expect(result, hasLength(1));
      expect(result.single.intervalMin, PushSchedule.defaultIntervalMin);
    });

    test('간격이 5 미만이면 슬롯을 드롭하지 않고 defaultIntervalMin으로 강등', () {
      final result = PushSchedule.decode('540:600:3:4');
      expect(result, hasLength(1));
      expect(result.single.intervalMin, PushSchedule.defaultIntervalMin);
    });

    test('간격이 1440 초과면 슬롯을 드롭하지 않고 defaultIntervalMin으로 강등', () {
      final result = PushSchedule.decode('540:600:3:1441');
      expect(result, hasLength(1));
      expect(result.single.intervalMin, PushSchedule.defaultIntervalMin);
    });

    test('간격이 음수여도 슬롯을 드롭하지 않고 defaultIntervalMin으로 강등', () {
      final result = PushSchedule.decode('540:600:3:-5');
      expect(result, hasLength(1));
      expect(result.single.intervalMin, PushSchedule.defaultIntervalMin);
    });

    test('간격이 숫자가 아니어도 슬롯을 드롭하지 않고 defaultIntervalMin으로 강등', () {
      final result = PushSchedule.decode('540:600:3:abc');
      expect(result, hasLength(1));
      expect(result.single.intervalMin, PushSchedule.defaultIntervalMin);
    });

    test('간격 경계값 5와 1440은 유효(포함)', () {
      expect(PushSchedule.decode('540:600:3:5').single.intervalMin, 5);
      expect(PushSchedule.decode('540:600:3:1440').single.intervalMin, 1440);
    });
  });

  group('decode — 절대 throw 하지 않음', () {
    test('쓰레기/잘린 입력 배치를 던져도 예외 없이 항상 리스트를 반환', () {
      const garbageInputs = <String>[
        '',
        ',',
        ':::',
        '::',
        'abc',
        'abc:def:ghi',
        '540',
        '540:1080',
        '540:1080:3:4:5',
        '540:1080:3,',
        ',540:1080:3',
        '540:1080:3,,540:1080:3',
        '99999999999999999999999999999:1080:3:10',
        '-1:-1:-1:-1',
        '1440:1440:1440:1440',
        'NaN:NaN:NaN:NaN',
        '  :  :  :  ',
        '540:1080:3:',
        '540::3:10',
        ':1080:3:10',
        '540:1080::10',
        '   ',
        '가:나:다:라',
        '540.5:1080:3:10',
      ];

      for (final garbage in garbageInputs) {
        expect(() => PushSchedule.decode(garbage), returnsNormally,
            reason: 'input: "$garbage"');
      }
      expect(() => PushSchedule.decode(null), returnsNormally);
    });
  });

  group('encode/decode 라운드트립', () {
    test('유효한 규칙 목록은 encode 후 decode하면 그대로 복원됨', () {
      final rules = [
        PushRule(start: 540, end: 1080, folderId: 3, intervalMin: 15),
        PushRule(start: 1080, end: 1380, folderId: 7, intervalMin: 30),
        PushRule(
            start: 1320,
            end: 120,
            folderId: PushSchedule.allFolders,
            intervalMin: 60),
      ];
      final csv = PushSchedule.encode(rules);
      expect(csv, '540:1080:3:15,1080:1380:7:30,1320:120:-1:60');
      final decoded = PushSchedule.decode(csv);

      expect(decoded, hasLength(rules.length));
      for (var i = 0; i < rules.length; i++) {
        expect(decoded[i].start, rules[i].start);
        expect(decoded[i].end, rules[i].end);
        expect(decoded[i].folderId, rules[i].folderId);
        expect(decoded[i].intervalMin, rules[i].intervalMin);
      }
    });

    test('빈 목록은 빈 문자열로 encode되고, 빈 문자열은 빈 목록으로 decode됨', () {
      expect(PushSchedule.encode(const []), '');
      expect(PushSchedule.decode(''), isEmpty);
    });

    test('encode는 간격 생략 없이 항상 4필드로 씀', () {
      final csv = PushSchedule.encode(
          [const PushRule(start: 540, end: 600, folderId: 3, intervalMin: 30)]);
      expect(csv, '540:600:3:30');
      expect(csv.split(':'), hasLength(4));
    });

    test('maxRules는 12', () {
      expect(PushSchedule.maxRules, 12);
    });
  });

  group('overlappingIndices 어댑터 — LockScreenSchedule 위임 검증(브루트포스 대조)', () {
    Set<int> bruteForceIndices(List<PushRule> rules) {
      final result = <int>{};
      for (var i = 0; i < rules.length; i++) {
        for (var j = i + 1; j < rules.length; j++) {
          if (_bruteForceOverlaps(rules[i], rules[j])) {
            result.add(i);
            result.add(j);
          }
        }
      }
      return result;
    }

    test('겹치는 규칙이 하나도 없으면 빈 집합', () {
      final rules = [
        const PushRule(start: 0, end: 480, folderId: 1, intervalMin: 30),
        const PushRule(start: 540, end: 1080, folderId: 2, intervalMin: 30),
        const PushRule(start: 1080, end: 1380, folderId: 3, intervalMin: 30),
      ];
      expect(PushSchedule.overlappingIndices(rules), bruteForceIndices(rules));
      expect(PushSchedule.overlappingIndices(rules), isEmpty);
    });

    test('세 규칙 중 두 개만 겹치면 그 두 인덱스만 포함', () {
      final rules = [
        const PushRule(start: 540, end: 1080, folderId: 1, intervalMin: 30),
        const PushRule(start: 1000, end: 1200, folderId: 2, intervalMin: 30),
        const PushRule(start: 1200, end: 1300, folderId: 3, intervalMin: 30),
      ];
      expect(PushSchedule.overlappingIndices(rules), bruteForceIndices(rules));
      expect(PushSchedule.overlappingIndices(rules), {0, 1});
    });

    test('자정 교차 규칙이 섞인 목록', () {
      final rules = [
        const PushRule(start: 1320, end: 120, folderId: 1, intervalMin: 30),
        const PushRule(start: 30, end: 60, folderId: 2, intervalMin: 30),
        const PushRule(start: 540, end: 1080, folderId: 3, intervalMin: 30),
      ];
      expect(PushSchedule.overlappingIndices(rules), bruteForceIndices(rules));
      expect(PushSchedule.overlappingIndices(rules), {0, 1});
    });

    test('folderId == allFolders(-1)여도 겹침 판정은 시간만 본다', () {
      final rules = [
        const PushRule(
            start: 540, end: 700, folderId: -1, intervalMin: 30),
        const PushRule(start: 600, end: 800, folderId: 2, intervalMin: 30),
      ];
      expect(PushSchedule.overlappingIndices(rules), {0, 1});
    });
  });

  group('effectiveRanges 어댑터 — 1440분 전수 크로스체크', () {
    int? firstMatchOwner(List<PushRule> rules, int minute) {
      for (var i = 0; i < rules.length; i++) {
        if (_covers(rules[i], minute)) return i;
      }
      return null;
    }

    bool inRanges(List<List<int>> ranges, int minute) {
      for (final r in ranges) {
        final pseudo =
            PushRule(start: r[0], end: r[1], folderId: 0, intervalMin: 30);
        if (_covers(pseudo, minute)) return true;
      }
      return false;
    }

    void crossCheck(String description, List<PushRule> rules) {
      test(description, () {
        final ranges = PushSchedule.effectiveRanges(rules);
        expect(ranges, hasLength(rules.length));
        for (var m = 0; m < 1440; m++) {
          final owner = firstMatchOwner(rules, m);
          for (var i = 0; i < rules.length; i++) {
            final covered = inRanges(ranges[i], m);
            expect(covered, i == owner,
                reason: '$description: 분 $m owner=$owner rule=$i');
          }
        }
      });
    }

    crossCheck('겹치지 않는 규칙들', [
      const PushRule(start: 0, end: 480, folderId: 1, intervalMin: 30),
      const PushRule(start: 540, end: 1080, folderId: 2, intervalMin: 30),
      const PushRule(start: 1080, end: 1380, folderId: 3, intervalMin: 30),
    ]);

    crossCheck('완전히 가려진 규칙(죽은 규칙)', [
      const PushRule(start: 1171, end: 1411, folderId: 1, intervalMin: 30),
      const PushRule(start: 1296, end: 1346, folderId: 2, intervalMin: 30),
    ]);

    crossCheck('자정 랩 + 부분 가려짐', [
      const PushRule(start: 1300, end: 1400, folderId: 1, intervalMin: 30),
      const PushRule(start: 1320, end: 120, folderId: 2, intervalMin: 30),
    ]);

    test('무작위 규칙 5개 스트레스(시드 고정, maxRules 한도 안에서)', () {
      for (final seed in [1, 7, 42]) {
        final rand = Random(seed);
        final rules = List.generate(5, (i) {
          final start = rand.nextInt(1440);
          var end = rand.nextInt(1440);
          if (end == start) end = (end + 1) % 1440;
          return PushRule(start: start, end: end, folderId: i, intervalMin: 30);
        });
        final ranges = PushSchedule.effectiveRanges(rules);
        expect(ranges, hasLength(rules.length));
        for (var m = 0; m < 1440; m++) {
          final owner = firstMatchOwner(rules, m);
          for (var i = 0; i < rules.length; i++) {
            expect(inRanges(ranges[i], m), i == owner,
                reason: 'seed=$seed 분 $m 규칙 $i (owner=$owner)');
          }
        }
      }
    });
  });

  group('activeRule — effectiveRanges 소유권과 1440분 전수 일치', () {
    test('activeRule이 가리키는 규칙 == effectiveRanges가 그 분을 소유한 규칙', () {
      for (final seed in [3, 11, 99, 123, 456]) {
        final rand = Random(seed);
        final rules = List.generate(5, (i) {
          final start = rand.nextInt(1440);
          var end = rand.nextInt(1440);
          if (end == start) end = (end + 1) % 1440;
          return PushRule(
              start: start,
              end: end,
              folderId: i,
              intervalMin: 30);
        });
        final ranges = PushSchedule.effectiveRanges(rules);
        for (var m = 0; m < 1440; m++) {
          final active = PushSchedule.activeRule(m, rules);
          if (active == null) {
            for (var i = 0; i < rules.length; i++) {
              expect(_inRangeList(ranges[i], m), isFalse,
                  reason: 'seed=$seed m=$m: activeRule null인데 rule $i가 소유');
            }
          } else {
            final activeIndex = rules.indexOf(active);
            for (var i = 0; i < rules.length; i++) {
              expect(_inRangeList(ranges[i], m), i == activeIndex,
                  reason: 'seed=$seed m=$m: activeIndex=$activeIndex rule=$i');
            }
          }
        }
      }
    });

    test('빈 목록에서는 항상 null', () {
      expect(PushSchedule.activeRule(0, const []), isNull);
      expect(PushSchedule.activeRule(1000, const []), isNull);
    });
  });

  group('gapRanges — 커버리지+gap 합이 1440, 자정랩 병합', () {
    int totalMinutes(List<List<int>> ranges) {
      var total = 0;
      for (final r in ranges) {
        if (r[0] < r[1]) {
          total += r[1] - r[0];
        } else if (r[0] > r[1]) {
          total += (1440 - r[0]) + r[1];
        }
        // r[0] == r[1] (둘 다 0): 0분짜리가 아니라 "하루 전체"를 뜻하는 특수
        // 표기이므로 아래 개별 테스트에서 별도로 처리한다.
      }
      return total;
    }

    test('규칙이 없으면 하루 전체가 gap([[0, 0]] = 전체 wrap)', () {
      final gaps = PushSchedule.gapRanges(const []);
      expect(gaps, [
        [0, 0]
      ]);
    });

    test('하루를 완전히 커버하면 gap 없음', () {
      final rules = [
        const PushRule(start: 0, end: 720, folderId: 1, intervalMin: 30),
        const PushRule(start: 720, end: 0, folderId: 2, intervalMin: 30),
      ];
      expect(PushSchedule.gapRanges(rules), isEmpty);
    });

    test('커버 구간 + gap 구간 합이 1440분', () {
      for (final seed in [5, 13, 21]) {
        final rand = Random(seed);
        final rules = List.generate(4, (i) {
          final start = rand.nextInt(1440);
          var end = rand.nextInt(1440);
          if (end == start) end = (end + 1) % 1440;
          return PushRule(start: start, end: end, folderId: i, intervalMin: 30);
        });
        final ranges = PushSchedule.effectiveRanges(rules);
        final covered =
            ranges.fold<int>(0, (sum, r) => sum + totalMinutes(r));
        final gaps = PushSchedule.gapRanges(rules);
        final gapMinutes = totalMinutes(gaps);
        expect(covered + gapMinutes, 1440,
            reason: 'seed=$seed covered=$covered gaps=$gaps');
      }
    });

    test('자정을 걸친 gap은 하나의 구간으로 병합된다', () {
      // 규칙 하나(10:00-18:00)만 있으면, 18:00~다음날10:00 gap이 자정을 걸쳐
      // 하나로 병합돼야 한다(둘로 쪼개지지 않음).
      final rules = [
        const PushRule(start: 600, end: 1080, folderId: 1, intervalMin: 30),
      ];
      final gaps = PushSchedule.gapRanges(rules);
      expect(gaps, hasLength(1));
      expect(gaps.single, [1080, 600]);
    });

    test('gapRanges가 반환한 모든 분은 실제로 activeRule==null이다(브루트포스 대조)', () {
      for (final seed in [2, 4, 6, 8]) {
        final rand = Random(seed);
        final rules = List.generate(3, (i) {
          final start = rand.nextInt(1440);
          var end = rand.nextInt(1440);
          if (end == start) end = (end + 1) % 1440;
          return PushRule(start: start, end: end, folderId: i, intervalMin: 30);
        });
        final gaps = PushSchedule.gapRanges(rules);
        for (var m = 0; m < 1440; m++) {
          final inGap = _inRangeList(gaps, m);
          final active = PushSchedule.activeRule(m, rules);
          expect(inGap, active == null,
              reason: 'seed=$seed m=$m active=$active gaps=$gaps');
        }
      }
    });
  });

  group('음성 대조군 (negative control)', () {
    // decode의 start==end 드롭 규칙을 일시적으로 주석 처리하면(무력화 실험) 아래
    // 테스트가 실패한다는 것을 문서화 — 실제로 push_schedule.dart의
    // `if (start == end) continue;` 를 지우고 이 테스트가
    //   Expected: empty
    //   Actual: [Instance of 'PushRule']
    // 로 실패하는 것을 확인한 뒤 원상 복구했다.
    test('start==end 드롭 규칙이 실제로 뭔가를 검증하고 있음을 남겨두는 문서화 테스트', () {
      expect(PushSchedule.decode('700:700:1:10'), isEmpty);
    });

    // interval 강등 규칙 무력화 실험: `if (raw != null && raw >= 5 && raw <= 1440)`
    // 가드를 없애면(= 범위 밖 interval을 그대로 채택) 아래 테스트가
    //   Expected: <30>
    //   Actual: <9999>
    // 로 실패한다.
    test('간격 강등 규칙이 실제로 뭔가를 검증하고 있음을 남겨두는 문서화 테스트', () {
      expect(PushSchedule.decode('540:600:3:9999').single.intervalMin,
          PushSchedule.defaultIntervalMin);
    });

    // folderId < -1 드롭 규칙 무력화 실험: `if (folderId < allFolders) continue;`를
    // `if (folderId < 0) continue;`로 되돌리면(= -1 이하 전체 드롭) 아래 테스트가
    //   Expected: 1
    //   Actual: 0
    // 로 실패한다(전체 폴더 -1이 드롭돼 리스트가 비게 되므로).
    test('folderId==-1 허용 규칙이 실제로 뭔가를 검증하고 있음을 남겨두는 문서화 테스트', () {
      expect(PushSchedule.decode('540:600:-1:10'), hasLength(1));
    });
  });
}

bool _inRangeList(List<List<int>> ranges, int minute) {
  for (final r in ranges) {
    if (r[0] < r[1]) {
      if (minute >= r[0] && minute < r[1]) return true;
    } else if (r[0] > r[1]) {
      if (minute >= r[0] || minute < r[1]) return true;
    } else {
      // r[0] == r[1] == 0: 하루 전체(모든 분)를 뜻하는 gapRanges의 특수 표기.
      return true;
    }
  }
  return false;
}
