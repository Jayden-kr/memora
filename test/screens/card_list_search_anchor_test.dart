import 'package:flutter_test/flutter_test.dart';
import 'package:memora/screens/card_list_screen.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// 검색을 닫을 때 "전체 목록에서 맨 위에 둘 카드"를 고르는 순수 함수들의 계약.
///
/// 우선순위는 마지막으로 누른 카드(결과에 아직 있을 때) > 화면 맨 위에 보이던 결과 >
/// 없음(null → 목록 맨 위). 위젯/DB 없이 함수만 검증한다.
void main() {
  group('pickSearchExitAnchor', () {
    const ids = <int?>[11, 22, 33, 44];

    test('누른 카드가 결과에 있으면 화면 맨 위 결과보다 우선한다', () {
      expect(
        pickSearchExitAnchor(
            tappedCardId: 33, resultIds: ids, firstVisibleIndex: 0),
        33,
      );
    });

    test('누른 카드가 결과에 없으면 화면 맨 위 결과로 넘어간다', () {
      expect(
        pickSearchExitAnchor(
            tappedCardId: 99, resultIds: ids, firstVisibleIndex: 1),
        22,
      );
    });

    test('누른 카드가 없으면 화면 맨 위 결과를 쓴다', () {
      expect(
        pickSearchExitAnchor(
            tappedCardId: null, resultIds: ids, firstVisibleIndex: 2),
        33,
      );
    });

    test('누른 카드도 보이는 칸도 없으면 null (목록 맨 위)', () {
      expect(
        pickSearchExitAnchor(
            tappedCardId: null, resultIds: ids, firstVisibleIndex: null),
        isNull,
      );
    });

    test('보이는 칸 인덱스가 범위를 벗어나면 던지지 않고 null', () {
      expect(
        pickSearchExitAnchor(
            tappedCardId: null, resultIds: ids, firstVisibleIndex: 4),
        isNull,
      );
      expect(
        pickSearchExitAnchor(
            tappedCardId: null, resultIds: ids, firstVisibleIndex: -1),
        isNull,
      );
    });

    test('결과가 비어 있으면 누른 카드가 있어도 null', () {
      expect(
        pickSearchExitAnchor(
            tappedCardId: 11, resultIds: const <int?>[], firstVisibleIndex: 0),
        isNull,
      );
    });

    test('id가 null인 결과는 누른 카드(null)와 짝지어지지 않는다', () {
      // 누른 카드가 없는데(null) 결과에 null id가 섞여 있다고 contains(null)이 참이 되면 안 된다.
      expect(
        pickSearchExitAnchor(
            tappedCardId: null,
            resultIds: const <int?>[null, 22],
            firstVisibleIndex: 1),
        22,
      );
    });
  });

  group('firstVisibleItemIndex', () {
    ItemPosition pos(int index, double leading, double trailing) =>
        ItemPosition(
          index: index,
          itemLeadingEdge: leading,
          itemTrailingEdge: trailing,
        );

    test('화면 위로 완전히 지나간 칸은 건너뛴다', () {
      expect(
        firstVisibleItemIndex([
          pos(4, -0.5, -0.1),
          pos(5, 0, 0.3),
          pos(6, 0.3, 0.7),
        ]),
        5,
      );
    });

    test('뒤쪽 가장자리가 정확히 0이면 보이지 않는 칸이다', () {
      expect(
        firstVisibleItemIndex([
          pos(4, -0.5, 0.0),
          pos(5, 0, 0.3),
        ]),
        5,
      );
    });

    test('순서가 뒤섞여 있어도 인덱스가 가장 작은 칸을 고른다', () {
      expect(
        firstVisibleItemIndex([
          pos(7, 0.6, 0.9),
          pos(5, 0.0, 0.3),
          pos(6, 0.3, 0.6),
        ]),
        5,
      );
    });

    test('위가 잘린 채 걸쳐 있는 칸도 보이는 칸이다', () {
      expect(
        firstVisibleItemIndex([
          pos(3, -0.4, 0.2),
          pos(4, 0.2, 0.6),
        ]),
        3,
      );
    });

    test('비어 있으면 null', () {
      expect(firstVisibleItemIndex(const <ItemPosition>[]), isNull);
    });

    test('전부 화면 위로 지나갔으면 null', () {
      expect(
        firstVisibleItemIndex([
          pos(1, -0.9, -0.5),
          pos(2, -0.5, 0.0),
        ]),
        isNull,
      );
    });
  });

  group('pinAlignmentFor', () {
    test('0~1 범위 안이면 그 값 그대로 (경계 포함)', () {
      expect(pinAlignmentFor(0.0), 0.0);
      expect(pinAlignmentFor(0.42), 0.42);
      expect(pinAlignmentFor(1.0), 1.0);
    });

    test('위로 잘린 카드(음수)는 붙잡지 않는다', () {
      expect(pinAlignmentFor(-0.01), isNull);
    });

    test('화면 아래로 벗어난 카드(1 초과)는 붙잡지 않는다', () {
      expect(pinAlignmentFor(1.01), isNull);
    });

    test('NaN은 붙잡지 않는다', () {
      expect(pinAlignmentFor(double.nan), isNull);
    });
  });
}
