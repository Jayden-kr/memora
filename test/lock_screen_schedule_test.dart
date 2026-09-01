// LockScreenSchedule(잠금화면 시간대별 폴더 자동 전환)의 decode/encode/overlap 로직 검증.
//
// 테스트 대상:
// 1. decode: scheduleCsv → List<LockScreenSlot>, 드롭 규칙이 FolderSchedule.kt
//    parse()와 반드시 일치해야 함(스펙은 이 파일의 상단 문서 주석 참고)
// 2. encode: List<LockScreenSlot> → scheduleCsv (decode의 역함수)
// 3. overlaps/overlappingIndices: 반열림 구간 [start, end) 겹침 판정
//    (start > end 인 자정 교차 슬롯 포함) — 1440분 전수 브루트포스가 스펙 그 자체
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:memora/services/lock_screen_service.dart';

// ─── 브루트포스 기준(스펙 그 자체) ───

/// 슬롯이 분 [minute](0..1439)을 커버하는지 판정.
/// start < end: 일반 구간 [start, end).
/// start > end: 자정을 넘는 구간 → [start, 1440) ∪ [0, end).
/// start == end: 커버 범위 없음(decode에서 이미 드롭되는 값이지만 방어적으로 정의).
bool _covers(LockScreenSlot slot, int minute) {
  if (slot.start < slot.end) {
    return minute >= slot.start && minute < slot.end;
  }
  if (slot.start > slot.end) {
    return minute >= slot.start || minute < slot.end;
  }
  return false;
}

/// 두 슬롯이 겹치는지 1440분을 전부 순회해 판정하는 브루트포스 기준.
bool _bruteForceOverlaps(LockScreenSlot a, LockScreenSlot b) {
  for (var m = 0; m < 1440; m++) {
    if (_covers(a, m) && _covers(b, m)) return true;
  }
  return false;
}

