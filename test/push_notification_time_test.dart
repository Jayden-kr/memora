// PushNotificationService의 시간 로직을 Dart로 포팅하여 전 경우의 수 시뮬레이션
//
// 테스트 대상 (Kotlin → Dart 포팅):
// 1. fireIfInRange: 현재 시간이 [startTotal, endTotal] 범위 안인지 확인
// 2. 딜레이 계산: 다음 알림까지의 대기 시간 계산
import 'package:flutter_test/flutter_test.dart';

// ─── Kotlin 로직을 Dart로 포팅 ───

/// fireIfInRange 로직: 현재 시간이 범위 내인지 확인
/// return true = 알림 발사, false = 스킵
bool fireIfInRange(int nowTotal, int startTotal, int endTotal) {
  if (nowTotal < startTotal || nowTotal > endTotal) {
    return false; // 범위 밖 → 스킵
  }
  return true; // 범위 내 → 발사
}

/// 딜레이 계산 로직 (현재 Kotlin 코드)
int calculateDelay(int nowMin, int startTotal, int intervalMin) {
  final elapsed =
      (nowMin >= startTotal) ? (nowMin - startTotal) % intervalMin : 0;
  return (elapsed == 0) ? intervalMin : (intervalMin - elapsed);
}

/// 딜레이 계산 로직 (수정 제안)
int calculateDelayFixed(
    int nowMin, int startTotal, int endTotal, int intervalMin) {
  if (nowMin < startTotal) {
    // 시작 시간 전 → startTotal까지 대기
    return startTotal - nowMin;
  }
  if (nowMin > endTotal) {
    // 종료 시간 후 → 다음날 startTotal까지 대기 (분)
    return (1440 - nowMin) + startTotal;
  }
  // 범위 내 → 다음 interval 시점까지
  final elapsed = (nowMin - startTotal) % intervalMin;
  return (elapsed == 0) ? intervalMin : (intervalMin - elapsed);
}

// 헬퍼: 시:분 → 총 분
int hm(int h, int m) => h * 60 + m;

