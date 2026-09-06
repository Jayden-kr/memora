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

    test('전순서다 — 어떤 두 원소든 부호가 대칭이고 자기 자신과는 0', () {
      const samples = ['Apple', 'apple', 'banana', '가', '한글', '', 'Zebra', '1'];
      for (final a in samples) {
        expect(compareNamesForSort(a, a), 0, reason: 'self compare: $a');
        for (final b in samples) {
          final ab = compareNamesForSort(a, b);
          final ba = compareNamesForSort(b, a);
          expect(ab.sign, -ba.sign, reason: 'asymmetry: $a vs $b');
        }
      }
    });
  });
}
