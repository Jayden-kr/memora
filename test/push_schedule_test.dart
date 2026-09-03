// PushSchedule(푸시 알림 시간대별 폴더·주기 자동 전환)의
// decode/encode/어댑터 로직 검증.
//
// 드롭 규칙 스펙(android/app/src/main/kotlin/com/henry/memora/PushSchedule.kt의
// parse()와 반드시 동일):
// - 토큰이 ':' 기준 3개 또는 4개로 안 쪼개지면 드롭
// - start/end가 0..1439 범위 밖이면 드롭
// - start == end면 드롭
// - folderId < 0이면 드롭
// - intervalMin이 5..1440 범위 밖(숫자가 아닌 경우 포함)이면 드롭하지 않고
//   PushSchedule.inherit(0)으로 강등한다
// - 3필드 토큰(간격 생략)은 intervalMin=inherit으로 관대하게 수용
// - start 오름차순 정렬 후 최대 maxSlots(5)개로 컷(가장 이른 시작들만 유지)
// - 어떤 입력에도 절대 throw하지 않는다
//
// 테스트 대상:
// 1. decode — 드롭 규칙 개별 검증 + 3필드 관대수용 + interval 강등(드롭 아님)
// 2. encode/decode 라운드트립, 4필드 고정
// 3. maxSlots == 5
// 4. overlappingIndices/effectiveRanges 어댑터 — LockScreenSchedule 위임이
//    1440분 브루트포스와 일치하는지
// 5. outsideWindowIndices — 마스터(양끝포함) × 슬롯(반열림) overnight 4조합 전수
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:memora/services/push_schedule.dart';

// ─── 브루트포스 기준(스펙 그 자체) ───

bool _covers(PushSlot slot, int minute) {
  if (slot.start < slot.end) {
    return minute >= slot.start && minute < slot.end;
  }
  if (slot.start > slot.end) {
    return minute >= slot.start || minute < slot.end;
  }
  return false;
}

/// 마스터 활성시간창(양끝 포함, overnight 지원)이 분 [minute]을 포함하는지 —
/// PushNotificationService.kt fireIfInRange()와 동일한 의미론의 브루트포스 기준.
bool _masterContains(int startTotal, int endTotal, int minute) {
  if (startTotal <= endTotal) {
    return minute >= startTotal && minute <= endTotal;
  }
  return minute >= startTotal || minute <= endTotal;
}

