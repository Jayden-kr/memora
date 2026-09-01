// LockScreenSchedule(잠금화면 시간대별 폴더 자동 전환)의
// decode/encode/overlap/effectiveRanges 로직 검증.
//
// 테스트 대상:
// 1. decode: scheduleCsv → List<LockScreenSlot>, 드롭 규칙이 FolderSchedule.kt
//    parse()와 반드시 일치해야 함(스펙은 이 파일의 상단 문서 주석 참고)
// 2. encode: List<LockScreenSlot> → scheduleCsv (decode의 역함수)
// 3. overlaps/overlappingIndices: 반열림 구간 [start, end) 겹침 판정
//    (start > end 인 자정 교차 슬롯 포함) — 1440분 전수 브루트포스가 스펙 그 자체
// 4. effectiveRanges: 각 슬롯이 "첫 매치 승리" 우선순위 규칙 아래 실제로 차지하는
//    구간 — 여기도 1440분 전수 크로스체크(firstMatchOwner)가 스펙 그 자체
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

  group('effectiveRanges — 각 슬롯의 실적용 구간', () {
    test('겹치지 않으면 모든 슬롯의 실적용 구간이 선언 구간과 같음', () {
      final slots = [
        LockScreenSlot(start: 0, end: 480, folderId: 1),
        LockScreenSlot(start: 540, end: 1080, folderId: 2),
        LockScreenSlot(start: 1080, end: 1380, folderId: 3), // 앞과 맞닿지만 안 겹침
      ];
      final ranges = LockScreenSchedule.effectiveRanges(slots);
      expect(ranges, hasLength(3));
      for (var i = 0; i < slots.length; i++) {
        expect(ranges[i], [
          [slots[i].start, slots[i].end]
        ]);
        expect(
            LockScreenSchedule.matchesDeclared(slots[i], ranges[i]), isTrue);
      }
    });

    test('부분 겹침: 뒤 슬롯은 앞 슬롯에게 뺏기고 남은 만큼만', () {
      final a = LockScreenSlot(start: 360, end: 720, folderId: 1); // 06:00-12:00
      final b = LockScreenSlot(start: 660, end: 1080, folderId: 2); // 11:00-18:00
      final ranges = LockScreenSchedule.effectiveRanges([a, b]);
      expect(ranges[0], [
        [360, 720]
      ]);
      expect(ranges[1], [
        [720, 1080]
      ]);
      expect(LockScreenSchedule.matchesDeclared(a, ranges[0]), isTrue);
      expect(LockScreenSchedule.matchesDeclared(b, ranges[1]), isFalse);
    });

    test('완전히 가려진 슬롯(죽은 슬롯) — 실기기에서 재현된 수치', () {
      // 영단어 19:31–23:31(1171-1411) + 히브리어 21:36–22:26(1296-1346).
      // 히브리어는 영단어 구간에 완전히 포함돼 단 1분도 실행되지 않는다.
      final a = LockScreenSlot(start: 1171, end: 1411, folderId: 1); // 영단어
      final b = LockScreenSlot(start: 1296, end: 1346, folderId: 2); // 히브리어
      final ranges = LockScreenSchedule.effectiveRanges([a, b]);
      expect(ranges[0], [
        [1171, 1411]
      ]);
      expect(ranges[1], isEmpty);
      expect(LockScreenSchedule.matchesDeclared(a, ranges[0]), isTrue);
      expect(LockScreenSchedule.matchesDeclared(b, ranges[1]), isFalse);
    });

    test('시작이 같은 두 슬롯 — 목록 순서상 먼저인 쪽이 전부, 나머지는 남는 부분만', () {
      final first = LockScreenSlot(start: 600, end: 750, folderId: 1);
      final second = LockScreenSlot(start: 600, end: 900, folderId: 2);
      final ranges = LockScreenSchedule.effectiveRanges([first, second]);
      expect(ranges[0], [
        [600, 750]
      ]);
      expect(ranges[1], [
        [750, 900]
      ]);
    });

    test('자정 랩, 가려지지 않음 — 두 조각이 아니라 하나로 병합되어 보고됨', () {
      final wrap = LockScreenSlot(start: 1320, end: 120, folderId: 1); // 22:00-02:00
      final ranges = LockScreenSchedule.effectiveRanges([wrap]);
      expect(ranges[0], [
        [1320, 120]
      ]);
    });

    test('자정 랩, 앞선 슬롯에게 일부 가려짐', () {
      final earlier = LockScreenSlot(start: 1300, end: 1400, folderId: 1); // 21:40-23:20
      final wrap = LockScreenSlot(start: 1320, end: 120, folderId: 2); // 22:00-02:00
      final ranges = LockScreenSchedule.effectiveRanges([earlier, wrap]);
      expect(ranges[0], [
        [1300, 1400]
      ]);
      // 22:00-23:20은 earlier가 이미 차지 → wrap은 23:20부터 시작하는 걸로 보고됨.
      expect(ranges[1], [
        [1400, 120]
      ]);
    });

    test('자정에서 끝나는 슬롯 — 다음날로 안 이어지고 [start, 0]으로 표현됨', () {
      final slot = LockScreenSlot(start: 1320, end: 0, folderId: 1);
      final ranges = LockScreenSchedule.effectiveRanges([slot]);
      expect(ranges[0], [
        [1320, 0]
      ]);
    });

    test('빈 입력은 빈 리스트', () {
      expect(LockScreenSchedule.effectiveRanges(const []), isEmpty);
    });

    test('슬롯 하나뿐이면 자기 자신의 구간 그대로', () {
      final slot = LockScreenSlot(start: 100, end: 200, folderId: 1);
      final ranges = LockScreenSchedule.effectiveRanges([slot]);
      expect(ranges, [
        [
          [100, 200]
        ]
      ]);
    });

    test(
        '한 슬롯이 서로 인접하지 않은 2개 구간으로 쪼개질 수 있음 — '
        '자정랩 슬롯의 가운데를 앞선 일반 슬롯이 파먹는 경우', () {
      // C(자정랩, 1300-200)는 두 번째 우선순위지만, 첫 번째 우선순위인 G(50-150)가
      // C의 [0,200) 세그먼트 "가운데"(50-150)를 가로채면 C는 [0,50)과 [150,200)
      // 두 조각으로 쪼개진다. 이 중 [0,50)은 C의 다른 세그먼트인 [1300,1440)과
      // 자정에서 물리적으로 맞닿아 있어 [1300,50) 하나로 병합되고, 결과적으로 C는
      // 서로 인접하지 않은 두 구간 [1300,50)과 [150,200)을 갖는다.
      final g = LockScreenSlot(start: 50, end: 150, folderId: 1);
      final c = LockScreenSlot(start: 1300, end: 200, folderId: 2);
      final ranges = LockScreenSchedule.effectiveRanges([g, c]);
      expect(ranges[0], [
        [50, 150]
      ]);
      expect(ranges[1], [
        [150, 200],
        [1300, 50],
      ]);
    });

    group('matchesDeclared', () {
      test('실적용이 선언과 완전히 같으면 true', () {
        final slot = LockScreenSlot(start: 100, end: 200, folderId: 1);
        expect(
            LockScreenSchedule.matchesDeclared(slot, [
              [100, 200]
            ]),
            isTrue);
      });

      test('구간이 여러 개면 false (합쳐서 같은 시간을 커버해도)', () {
        final slot = LockScreenSlot(start: 100, end: 200, folderId: 1);
        expect(
            LockScreenSchedule.matchesDeclared(slot, [
              [100, 150],
              [150, 200]
            ]),
            isFalse);
      });

      test('구간이 비어 있으면 false', () {
        final slot = LockScreenSlot(start: 100, end: 200, folderId: 1);
        expect(LockScreenSchedule.matchesDeclared(slot, const []), isFalse);
      });

      test('시작/끝이 조금이라도 다르면 false', () {
        final slot = LockScreenSlot(start: 100, end: 200, folderId: 1);
        expect(
            LockScreenSchedule.matchesDeclared(slot, [
              [100, 199]
            ]),
            isFalse);
      });
    });
  });

  group('effectiveRanges — 규칙 자체와 교차검증(1440분 전수)', () {
    // slots 목록에서 분 m을 "첫 매치 승리" 규칙으로 실제 소유하는 슬롯의 인덱스.
    // 아무도 커버하지 않으면 null. decode()가 보장하는 정렬을 다시 하지 않고 주어진
    // 목록 순서를 그대로 쓴다 — effectiveRanges의 스펙과 동일한 전제.
    int? firstMatchOwner(List<LockScreenSlot> slots, int minute) {
      for (var i = 0; i < slots.length; i++) {
        if (_covers(slots[i], minute)) return i;
      }
      return null;
    }

    // 구간 [r[0], r[1]]을 (r[0]<r[1] 또는 자정랩 r[0]>r[1]) 슬롯과 동일한 반열림
    // 규칙으로 읽어 분 minute이 그 안에 들어가는지 판정. 기존 _covers를 재사용해
    // 세 번째 포함 판정 로직을 새로 만들지 않는다.
    bool inRanges(List<List<int>> ranges, int minute) {
      for (final r in ranges) {
        final pseudo = LockScreenSlot(start: r[0], end: r[1], folderId: 0);
        if (_covers(pseudo, minute)) return true;
      }
      return false;
    }

    void crossCheck(String description, List<LockScreenSlot> slots) {
      test(description, () {
        final ranges = LockScreenSchedule.effectiveRanges(slots);
        expect(ranges, hasLength(slots.length));
        for (var m = 0; m < 1440; m++) {
          final owner = firstMatchOwner(slots, m);
          for (var i = 0; i < slots.length; i++) {
            final covered = inRanges(ranges[i], m);
            if (i == owner) {
              expect(covered, isTrue,
                  reason: '$description: 분 $m 은 규칙상 슬롯 $i(첫 매치) 소유인데 '
                      'effectiveRanges[$i]엔 없음');
            } else {
              expect(covered, isFalse,
                  reason: '$description: 분 $m 은 슬롯 $owner 소유인데 '
                      'effectiveRanges[$i]에도 들어있음(중복 소유)');
            }
          }
        }
      });
    }

    crossCheck('겹치지 않는 슬롯들', [
      LockScreenSlot(start: 0, end: 480, folderId: 1),
      LockScreenSlot(start: 540, end: 1080, folderId: 2),
      LockScreenSlot(start: 1080, end: 1380, folderId: 3),
    ]);

    crossCheck('부분 겹침 체인 3개', [
      LockScreenSlot(start: 0, end: 300, folderId: 1),
      LockScreenSlot(start: 200, end: 500, folderId: 2),
      LockScreenSlot(start: 400, end: 700, folderId: 3),
    ]);

    crossCheck('완전히 가려진 슬롯(죽은 슬롯)', [
      LockScreenSlot(start: 1171, end: 1411, folderId: 1),
      LockScreenSlot(start: 1296, end: 1346, folderId: 2),
    ]);

    crossCheck('자정 랩 + 부분 가려짐', [
      LockScreenSlot(start: 1300, end: 1400, folderId: 1),
      LockScreenSlot(start: 1320, end: 120, folderId: 2),
    ]);

    crossCheck('자정 랩 두 개가 서로 겹침', [
      LockScreenSlot(start: 1320, end: 120, folderId: 1),
      LockScreenSlot(start: 1400, end: 100, folderId: 2),
    ]);

    crossCheck('한 슬롯이 비인접 2구간으로 쪼개지는 경우(자정랩 가운데를 파먹힘)', [
      LockScreenSlot(start: 50, end: 150, folderId: 1),
      LockScreenSlot(start: 1300, end: 200, folderId: 2),
    ]);

    crossCheck('시작이 같은 슬롯들', [
      LockScreenSlot(start: 600, end: 750, folderId: 1),
      LockScreenSlot(start: 600, end: 900, folderId: 2),
      LockScreenSlot(start: 600, end: 620, folderId: 3),
    ]);

    test('무작위 슬롯 15개 스트레스(시드 고정) — 여러 세트 반복', () {
      for (final seed in [1, 7, 42]) {
        final rand = Random(seed);
        final slots = List.generate(15, (i) {
          final start = rand.nextInt(1440);
          var end = rand.nextInt(1440);
          if (end == start) end = (end + 1) % 1440; // decode와 동일하게 start==end 회피
          return LockScreenSlot(start: start, end: end, folderId: i);
        });
        final ranges = LockScreenSchedule.effectiveRanges(slots);
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

    // effectiveRanges 쪽 무력화 실험: lock_screen_service.dart의
    // `if (inSlot) { owner[m] = i; break; }`에서 break;를 일시적으로 제거해
    // "나중 슬롯이 앞선 슬롯이 이미 차지한 분을 도로 뺏는" 회귀를 주입한 뒤
    // 확인했다. 결과: 겹침이 있는 시나리오를 다루는 테스트 12개가 전부 실패,
    // 겹침이 없는 시나리오(겹치지 않는 슬롯/자정 랩 단독/빈 입력/matchesDeclared
    // 등) 10개는 원래대로 통과 — 겹침이 없으면 분마다 후보가 하나뿐이라 break
    // 유무가 결과에 영향을 주지 않기 때문에, 이 구분 자체가 테스트가 정확히
    // "우선순위 규칙"을 겨냥하고 있음을 보여준다. 실패한 12개:
    //   - "부분 겹침: 뒤 슬롯은 앞 슬롯에게 뺏기고 남은 만큼만"
    //   - "완전히 가려진 슬롯(죽은 슬롯) — 실기기에서 재현된 수치"
    //   - "시작이 같은 두 슬롯 — 목록 순서상 먼저인 쪽이 전부, 나머지는 남는 부분만"
    //   - "자정 랩, 앞선 슬롯에게 일부 가려짐"
    //   - "한 슬롯이 서로 인접하지 않은 2개 구간으로 쪼개질 수 있음 — ..."
    //   - 교차검증(1440분 전수) 중 "부분 겹침 체인 3개"
    //   - 교차검증 중 "완전히 가려진 슬롯(죽은 슬롯)"
    //   - 교차검증 중 "자정 랩 + 부분 가려짐"
    //   - 교차검증 중 "자정 랩 두 개가 서로 겹침"
    //   - 교차검증 중 "한 슬롯이 비인접 2구간으로 쪼개지는 경우(자정랩 가운데를 파먹힘)"
    //   - 교차검증 중 "시작이 같은 슬롯들"
    //   - 교차검증 중 "무작위 슬롯 15개 스트레스(시드 고정) — 여러 세트 반복"
    // 확인 후 break;를 원상 복구했다.
    test('effectiveRanges 우선순위(첫 매치 승리) 검증도 실제로 회귀를 잡아냄을 남겨두는 문서화 테스트',
        () {
      // "앞선 슬롯이 이긴다" 규칙이 살아있는 한, 완전히 가려진 슬롯은 항상 빈
      // 리스트여야 한다.
      final earlier = LockScreenSlot(start: 1171, end: 1411, folderId: 1);
      final shadowed = LockScreenSlot(start: 1296, end: 1346, folderId: 2);
      expect(
          LockScreenSchedule.effectiveRanges([earlier, shadowed])[1], isEmpty);
    });
  });
}