void main() {
  group('fireIfInRange — 시간 범위 체크', () {
    // 설정: 09:00~22:00
    const start = 540; // 09:00
    const end = 1320; // 22:00

    test('08:59 → 범위 밖 (시작 전)', () {
      expect(fireIfInRange(hm(8, 59), start, end), false);
    });

    test('09:00 → 범위 내 (경계 시작)', () {
      expect(fireIfInRange(hm(9, 0), start, end), true);
    });

    test('09:01 → 범위 내', () {
      expect(fireIfInRange(hm(9, 1), start, end), true);
    });

    test('12:00 → 범위 내 (정오)', () {
      expect(fireIfInRange(hm(12, 0), start, end), true);
    });

    test('21:59 → 범위 내', () {
      expect(fireIfInRange(hm(21, 59), start, end), true);
    });

    test('22:00 → 범위 내 (경계 종료, inclusive)', () {
      expect(fireIfInRange(hm(22, 0), start, end), true);
    });

    test('22:01 → 범위 밖 (종료 후)', () {
      expect(fireIfInRange(hm(22, 1), start, end), false);
    });

    test('00:00 → 범위 밖 (자정)', () {
      expect(fireIfInRange(hm(0, 0), start, end), false);
    });

    test('23:59 → 범위 밖', () {
      expect(fireIfInRange(hm(23, 59), start, end), false);
    });

    test('06:00 → 범위 밖 (새벽)', () {
      expect(fireIfInRange(hm(6, 0), start, end), false);
    });
  });

  group('fireIfInRange — 다른 시간대', () {
    test('18:00~20:00, 현재 19:00 → 범위 내', () {
      expect(fireIfInRange(hm(19, 0), hm(18, 0), hm(20, 0)), true);
    });

    test('18:00~20:00, 현재 20:01 → 범위 밖', () {
      expect(fireIfInRange(hm(20, 1), hm(18, 0), hm(20, 0)), false);
    });

    test('06:00~08:00, 현재 07:30 → 범위 내', () {
      expect(fireIfInRange(hm(7, 30), hm(6, 0), hm(8, 0)), true);
    });

    test('06:00~08:00, 현재 05:59 → 범위 밖', () {
      expect(fireIfInRange(hm(5, 59), hm(6, 0), hm(8, 0)), false);
    });
  });

  group('현재 딜레이 계산 — 버그 발견 테스트', () {
    // 설정: start=09:00 (540), interval=30분

    test('09:00에 시작 → 30분 후 첫 알림 (09:30)', () {
      final delay = calculateDelay(hm(9, 0), 540, 30);
      expect(delay, 30);
      // 첫 알림: 09:30 ✓
    });

    test('09:15에 시작 → 15분 후 첫 알림 (09:30)', () {
      final delay = calculateDelay(hm(9, 15), 540, 30);
      expect(delay, 15);
      // 첫 알림: 09:30 ✓
    });

    test('09:30에 시작 → 30분 후 (10:00)', () {
      final delay = calculateDelay(hm(9, 30), 540, 30);
      expect(delay, 30);
    });

    test('12:00에 시작 → 30분 후 (12:30)', () {
      final delay = calculateDelay(hm(12, 0), 540, 30);
      expect(delay, 30);
    });

    test('BUG: 08:50에 시작 → 현재 코드: 30분 후 (09:20), 기대: 10분 후 (09:00)',
        () {
      final delay = calculateDelay(hm(8, 50), 540, 30);
      // 현재 코드: nowMin < startTotal → elapsed=0 → delay=intervalMin=30
      expect(delay, 30); // 현재 동작: 09:20에 첫 알림
      // 이상적: delay = 10 (startTotal - nowMin = 540 - 530 = 10)
    });

    test('BUG: 08:00에 시작 → 현재 코드: 30분 후 (08:30 → 스킵), 기대: 60분 (09:00)',
        () {
      final delay = calculateDelay(hm(8, 0), 540, 30);
      expect(delay, 30); // 현재: 08:30에 첫 tick → fireIfInRange에서 스킵
      // 이상적: delay = 60 (startTotal - nowMin = 540 - 480 = 60)
    });

    test('BUG: 23:00에 시작 (end=22:00 지남) → 30분 후 (23:30 → 스킵, 무한 허공)',
        () {
      final delay = calculateDelay(hm(23, 0), 540, 30);
      // (1380-540)%30 = 840%30 = 0 → delay = 30
      expect(delay, 30); // 23:30에 tick → 범위 밖 스킵, 무한 반복
      // 이상적: 다음날 09:00까지 = 600분
    });
  });

  group('수정된 딜레이 계산 — 모든 케이스 통과', () {
    // start=09:00 (540), end=22:00 (1320), interval=30

    test('09:00 → 30분 (09:30)', () {
      expect(calculateDelayFixed(hm(9, 0), 540, 1320, 30), 30);
    });

    test('09:15 → 15분 (09:30)', () {
      expect(calculateDelayFixed(hm(9, 15), 540, 1320, 30), 15);
    });

    test('12:00 → 30분 (12:30)', () {
      expect(calculateDelayFixed(hm(12, 0), 540, 1320, 30), 30);
    });

    test('08:50 → 10분 (09:00) ← BUG 수정', () {
      expect(calculateDelayFixed(hm(8, 50), 540, 1320, 30), 10);
    });

    test('08:00 → 60분 (09:00) ← BUG 수정', () {
      expect(calculateDelayFixed(hm(8, 0), 540, 1320, 30), 60);
    });

    test('00:00 → 540분 (09:00) ← BUG 수정', () {
      expect(calculateDelayFixed(hm(0, 0), 540, 1320, 30), 540);
    });

    test('23:00 → 600분 (다음날 09:00) ← BUG 수정', () {
      expect(calculateDelayFixed(hm(23, 0), 540, 1320, 30), 600);
    });

    test('22:01 → 659분 (다음날 09:00) ← BUG 수정', () {
      expect(calculateDelayFixed(hm(22, 1), 540, 1320, 30), 659);
    });

    test('22:00 → 30분 (범위 내 마지막, 22:30에서 스킵됨)', () {
      expect(calculateDelayFixed(hm(22, 0), 540, 1320, 30), 30);
    });

    test('21:45 → 15분 (22:00)', () {
      expect(calculateDelayFixed(hm(21, 45), 540, 1320, 30), 15);
    });
  });

  group('수정된 딜레이 — 5분 간격', () {
    test('09:03 → 2분 (09:05)', () {
      expect(calculateDelayFixed(hm(9, 3), 540, 1320, 5), 2);
    });

    test('09:05 → 5분 (09:10)', () {
      expect(calculateDelayFixed(hm(9, 5), 540, 1320, 5), 5);
    });

    test('08:58 → 2분 (09:00)', () {
      expect(calculateDelayFixed(hm(8, 58), 540, 1320, 5), 2);
    });
  });

  group('수정된 딜레이 — 60분 간격', () {
    test('10:30 → 30분 (11:00)', () {
      expect(calculateDelayFixed(hm(10, 30), 540, 1320, 60), 30);
    });

    test('09:00 → 60분 (10:00)', () {
      expect(calculateDelayFixed(hm(9, 0), 540, 1320, 60), 60);
    });

    test('08:30 → 30분 (09:00)', () {
      expect(calculateDelayFixed(hm(8, 30), 540, 1320, 60), 30);
    });
  });

  group('전체 하루 시뮬레이션 — 09:00~22:00, 30분 간격', () {
    test('24시간 동안 매분 체크하여 정확한 알림 횟수 확인', () {
      const start = 540; // 09:00
      const end = 1320; // 22:00
      const interval = 30;

      int fireCount = 0;
      final fireTimes = <int>[];

      // 09:00에 서비스 시작 가정
      int nextTick = start + interval; // 첫 알림: 09:30

      for (int min = 0; min < 1440; min++) {
        if (min == nextTick) {
          if (fireIfInRange(min, start, end)) {
            fireCount++;
            fireTimes.add(min);
          }
          nextTick += interval;
        }
      }

      // 09:30, 10:00, 10:30, ... 21:30, 22:00 = 26회
      expect(fireCount, 26);
      expect(fireTimes.first, hm(9, 30)); // 첫 알림
      expect(fireTimes.last, hm(22, 0)); // 마지막 알림
    });

    test('5분 간격으로 하루 알림 횟수', () {
      const start = 540;
      const end = 1320;
      const interval = 5;

      int fireCount = 0;
      int nextTick = start + interval;

      for (int min = 0; min < 1440; min++) {
        if (min == nextTick) {
          if (fireIfInRange(min, start, end)) {
            fireCount++;
          }
          nextTick += interval;
        }
      }

      // (22:00 - 09:05) / 5 + 1 = 155 + 1 = 156...
      // Actually: 09:05, 09:10, ... 22:00 = (1320-545)/5 + 1 = 156
      expect(fireCount, 156);
    });
  });

  group('경계 케이스 — endTotal 직전/직후', () {
    test('endTotal 직전 분에서 발사', () {
      expect(fireIfInRange(1319, 540, 1320), true); // 21:59 ✓
    });

    test('endTotal 정확히에서 발사 (inclusive)', () {
      expect(fireIfInRange(1320, 540, 1320), true); // 22:00 ✓
    });

    test('endTotal+1에서 스킵', () {
      expect(fireIfInRange(1321, 540, 1320), false); // 22:01 ✗
    });

    test('startTotal 직전에서 스킵', () {
      expect(fireIfInRange(539, 540, 1320), false); // 08:59 ✗
    });

    test('startTotal 정확히에서 발사', () {
      expect(fireIfInRange(540, 540, 1320), true); // 09:00 ✓
    });
  });
}
