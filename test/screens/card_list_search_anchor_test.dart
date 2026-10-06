import 'package:flutter_test/flutter_test.dart';
import 'package:memora/screens/card_list_screen.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// 검색을 닫을 때 "전체 목록에서 맨 위에 둘 카드"를 고르는 순수 함수들의 계약.
///
/// 우선순위는 마지막으로 누른 카드 > 닫기 직전 화면 맨 위에 보이던 결과 > 없음(null → 목록 맨 위).
/// 두 후보 모두 "다시 불러온 전체 목록에 있을 때만" 쓴다. 위젯/DB 없이 함수만 검증한다.
void main() {
  group('pickSearchExitAnchor (전체 목록 기준)', () {
    const full = <int?>[11, 22, 33, 44, 55];

    test('누른 카드가 전체 목록에 있으면 맨 위 결과보다 우선한다', () {
      // 누른 카드를 편집해 검색어와 안 맞게 고치면 같은 검색어 재조회 결과에서는 빠지지만 전체
      // 목록에는 그대로 있다. 이 함수는 결과 목록이 아니라 전체 목록만 보므로(결과 목록은
      // 인자에도 없다) 그 카드(33)가 맨 위 결과(11)를 이긴다.
      expect(
        pickSearchExitAnchor(
            tappedCardId: 33, firstVisibleCardId: 11, fullListIds: full),
        33,
      );
    });

    test('누른 카드가 전체 목록에도 없으면(삭제·이동) 맨 위 결과로 넘어간다', () {
      expect(
        pickSearchExitAnchor(
            tappedCardId: 99, firstVisibleCardId: 22, fullListIds: full),
        22,
      );
    });

    test('누른 카드가 없으면 맨 위 결과를 쓴다', () {
      expect(
        pickSearchExitAnchor(
            tappedCardId: null, firstVisibleCardId: 33, fullListIds: full),
        33,
      );
    });

    test('맨 위 결과도 전체 목록에 없으면 null (목록 맨 위)', () {
      expect(
        pickSearchExitAnchor(
            tappedCardId: 99, firstVisibleCardId: 98, fullListIds: full),
        isNull,
      );
    });

    test('두 후보 모두 없으면 null', () {
      expect(
        pickSearchExitAnchor(
            tappedCardId: null, firstVisibleCardId: null, fullListIds: full),
        isNull,
      );
    });

    test('전체 목록이 비어 있으면 후보가 있어도 null', () {
      expect(
        pickSearchExitAnchor(
            tappedCardId: 11,
            firstVisibleCardId: 22,
            fullListIds: const <int?>[]),
        isNull,
      );
    });

    test('id가 null인 카드는 누른 카드(null)와 짝지어지지 않는다', () {
      // 누른 카드가 없는데(null) 전체 목록에 null id가 섞여 있다고 contains(null)이 참이 되어
      // null을 앵커로 돌려주면 안 된다 — 다음 후보(22)로 넘어가야 한다.
      expect(
        pickSearchExitAnchor(
            tappedCardId: null,
            firstVisibleCardId: 22,
            fullListIds: const <int?>[null, 22]),
        22,
      );
    });

    test('맨 위 결과 후보가 null이어도 전체 목록의 null id와 짝지어지지 않는다', () {
      expect(
        pickSearchExitAnchor(
            tappedCardId: null,
            firstVisibleCardId: null,
            fullListIds: const <int?>[null, 22]),
        isNull,
      );
    });
  });

  group('keepAnchorForNewResults (새 결과 묶음에서도 누른 카드를 이어 간다)', () {
    test('누른 카드가 새 결과에도 있으면 그대로 이어 간다', () {
      expect(
        keepAnchorForNewResults(
            tappedCardId: 33, newResultIds: const <int?>[11, 33, 44]),
        33,
      );
    });

    test('누른 카드가 새 결과에 없으면 비운다', () {
      expect(
        keepAnchorForNewResults(
            tappedCardId: 33, newResultIds: const <int?>[11, 44]),
        isNull,
      );
    });

    test('누른 카드가 없으면(null) 새 결과에 null id가 섞여 있어도 null', () {
      expect(
        keepAnchorForNewResults(
            tappedCardId: null, newResultIds: const <int?>[null, 22]),
        isNull,
      );
    });

    test('새 결과가 비어 있으면 null', () {
      expect(
        keepAnchorForNewResults(
            tappedCardId: 33, newResultIds: const <int?>[]),
        isNull,
      );
    });

    test('실기기 재현: 검색어를 한 글자씩 지워도(apple→appl→app→ap→a→빈칸) 닫을 때 누른 카드에 머문다', () {
      // 누른 카드(33)가 글자를 지울수록 늘어나는 결과(부분 문자열 검색)에 계속 들어 있다.
      const resultSets = <List<int?>>[
        [33], // apple
        [33, 55], // appl
        [11, 33, 55], // app
        [11, 22, 33, 55], // ap
        [11, 22, 33, 44, 55], // a
      ];
      int? anchor = 33; // "apple" 결과에서 33번 카드를 눌렀다
      for (final ids in resultSets.skip(1)) {
        anchor = keepAnchorForNewResults(tappedCardId: anchor, newResultIds: ids);
      }
      expect(anchor, 33);
      // 검색어가 비어 전체 목록이 올라오면, 닫기 직전 맨 위 결과(11)가 아니라 누른 카드로 간다.
      expect(
        pickSearchExitAnchor(
          tappedCardId: anchor,
          firstVisibleCardId: 11,
          fullListIds: const <int?>[11, 22, 33, 44, 55, 66],
        ),
        33,
      );
    });

    test('중간에 누른 카드가 빠지는 검색어를 거치면 이후엔 맨 위 결과로 간다', () {
      int? anchor = 33;
      anchor = keepAnchorForNewResults(
          tappedCardId: anchor, newResultIds: const <int?>[11, 44]); // 33 없음
      expect(anchor, isNull);
      // 다시 33이 들어 있는 결과가 와도 비운 앵커는 돌아오지 않는다(눌러야 다시 기록된다).
      anchor = keepAnchorForNewResults(
          tappedCardId: anchor, newResultIds: const <int?>[11, 33, 44]);
      expect(anchor, isNull);
    });
  });

  group('resultIdAt', () {
    const ids = <int?>[11, 22, 33, 44];

    test('범위 안이면 그 칸의 id', () {
      expect(resultIdAt(ids, 0), 11);
      expect(resultIdAt(ids, 2), 33);
      expect(resultIdAt(ids, 3), 44);
    });

    test('인덱스가 null이거나 범위를 벗어나면 던지지 않고 null', () {
      expect(resultIdAt(ids, null), isNull);
      expect(resultIdAt(ids, 4), isNull);
      expect(resultIdAt(ids, -1), isNull);
    });

    test('결과가 비어 있으면 null', () {
      expect(resultIdAt(const <int?>[], 0), isNull);
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

  group('tappedCardNeedsPin (target보다 위쪽 카드만 붙잡는다)', () {
    test('target보다 위쪽 카드는 붙잡아야 한다', () {
      expect(
        tappedCardNeedsPin(tappedIndex: 5, targetIndex: 10, itemCount: 100),
        isTrue,
      );
      expect(
        tappedCardNeedsPin(tappedIndex: 9, targetIndex: 10, itemCount: 100),
        isTrue,
      );
    });

    test('target 카드 자신은 붙잡지 않는다 (경계)', () {
      expect(
        tappedCardNeedsPin(tappedIndex: 10, targetIndex: 10, itemCount: 100),
        isFalse,
      );
    });

    test('target보다 아래쪽 카드는 붙잡지 않는다', () {
      expect(
        tappedCardNeedsPin(tappedIndex: 11, targetIndex: 10, itemCount: 100),
        isFalse,
      );
      expect(
        tappedCardNeedsPin(tappedIndex: 99, targetIndex: 0, itemCount: 100),
        isFalse,
      );
    });

    test('target이 0이면 아무 카드도 붙잡지 않는다 (기본 상태)', () {
      expect(
        tappedCardNeedsPin(tappedIndex: 0, targetIndex: 0, itemCount: 100),
        isFalse,
      );
      expect(
        tappedCardNeedsPin(tappedIndex: 7, targetIndex: 0, itemCount: 100),
        isFalse,
      );
    });

    test('목록이 줄어 기록된 target이 범위를 넘으면 SPL처럼 마지막 칸으로 줄여 비교한다', () {
      // 기록된 target 500, 칸은 100개 → 실제 target은 99. 마지막 카드(99)는 target 자신이다.
      expect(
        tappedCardNeedsPin(tappedIndex: 99, targetIndex: 500, itemCount: 100),
        isFalse,
      );
      expect(
        tappedCardNeedsPin(tappedIndex: 98, targetIndex: 500, itemCount: 100),
        isTrue,
      );
    });

    test('범위 밖 인덱스나 빈 목록은 던지지 않고 false', () {
      expect(
        tappedCardNeedsPin(tappedIndex: -1, targetIndex: 10, itemCount: 100),
        isFalse,
      );
      expect(
        tappedCardNeedsPin(tappedIndex: 100, targetIndex: 10, itemCount: 100),
        isFalse,
      );
      expect(
        tappedCardNeedsPin(tappedIndex: 0, targetIndex: 10, itemCount: 0),
        isFalse,
      );
    });
  });
}