void main() {
  group('decode — 드롭 규칙 개별 검증', () {
    test('start == end 이면 드롭', () {
      expect(LockScreenSchedule.decode('540:540:3'), isEmpty);
    });

    test('start < 0 이면 드롭', () {
      expect(LockScreenSchedule.decode('-1:100:3'), isEmpty);
    });

    test('start > 1439 이면 드롭', () {
      expect(LockScreenSchedule.decode('1440:100:3'), isEmpty);
    });

    test('end < 0 이면 드롭', () {
      expect(LockScreenSchedule.decode('100:-1:3'), isEmpty);
    });

    test('end > 1439 이면 드롭 (1440은 범위 밖)', () {
      expect(LockScreenSchedule.decode('100:1440:3'), isEmpty);
    });

    test('folderId < 0 이면 드롭', () {
      expect(LockScreenSchedule.decode('540:1080:-1'), isEmpty);
    });

    test('folderId == 0 은 유효(드롭 대상 아님)', () {
      final result = LockScreenSchedule.decode('540:1080:0');
      expect(result, hasLength(1));
      expect(result.single.folderId, 0);
    });

    test('숫자가 아닌 토큰이 섞이면 드롭', () {
      expect(LockScreenSchedule.decode('abc:1080:3'), isEmpty);
      expect(LockScreenSchedule.decode('540:abc:3'), isEmpty);
      expect(LockScreenSchedule.decode('540:1080:abc'), isEmpty);
    });

    test("':' 기준 2개 토큰이면 드롭 (3개가 아님)", () {
      expect(LockScreenSchedule.decode('540:1080'), isEmpty);
    });

    test("':' 기준 4개 토큰이면 드롭 (3개가 아님)", () {
      expect(LockScreenSchedule.decode('540:1080:3:5'), isEmpty);
    });

    test('trailing comma는 빈 토큰을 만들고, 빈 토큰은 드롭 — 나머지는 살아남음', () {
      final result = LockScreenSchedule.decode('540:1080:3,');
      expect(result, hasLength(1));
      expect(result.single.start, 540);
    });

    test('빈 문자열("")은 빈 리스트', () {
      expect(LockScreenSchedule.decode(''), isEmpty);
    });

    test('null은 빈 리스트', () {
      expect(LockScreenSchedule.decode(null), isEmpty);
    });

    test('숫자 주변 공백은 trim되어 허용됨', () {
      final result = LockScreenSchedule.decode(' 540 : 1080 : 3 ');
      expect(result, hasLength(1));
      expect(result.single.start, 540);
      expect(result.single.end, 1080);
      expect(result.single.folderId, 3);
    });

    test('start 기준 오름차순으로 정렬됨', () {
      final result = LockScreenSchedule.decode('600:700:1,100:200:2,900:1000:3');
      expect(result.map((s) => s.start).toList(), [100, 600, 900]);
    });

    test('50개 초과 시 정렬 후 앞의 50개(가장 이른 시작)만 유지', () {
      // 60개의 겹치지 않는 유효한 슬롯을 무작위 순서로 CSV에 나열해
      // "토큰 순서상 앞의 50개"가 아니라 "정렬 후 시작이 가장 이른 50개"가
      // 남는지 확인한다.
      final all = List.generate(
          60, (i) => LockScreenSlot(start: i * 10, end: i * 10 + 5, folderId: i));
      final shuffled = List<LockScreenSlot>.from(all)..shuffle(Random(42));
      final csv =
          shuffled.map((s) => '${s.start}:${s.end}:${s.folderId}').join(',');

      final decoded = LockScreenSchedule.decode(csv);

      expect(decoded, hasLength(LockScreenSchedule.maxSlots));
      // 정렬 유지 확인
      for (var i = 1; i < decoded.length; i++) {
        expect(decoded[i].start, greaterThanOrEqualTo(decoded[i - 1].start));
      }
      // 정확히 시작이 가장 이른 50개(0, 10, ..., 490)가 남았는지 확인
      final keptStarts = decoded.map((s) => s.start).toSet();
      final expectedStarts = List.generate(50, (i) => i * 10).toSet();
      expect(keptStarts, expectedStarts);
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
        '540:1080:3:4',
        '540:1080:3,',
        ',540:1080:3',
        '540:1080:3,,540:1080:3',
        '99999999999999999999999999999:1080:3', // int 오버플로 → tryParse null
        '-1:-1:-1',
        '1440:1440:1440',
        'NaN:NaN:NaN',
        '  :  :  ',
        '540:1080:3:',
        '540::3',
        ':1080:3',
        '540:1080:',
        '   ',
        '가:나:다', // 비-ASCII 숫자 아님
        '540.5:1080:3', // 소수점 포함 → tryParse null
      ];

      for (final garbage in garbageInputs) {
        expect(() => LockScreenSchedule.decode(garbage), returnsNormally,
            reason: 'input: "$garbage"');
      }
      // null도 별도로 확인 (nullable 인자이므로 위 List<String>엔 못 넣음)
      expect(() => LockScreenSchedule.decode(null), returnsNormally);
    });
  });

  group('encode/decode 라운드트립', () {
    test('유효한 슬롯 목록은 encode 후 decode하면 그대로 복원됨', () {
      final slots = [
        LockScreenSlot(start: 540, end: 1080, folderId: 3),
        LockScreenSlot(start: 1080, end: 1380, folderId: 7),
        LockScreenSlot(start: 1320, end: 120, folderId: 9), // 자정 교차
      ];
      final csv = LockScreenSchedule.encode(slots);
      final decoded = LockScreenSchedule.decode(csv);

      expect(decoded, hasLength(slots.length));
      for (var i = 0; i < slots.length; i++) {
        expect(decoded[i].start, slots[i].start);
        expect(decoded[i].end, slots[i].end);
        expect(decoded[i].folderId, slots[i].folderId);
      }
    });

    test('빈 목록은 빈 문자열로 encode되고, 빈 문자열은 빈 목록으로 decode됨', () {
      expect(LockScreenSchedule.encode(const []), '');
      expect(LockScreenSchedule.decode(''), isEmpty);
    });
  });

  group('overlaps — 브루트포스(1440분 전수) 기준 검증', () {
    test('겹치지 않는 두 일반 구간', () {
      final a = LockScreenSlot(start: 540, end: 700, folderId: 1); // 09:00-11:40
      final b = LockScreenSlot(start: 800, end: 900, folderId: 2); // 13:20-15:00
      expect(LockScreenSchedule.overlaps(a, b), _bruteForceOverlaps(a, b));
      expect(LockScreenSchedule.overlaps(a, b), false);
    });

    test('맞닿아 있지만 겹치지 않는 인접 구간 — [540,1080)과 [1080,1380)은 겹침 아님', () {
      final a = LockScreenSlot(start: 540, end: 1080, folderId: 1);
      final b = LockScreenSlot(start: 1080, end: 1380, folderId: 2);
      expect(LockScreenSchedule.overlaps(a, b), _bruteForceOverlaps(a, b));
      expect(LockScreenSchedule.overlaps(a, b), false);
    });

    test('일반 구간끼리 부분적으로 겹침', () {
      final a = LockScreenSlot(start: 540, end: 1080, folderId: 1);
      final b = LockScreenSlot(start: 1000, end: 1200, folderId: 2);
      expect(LockScreenSchedule.overlaps(a, b), _bruteForceOverlaps(a, b));
      expect(LockScreenSchedule.overlaps(a, b), true);
    });

    test('자정 교차 슬롯 두 개가 자정 부근에서 겹침', () {
      final a = LockScreenSlot(start: 1320, end: 120, folderId: 1); // 22:00-02:00
      final b = LockScreenSlot(start: 1400, end: 100, folderId: 2); // 23:20-01:40
      expect(LockScreenSchedule.overlaps(a, b), _bruteForceOverlaps(a, b));
      expect(LockScreenSchedule.overlaps(a, b), true);
    });

    test('자정 교차 슬롯 두 개가 겹치지 않음', () {
      final a = LockScreenSlot(start: 1380, end: 30, folderId: 1); // 23:00-00:30
      final b = LockScreenSlot(start: 60, end: 1320, folderId: 2); // 01:00-22:00 (일반구간)
      // a는 [1380,1440)∪[0,30), b는 [60,1320) → 겹치는 분 없음
      expect(LockScreenSchedule.overlaps(a, b), _bruteForceOverlaps(a, b));
      expect(LockScreenSchedule.overlaps(a, b), false);
    });

    test('자정 교차 슬롯이 이른 새벽 슬롯과 겹침', () {
      final wrap = LockScreenSlot(start: 1320, end: 120, folderId: 1); // 22:00-02:00
      final earlyMorning = LockScreenSlot(start: 30, end: 60, folderId: 2); // 00:30-01:00
      expect(LockScreenSchedule.overlaps(wrap, earlyMorning),
          _bruteForceOverlaps(wrap, earlyMorning));
      expect(LockScreenSchedule.overlaps(wrap, earlyMorning), true);
    });

    test('자정 교차 슬롯이 이른 새벽 슬롯과 겹치지 않음(새벽 슬롯이 wrap 종료 이후)', () {
      final wrap = LockScreenSlot(start: 1320, end: 60, folderId: 1); // 22:00-01:00
      final earlyMorning = LockScreenSlot(start: 120, end: 180, folderId: 2); // 02:00-03:00
      expect(LockScreenSchedule.overlaps(wrap, earlyMorning),
          _bruteForceOverlaps(wrap, earlyMorning));
      expect(LockScreenSchedule.overlaps(wrap, earlyMorning), false);
    });

    test('동일한 슬롯은 스스로와 겹침', () {
      final a = LockScreenSlot(start: 540, end: 1080, folderId: 1);
      expect(LockScreenSchedule.overlaps(a, a), _bruteForceOverlaps(a, a));
      expect(LockScreenSchedule.overlaps(a, a), true);
    });

    test('방어적 케이스: start == end (커버 범위 없음)인 슬롯은 아무와도 겹치지 않음', () {
      // decode()가 이미 걸러내는 값이지만, overlaps()가 단독으로 호출돼도
      // 안전하게 false를 반환해야 한다 (커버하는 분이 없으므로).
      final degenerate = LockScreenSlot(start: 540, end: 540, folderId: 1);
      final other = LockScreenSlot(start: 0, end: 1439, folderId: 2);
      expect(LockScreenSchedule.overlaps(degenerate, other),
          _bruteForceOverlaps(degenerate, other));
      expect(LockScreenSchedule.overlaps(degenerate, other), false);
    });

    test('넓은 조합 스윕: 대표 슬롯 집합의 모든 쌍이 브루트포스와 일치', () {
      final samples = <LockScreenSlot>[
        LockScreenSlot(start: 0, end: 60, folderId: 1),
        LockScreenSlot(start: 60, end: 120, folderId: 2),
        LockScreenSlot(start: 540, end: 1080, folderId: 3),
        LockScreenSlot(start: 1080, end: 1380, folderId: 4),
        LockScreenSlot(start: 1320, end: 120, folderId: 5), // wrap
        LockScreenSlot(start: 1400, end: 100, folderId: 6), // wrap
        LockScreenSlot(start: 1439, end: 30, folderId: 7), // wrap, 거의 자정
        LockScreenSlot(start: 0, end: 1, folderId: 8), // 1분짜리
        LockScreenSlot(start: 1438, end: 1439, folderId: 9), // 1분짜리
        LockScreenSlot(start: 0, end: 1439, folderId: 10), // 거의 하루 전체
      ];
      for (final a in samples) {
        for (final b in samples) {
          expect(
            LockScreenSchedule.overlaps(a, b),
            _bruteForceOverlaps(a, b),
            reason: 'a=[${a.start},${a.end}) b=[${b.start},${b.end})',
          );
        }
      }
    });
  });

  group('overlappingIndices — 브루트포스 기준 검증', () {
    Set<int> bruteForceIndices(List<LockScreenSlot> slots) {
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
        LockScreenSlot(start: 0, end: 480, folderId: 1),
        LockScreenSlot(start: 540, end: 1080, folderId: 2),
        LockScreenSlot(start: 1080, end: 1380, folderId: 3), // 위와 맞닿지만 안 겹침
      ];
      expect(LockScreenSchedule.overlappingIndices(slots),
          bruteForceIndices(slots));
      expect(LockScreenSchedule.overlappingIndices(slots), isEmpty);
    });

    test('세 슬롯 중 두 개만 겹치면 그 두 인덱스만 포함', () {
      final slots = [
        LockScreenSlot(start: 540, end: 1080, folderId: 1), // idx0
        LockScreenSlot(start: 1000, end: 1200, folderId: 2), // idx1, idx0와 겹침
        LockScreenSlot(start: 1200, end: 1300, folderId: 3), // idx2, 아무와도 안 겹침
      ];
      expect(LockScreenSchedule.overlappingIndices(slots),
          bruteForceIndices(slots));
      expect(LockScreenSchedule.overlappingIndices(slots), {0, 1});
    });

    test('자정 교차 슬롯이 섞인 목록', () {
      final slots = [
        LockScreenSlot(start: 1320, end: 120, folderId: 1), // 22:00-02:00 (wrap)
        LockScreenSlot(start: 30, end: 60, folderId: 2), // 00:30-01:00, wrap과 겹침
        LockScreenSlot(start: 540, end: 1080, folderId: 3), // 낮 시간, 안 겹침
      ];
      expect(LockScreenSchedule.overlappingIndices(slots),
          bruteForceIndices(slots));
      expect(LockScreenSchedule.overlappingIndices(slots), {0, 1});
    });
  });

  group('음성 대조군 (negative control)', () {
    // 이 그룹은 "테스트가 실제로 회귀를 잡아내는가"를 문서화하기 위한 것으로,
    // 정상 상태에서는 항상 통과한다. 실제 무력화 실험은 이 파일 작성 과정에서
    // lock_screen_service.dart의 `if (start == end) continue;` 드롭 규칙을
    // 일시적으로 주석 처리해 수행했으며, 위 '음성 대조군' 대상 테스트인
    // "decode — 드롭 규칙 개별 검증 > start == end 이면 드롭"이 다음과 같이
    // 실패하는 것을 확인한 뒤 원상 복구했다:
    //   Expected: empty
    //   Actual: [LockScreenSlot:<...>] (start==end인 슬롯이 살아남아 리스트에 포함됨)
    test('위 드롭 규칙 테스트들이 실제로 무언가를 검증하고 있음을 남겨두는 문서화 테스트', () {
      // start == end 규칙이 살아있는 한 이 슬롯은 항상 드롭되어야 한다.
      expect(LockScreenSchedule.decode('700:700:1'), isEmpty);
    });
  });
}