bool _bruteForceOverlaps(PushSlot a, PushSlot b) {
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

    test('folderId < 0 이면 드롭', () {
      expect(PushSchedule.decode('540:1080:-1:10'), isEmpty);
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

    test('5개 초과 시 정렬 후 앞의 5개(가장 이른 시작)만 유지', () {
      final all = List.generate(
          10,
          (i) => PushSlot(
              start: i * 100,
              end: i * 100 + 10,
              folderId: i,
              intervalMin: 10));
      final shuffled = List<PushSlot>.from(all)..shuffle(Random(42));
      final csv = shuffled
          .map((s) => '${s.start}:${s.end}:${s.folderId}:${s.intervalMin}')
          .join(',');

      final decoded = PushSchedule.decode(csv);

      expect(decoded, hasLength(PushSchedule.maxSlots));
      for (var i = 1; i < decoded.length; i++) {
        expect(decoded[i].start, greaterThanOrEqualTo(decoded[i - 1].start));
      }
      final keptStarts = decoded.map((s) => s.start).toSet();
      final expectedStarts = List.generate(5, (i) => i * 100).toSet();
      expect(keptStarts, expectedStarts);
    });
  });

  group('decode — 3필드 관대 수용 + interval 강등(드롭 아님)', () {
    test('3필드 토큰(간격 생략)은 intervalMin=inherit(0)으로 수용', () {
      final result = PushSchedule.decode('540:600:3');
      expect(result, hasLength(1));
      expect(result.single.intervalMin, PushSchedule.inherit);
      expect(PushSchedule.inherit, 0);
    });

    test('간격이 5 미만이면 슬롯을 드롭하지 않고 inherit으로 강등', () {
      final result = PushSchedule.decode('540:600:3:4');
      expect(result, hasLength(1));
      expect(result.single.intervalMin, PushSchedule.inherit);
    });

    test('간격이 1440 초과면 슬롯을 드롭하지 않고 inherit으로 강등', () {
      final result = PushSchedule.decode('540:600:3:1441');
      expect(result, hasLength(1));
      expect(result.single.intervalMin, PushSchedule.inherit);
    });

    test('간격이 음수여도 슬롯을 드롭하지 않고 inherit으로 강등', () {
      final result = PushSchedule.decode('540:600:3:-5');
      expect(result, hasLength(1));
      expect(result.single.intervalMin, PushSchedule.inherit);
    });

    test('간격이 숫자가 아니어도 슬롯을 드롭하지 않고 inherit으로 강등', () {
      final result = PushSchedule.decode('540:600:3:abc');
      expect(result, hasLength(1));
      expect(result.single.intervalMin, PushSchedule.inherit);
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
    test('유효한 슬롯 목록은 encode 후 decode하면 그대로 복원됨', () {
      final slots = [
        PushSlot(start: 540, end: 1080, folderId: 3, intervalMin: 15),
        PushSlot(
            start: 1080, end: 1380, folderId: 7, intervalMin: PushSchedule.inherit),
        PushSlot(start: 1320, end: 120, folderId: 9, intervalMin: 60),
      ];
      final csv = PushSchedule.encode(slots);
      expect(csv, '540:1080:3:15,1080:1380:7:0,1320:120:9:60');
      final decoded = PushSchedule.decode(csv);

      expect(decoded, hasLength(slots.length));
      for (var i = 0; i < slots.length; i++) {
        expect(decoded[i].start, slots[i].start);
        expect(decoded[i].end, slots[i].end);
        expect(decoded[i].folderId, slots[i].folderId);
        expect(decoded[i].intervalMin, slots[i].intervalMin);
      }
    });

    test('빈 목록은 빈 문자열로 encode되고, 빈 문자열은 빈 목록으로 decode됨', () {
      expect(PushSchedule.encode(const []), '');
      expect(PushSchedule.decode(''), isEmpty);
    });

    test('encode는 간격 생략 없이 항상 4필드로 씀', () {
      final csv = PushSchedule.encode(
          [const PushSlot(start: 540, end: 600, folderId: 3)]);
      expect(csv, '540:600:3:0');
      expect(csv.split(':'), hasLength(4));
    });

    test('maxSlots는 5', () {
      expect(PushSchedule.maxSlots, 5);
    });
  });

  group('overlappingIndices 어댑터 — LockScreenSchedule 위임 검증(브루트포스 대조)', () {
    Set<int> bruteForceIndices(List<PushSlot> slots) {
      final result = <int>{};
      for (var i = 0; i < slots.length; i++) {
        for (var j = i + 1; j < slots.length; j++) {
          if (_bruteForceOverlaps(slots[i], slots[j])) {
            result.add(i);
            result.add(j);
          }
        }
      }
      return result;
    }

    test('겹치는 슬롯이 하나도 없으면 빈 집합', () {
      final slots = [
        const PushSlot(start: 0, end: 480, folderId: 1),
        const PushSlot(start: 540, end: 1080, folderId: 2),
        const PushSlot(start: 1080, end: 1380, folderId: 3),
      ];
      expect(PushSchedule.overlappingIndices(slots), bruteForceIndices(slots));
      expect(PushSchedule.overlappingIndices(slots), isEmpty);
    });

    test('세 슬롯 중 두 개만 겹치면 그 두 인덱스만 포함', () {
      final slots = [
        const PushSlot(start: 540, end: 1080, folderId: 1),
        const PushSlot(start: 1000, end: 1200, folderId: 2),
        const PushSlot(start: 1200, end: 1300, folderId: 3),
      ];
      expect(PushSchedule.overlappingIndices(slots), bruteForceIndices(slots));
      expect(PushSchedule.overlappingIndices(slots), {0, 1});
    });

    test('자정 교차 슬롯이 섞인 목록', () {
      final slots = [
        const PushSlot(start: 1320, end: 120, folderId: 1),
        const PushSlot(start: 30, end: 60, folderId: 2),
        const PushSlot(start: 540, end: 1080, folderId: 3),
      ];
      expect(PushSchedule.overlappingIndices(slots), bruteForceIndices(slots));
      expect(PushSchedule.overlappingIndices(slots), {0, 1});
    });
  });

  group('effectiveRanges 어댑터 — 1440분 전수 크로스체크', () {
    int? firstMatchOwner(List<PushSlot> slots, int minute) {
      for (var i = 0; i < slots.length; i++) {
        if (_covers(slots[i], minute)) return i;
      }
      return null;
    }

    bool inRanges(List<List<int>> ranges, int minute) {
      for (final r in ranges) {
        final pseudo = PushSlot(start: r[0], end: r[1], folderId: 0);
        if (_covers(pseudo, minute)) return true;
      }
      return false;
    }

    void crossCheck(String description, List<PushSlot> slots) {
      test(description, () {
        final ranges = PushSchedule.effectiveRanges(slots);
        expect(ranges, hasLength(slots.length));
        for (var m = 0; m < 1440; m++) {
          final owner = firstMatchOwner(slots, m);
          for (var i = 0; i < slots.length; i++) {
            final covered = inRanges(ranges[i], m);
            expect(covered, i == owner,
                reason: '$description: 분 $m owner=$owner slot=$i');
          }
        }
      });
    }

    crossCheck('겹치지 않는 슬롯들', [
      const PushSlot(start: 0, end: 480, folderId: 1),
      const PushSlot(start: 540, end: 1080, folderId: 2),
      const PushSlot(start: 1080, end: 1380, folderId: 3),
    ]);

    crossCheck('완전히 가려진 슬롯(죽은 슬롯)', [
      const PushSlot(start: 1171, end: 1411, folderId: 1),
      const PushSlot(start: 1296, end: 1346, folderId: 2),
    ]);

    crossCheck('자정 랩 + 부분 가려짐', [
      const PushSlot(start: 1300, end: 1400, folderId: 1),
      const PushSlot(start: 1320, end: 120, folderId: 2),
    ]);

    test('무작위 슬롯 5개 스트레스(시드 고정, maxSlots 한도 안에서)', () {
      for (final seed in [1, 7, 42]) {
        final rand = Random(seed);
        final slots = List.generate(5, (i) {
          final start = rand.nextInt(1440);
          var end = rand.nextInt(1440);
          if (end == start) end = (end + 1) % 1440;
          return PushSlot(start: start, end: end, folderId: i);
        });
        final ranges = PushSchedule.effectiveRanges(slots);
        expect(ranges, hasLength(slots.length));
        for (var m = 0; m < 1440; m++) {
          final owner = firstMatchOwner(slots, m);
          for (var i = 0; i < slots.length; i++) {
            expect(inRanges(ranges[i], m), i == owner,
                reason: 'seed=$seed 분 $m 슬롯 $i (owner=$owner)');
          }
        }
      }
    });
  });

  group('outsideWindowIndices — 마스터(양끝포함) × 슬롯(반열림) overnight 4조합 전수', () {
    // 4조합: (마스터 일반, 마스터 overnight) × (슬롯 일반, 슬롯 overnight)

    test('마스터 일반 구간 × 슬롯 일반 구간 — 창 안이면 포함되지 않음', () {
      final slots = [const PushSlot(start: 600, end: 700, folderId: 1)]; // 안
      expect(PushSchedule.outsideWindowIndices(slots, 540, 1320), isEmpty);
    });

    test('마스터 일반 구간 × 슬롯 일반 구간 — 창 밖이면 포함됨', () {
      final slots = [const PushSlot(start: 0, end: 60, folderId: 1)]; // 00:00-01:00
      // 마스터 09:00~22:00 과 전혀 안 겹침
      expect(PushSchedule.outsideWindowIndices(slots, 540, 1320), {0});
    });

    test('마스터 일반 구간의 경계(양끝 포함)에 슬롯이 걸치면 창 안으로 판정', () {
      // 마스터 [540,1320] 양끝 포함. 슬롯이 539..541처럼 경계 1분만 걸쳐도 겹침.
      final slots = [const PushSlot(start: 539, end: 541, folderId: 1)];
      expect(PushSchedule.outsideWindowIndices(slots, 540, 1320), isEmpty);
    });

    test('마스터 overnight(자정 교차) × 슬롯 일반 구간 — 겹치면 창 안', () {
      // 마스터 22:00~06:00(overnight). 슬롯 23:00-23:30은 창 안.
      final slots = [const PushSlot(start: 1380, end: 1410, folderId: 1)];
      expect(PushSchedule.outsideWindowIndices(slots, 1320, 360), isEmpty);
    });

    test('마스터 overnight(자정 교차) × 슬롯 일반 구간 — 안 겹치면 창 밖', () {
      // 마스터 22:00~06:00. 슬롯 12:00-13:00은 낮이라 안 겹침.
      final slots = [const PushSlot(start: 720, end: 780, folderId: 1)];
      expect(PushSchedule.outsideWindowIndices(slots, 1320, 360), {0});
    });

    test('마스터 일반 구간 × 슬롯 overnight — 겹치는 조각이 있으면 창 안', () {
      // 마스터 09:00~22:00. 슬롯 21:00~02:00(overnight)은 21:00~22:00이 창과 겹침.
      final slots = [const PushSlot(start: 1260, end: 120, folderId: 1)];
      expect(PushSchedule.outsideWindowIndices(slots, 540, 1320), isEmpty);
    });

    test('마스터 일반 구간 × 슬롯 overnight — 전혀 안 겹치면 창 밖', () {
      // 마스터 09:00~17:00(540~1020). 슬롯 22:00~02:00(overnight)은 전혀 안 겹침.
      final slots = [const PushSlot(start: 1320, end: 120, folderId: 1)];
      expect(PushSchedule.outsideWindowIndices(slots, 540, 1020), {0});
    });

    test('마스터 overnight × 슬롯 overnight — 겹치면 창 안', () {
      // 마스터 22:00~06:00. 슬롯 23:00~03:00(overnight)도 겹침.
      final slots = [const PushSlot(start: 1380, end: 180, folderId: 1)];
      expect(PushSchedule.outsideWindowIndices(slots, 1320, 360), isEmpty);
    });

    test('마스터 overnight × 슬롯 overnight — 안 겹치면 창 밖', () {
      // 마스터 23:50~00:10(1430~10, 20분짜리 좁은 overnight).
      // 슬롯 12:00~13:00은 낮 시간이라 안 겹침(일반 구간이지만 대조를 위해 포함).
      final slots = [const PushSlot(start: 720, end: 780, folderId: 1)];
      expect(PushSchedule.outsideWindowIndices(slots, 1430, 10), {0});
    });

    test('여러 슬롯 중 일부만 창 밖', () {
      final slots = [
        const PushSlot(start: 600, end: 700, folderId: 1), // 창 안(09:00-22:00)
        const PushSlot(start: 0, end: 60, folderId: 2), // 창 밖
        const PushSlot(start: 1330, end: 1340, folderId: 3), // 창 밖
      ];
      expect(PushSchedule.outsideWindowIndices(slots, 540, 1320), {1, 2});
    });

    test('빈 슬롯 목록은 빈 집합', () {
      expect(PushSchedule.outsideWindowIndices(const [], 540, 1320), isEmpty);
    });

    // 위의 개별 케이스들을 브루트포스(1440분 전수) 기준과 교차검증 — _masterContains를
    // 실제로 행사해 마스터 창 판정 자체가 스펙과 일치하는지도 함께 확인한다.
    Set<int> bruteForceOutside(
        List<PushSlot> slots, int startTotal, int endTotal) {
      final result = <int>{};
      for (var i = 0; i < slots.length; i++) {
        var overlaps = false;
        for (var m = 0; m < 1440; m++) {
          if (_covers(slots[i], m) && _masterContains(startTotal, endTotal, m)) {
            overlaps = true;
            break;
          }
        }
        if (!overlaps) result.add(i);
      }
      return result;
    }

    void crossCheckOutside(
        String description, List<PushSlot> slots, int startTotal, int endTotal) {
      test(description, () {
        expect(
          PushSchedule.outsideWindowIndices(slots, startTotal, endTotal),
          bruteForceOutside(slots, startTotal, endTotal),
        );
      });
    }

    crossCheckOutside('브루트포스 대조: 마스터 일반 × 슬롯 일반', [
      const PushSlot(start: 600, end: 700, folderId: 1),
      const PushSlot(start: 0, end: 60, folderId: 2),
    ], 540, 1320);

    crossCheckOutside('브루트포스 대조: 마스터 overnight × 슬롯 overnight', [
      const PushSlot(start: 1380, end: 180, folderId: 1),
      const PushSlot(start: 700, end: 800, folderId: 2),
    ], 1320, 360);

    test('무작위 슬롯 5개 × 무작위 마스터 창 스트레스(시드 고정)', () {
      for (final seed in [3, 11, 99]) {
        final rand = Random(seed);
        final slots = List.generate(5, (i) {
          final start = rand.nextInt(1440);
          var end = rand.nextInt(1440);
          if (end == start) end = (end + 1) % 1440;
          return PushSlot(start: start, end: end, folderId: i);
        });
        final startTotal = rand.nextInt(1440);
        var endTotal = rand.nextInt(1440);
        expect(
          PushSchedule.outsideWindowIndices(slots, startTotal, endTotal),
          bruteForceOutside(slots, startTotal, endTotal),
          reason: 'seed=$seed startTotal=$startTotal endTotal=$endTotal',
        );
      }
    });
  });

  group('음성 대조군 (negative control)', () {
    // decode의 start==end 드롭 규칙을 일시적으로 주석 처리하면(무력화 실험) 아래
    // 테스트가 실패한다는 것을 문서화 — 실제로 push_schedule.dart의
    // `if (start == end) continue;` 를 지우고 이 테스트가
    //   Expected: empty
    //   Actual: [Instance of 'PushSlot']
    // 로 실패하는 것을 확인한 뒤 원상 복구했다.
    test('start==end 드롭 규칙이 실제로 뭔가를 검증하고 있음을 남겨두는 문서화 테스트', () {
      expect(PushSchedule.decode('700:700:1:10'), isEmpty);
    });

    // interval 강등 규칙 무력화 실험: `if (raw != null && raw >= 5 && raw <= 1440)`
    // 가드를 없애면(= 범위 밖 interval을 그대로 채택) 아래 테스트가
    //   Expected: <0>
    //   Actual: <9999>
    // 로 실패한다.
    test('간격 강등 규칙이 실제로 뭔가를 검증하고 있음을 남겨두는 문서화 테스트', () {
      expect(PushSchedule.decode('540:600:3:9999').single.intervalMin,
          PushSchedule.inherit);
    });
  });
}
