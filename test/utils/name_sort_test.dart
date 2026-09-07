// 이름순 정렬 규칙(lib/utils/name_sort.dart) 검증.
//
// 이 비교자는 세 곳이 같은 순서를 내도록 맞추는 단일 기준이다:
//  - 카드 목록: SQL `question COLLATE NOCASE ASC, question ASC`
//  - 홈 폴더 목록: 이 함수
//  - 잠금화면(네이티브): java.text.Collator, SECONDARY(대소문자 무시)
// 세 규칙이 어긋나면 같은 덱이 화면마다 다른 순서로 보인다.
import 'package:flutter_test/flutter_test.dart';
import 'package:memora/utils/name_sort.dart';

void main() {
  List<String> sorted(List<String> input) =>
      List<String>.from(input)..sort(compareNamesForSort);

  group('compareNamesForSort', () {
    test('대소문자를 접어 사전 순으로 붙인다', () {
      // SQL 쪽 `COLLATE NOCASE`와 같은 결과여야 한다 — 예전 `question ASC`는
      // 'Apple', 'Zebra', 'apple' 처럼 대문자를 전부 앞으로 몰았다.
      expect(sorted(['Zebra', 'apple', 'Apple', 'banana']),
          ['Apple', 'apple', 'banana', 'Zebra']);
    });

    test('접었을 때 같으면 원문으로 갈라 순서를 고정한다', () {
      expect(compareNamesForSort('apple', 'Apple'), greaterThan(0));
      expect(compareNamesForSort('Apple', 'apple'), lessThan(0));
      expect(compareNamesForSort('apple', 'apple'), 0);
    });

    test('한글은 가나다 순이다', () {
      expect(sorted(['하늘', '가방', '나무', '다리']),
          ['가방', '나무', '다리', '하늘']);
    });

    test('영문이 한글보다 앞선다(Collator와 같은 방향)', () {
      expect(sorted(['한글', 'apple', '가']), ['apple', '가', '한글']);
    });

    test('빈 문자열이 맨 앞이고 비교가 던지지 않는다', () {
      expect(sorted(['b', '', 'a']), ['', 'a', 'b']);
    });

    test('SQL COLLATE NOCASE와 같이 ASCII만 접는다', () {
      // SQLite NOCASE는 ASCII A~Z만 접는다. Dart의 toLowerCase()는 유니코드 전체를
      // 접어 켈빈 기호(U+212A)를 'k'로, 'É'를 'é'로 바꾼다 — 그 차이 때문에 같은 이름이
      // 카드 목록(SQL)과 홈 폴더 목록(Dart)에서 다른 자리에 놓였다(리뷰 A-01).
      // 아래 기대값은 sqlite에서 `ORDER BY question COLLATE NOCASE, question`으로
      // 실측 대조했다.
      const kelvin = 'K'; // 켈빈 기호. 눈으로는 'K'와 똑같다.
      expect(compareNamesForSort(kelvin, 'zebra'), greaterThan(0));
      expect(compareNamesForSort('É', 'e'), greaterThan(0));
      expect(compareNamesForSort('É', 'é'), lessThan(0));
      expect(compareNamesForSort('B', 'a'), greaterThan(0));
    });

    test('서로게이트 쌍(이모지 등)도 SQLite와 같은 코드포인트 순서다', () {
      // String.compareTo는 UTF-16 "코드유닛"을 비교한다 — 서로게이트 쌍(U+10000
      // 이상)의 앞쪽 유닛(0xD800~0xDBFF)이 BMP 상위 영역(0xE000~0xFFFF, 예: 이
      // 대체문자 U+FFFD)보다 수치상 작아서, 코드유닛 비교로는 실제로 더 큰
      // 코드포인트(이모지)가 더 작게 취급된다. SQLite의 BINARY collation은 UTF-8
      // 바이트 비교라 진짜 코드포인트 순서와 같다. 아래 기대값은 sqlite에서
      // `ORDER BY name COLLATE NOCASE, name`으로 실측 대조했다(리뷰 발견).
      //
      // ⚠️ 네거티브 컨트롤: compareNamesForSort가 다시 String.compareTo만 쓰면
      // (코드포인트 비교 없이) 아래 두 단언이 뒤집힌다 — 직접 되돌려서 실패하는
      // 것까지 확인했다.
      const emoji = '\u{1F600}zz'; // 😀 (U+1F600, 서로게이트 쌍)
      const replacementChar = '�zz'; // U+FFFD, BMP 상위 영역
      expect(compareNamesForSort(replacementChar, emoji), lessThan(0));
      expect(sorted([emoji, replacementChar]), [replacementChar, emoji]);
    });

    test('전순서다 — 반사·대칭·추이 전부', () {
      const samples = [
        'Apple', 'apple', 'banana', '가', '한글', '', 'Zebra', '1',
        'É', 'é', 'K',
      ];
      for (final a in samples) {
        expect(compareNamesForSort(a, a), 0, reason: 'self compare: $a');
        for (final b in samples) {
          final ab = compareNamesForSort(a, b);
          final ba = compareNamesForSort(b, a);
          expect(ab.sign, -ba.sign, reason: 'asymmetry: $a vs $b');
        }
      }
      // ⚠️ 반사성과 대칭성만 보면 `(a, b) => 0`(전부 같다)도 통과한다 — 실제로 그
      // 돌연변이가 이 테스트를 살아서 빠져나갔다(리뷰 P4-02). 추이성을 더해도
      // `=> 0`은 유효한 전순서라 여전히 통과하므로, "서로 다른 문자열은 반드시
      // 갈린다"는 퇴화 방지 단언을 먼저 둔다. 이 비교자는 접은 키가 같아도 원문으로
      // 갈라내므로 같은 문자열일 때만 0이어야 한다.
      for (final a in samples) {
        for (final b in samples) {
          if (a == b) continue;
          expect(compareNamesForSort(a, b), isNot(0),
              reason: 'distinct strings must not compare equal: $a vs $b');
        }
      }
      // List.sort가 일관된 결과를 내려면 필요한 성질은 추이성이다.
      for (final a in samples) {
        for (final b in samples) {
          if (compareNamesForSort(a, b) >= 0) continue;
          for (final c in samples) {
            if (compareNamesForSort(b, c) >= 0) continue;
            expect(
              compareNamesForSort(a, c),
              lessThan(0),
              reason: 'transitivity: $a < $b < $c 인데 $a >= $c',
            );
          }
        }
      }
      // 같음(0)도 추이적이어야 한다 — a==b, b==c 면 a==c.
      for (final a in samples) {
        for (final b in samples) {
          if (compareNamesForSort(a, b) != 0) continue;
          for (final c in samples) {
            if (compareNamesForSort(b, c) != 0) continue;
            expect(compareNamesForSort(a, c), 0,
                reason: 'equality transitivity: $a == $b == $c');
          }
        }
      }
    });
  });
}
