import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memora/screens/card_list_screen.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// 대량 목록(ScrollablePositionedList) 점프 = "다시 마운트" 방식의 계약.
///
/// 배경: SPL 0.3.8의 jumpTo(index)는 목록을 새로 만들지 않고 target만 바꾼다. 지금 target에서 뷰포트
/// 캐시 범위보다 먼 칸으로 점프하면 재활용된 SliverList 칸이 옛 칸의 오프셋을 물려받아 페이지 전체가
/// 밀린다. 그래서 (C2) 접기/보이기 때 누른 카드가 튀고, (F2) 새 검색 결과가 맨 위가 아닌 곳에서 열리고,
/// (F3) 검색을 닫은 뒤 앵커 카드가 화면 위로 벗어나고, (F4) 위치 복원 점프가 어긋났다.
///
/// 화면(sqlite 의존)은 못 띄우므로, 화면이 쓰는 같은 최상위 도우미(SplRemountController·
/// reanchorTappedCard·laidOutAboveListTarget)를 평범한 SPL 호스트에 붙여서 검증한다. 호스트의
/// 칸/탭 처리는 화면의 _buildCardItem/_toggleQuestionFold와 같은 모양(Builder → 탭 → 붙잡기 → setState)이다.
/// 기기 크기는 실기기(S20, 뷰포트 약 636dp, 목록 위쪽 약 193dp)와 같게 맞춘다.
///
/// "전제 확인" 테스트는 옛 방식(raw SPL jumpTo)이 실제로 이 SPL에서 틀어진다는 것을 보여 주는 대조군이다 —
/// 위의 고침 테스트가 아무것도 안 보는 테스트가 아님을 증명한다. SPL을 올려서 대조군이 초록→빨강이 되면
/// 다시 마운트 방식이 더는 필요 없을 수 있다는 신호이니 그때 재검토한다.

const double kListTop = 193; // 목록 위쪽 (앱바 + 검색창)
const double kVp = 636; // 뷰포트 높이

enum _Mode {
  /// 화면과 같은 방식: SplRemountController.jumpTo (다시 마운트)
  remount,

  /// 옛 방식 대조군: 평범한 SPL + ItemScrollController.jumpTo
  rawJump,
}

typedef _Pin = void Function(_Rig rig, BuildContext itemContext, int index);

/// 화면의 _keepTappedCardInPlace: 같은 reanchorTappedCard를 부른다.
void _pinReal(_Rig rig, BuildContext c, int i) {
  reanchorTappedCard(
    spl: rig.spl,
    itemContext: c,
    index: i,
    itemCount: rig.heights.length,
    kind: CardResizeKind.questionToggle, // 이 호스트는 질문 탭 모양 (위쪽 가장자리 고정)
    setState: rig.setOuter,
  );
}

void _pinNever(_Rig rig, BuildContext c, int i) {}

/// 옛 규칙(635d4bd): 화면 안에 있으면 무조건 raw jumpTo로 붙잡는다.
void _pin635(_Rig rig, BuildContext c, int i) {
  for (final p in rig.ipl.itemPositions.value) {
    if (p.index != i) continue;
    final a = pinAlignmentFor(p.itemLeadingEdge);
    if (a != null) rig.isc.jumpTo(index: i, alignment: a);
    return;
  }
}

/// 대조군: target 위쪽 칸만 붙잡되 raw jumpTo로 (다시 마운트가 아닌 방식).
void _pinRawAbove(_Rig rig, BuildContext c, int i) {
  final a = reanchorAlignmentBeforeResize(
    itemContext: c,
    positions: rig.ipl.itemPositions.value,
    index: i,
  );
  if (a != null) rig.isc.jumpTo(index: i, alignment: a);
}

class _Rig {
  _Rig(
    this.heights, {
    this.mode = _Mode.remount,
    this.pin = _pinReal,
    this.wrapInOpacity = false,
  });

  List<double> heights;
  final _Mode mode;
  final _Pin pin;
  final bool wrapInOpacity;

  final isc = ItemScrollController();
  final ipl = ItemPositionsListener.create();
  late final SplRemountController spl = SplRemountController(
    itemScrollController: isc,
    itemPositionsListener: ipl,
  );
  final folded = <int>{};
  bool showList = true;
  bool settling = false; // wrapInOpacity일 때 true면 투명 (화면의 _settlingSearchExit)
  late StateSetter setOuter;

  /// 화면의 _jumpSplTo 자리.
  void jump(int index, {double alignment = 0}) {
    if (mode == _Mode.remount) {
      spl.jumpTo(index, alignment: alignment, setState: setOuter);
    } else {
      isc.jumpTo(index: index, alignment: alignment);
    }
  }

  Widget _item(BuildContext context, int i) => Builder(
        builder: (itemContext) => GestureDetector(
          key: ValueKey('card$i'),
          behavior: HitTestBehavior.opaque,
          onTap: () {
            pin(this, itemContext, i);
            setOuter(() {
              if (!folded.remove(i)) folded.add(i);
            });
          },
          child: SizedBox(
            height: folded.contains(i) ? 60 : heights[i],
            child: Text('card $i'),
          ),
        ),
      );

  Widget _list() {
    if (mode == _Mode.remount) {
      return spl.build(
        itemCount: heights.length,
        itemBuilder: _item,
        physics: const ClampingScrollPhysics(),
      );
    }
    return SizedBox.expand(
      child: ScrollablePositionedList.builder(
        itemCount: heights.length,
        itemBuilder: _item,
        itemScrollController: isc,
        itemPositionsListener: ipl,
        physics: const ClampingScrollPhysics(),
      ),
    );
  }

  Widget build() => MaterialApp(
        home: Scaffold(
          body: Column(children: [
            const SizedBox(height: kListTop),
            SizedBox(
              height: kVp,
              child: StatefulBuilder(builder: (context, ss) {
                setOuter = ss;
                // 화면처럼 Stack의 자식으로 둔다 (목록 위에 스크롤 인디케이터가 얹히는 구조).
                // 점프 도우미는 부모가 Stack이어도 안전해야 한다 (SizedBox.expand 래퍼).
                final Widget list = showList ? _list() : const SizedBox();
                return Stack(children: [
                  wrapInOpacity
                      ? Opacity(opacity: settling ? 0.0 : 1.0, child: list)
                      : list,
                ]);
              }),
            ),
          ]),
        ),
      );
}

Future<void> _mount(WidgetTester tester, _Rig rig) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(rig.build());
  await tester.pump();
}

ScrollPosition _primary(WidgetTester t) =>
    t.state<ScrollableState>(find.byType(Scrollable).first).position;

Finder _card(int i) => find.byKey(ValueKey('card$i'));

double? _top(WidgetTester t, int i) {
  final f = _card(i);
  return f.evaluate().isEmpty ? null : t.getTopLeft(f).dy;
}

double _sum(List<double> h, int from, int to) {
  var s = 0.0;
  for (var i = from; i < to; i++) {
    s += h[i];
  }
  return s;
}

List<double> _randomHeights(int seed, int n) {
  final rnd = math.Random(seed);
  return [for (var i = 0; i < n; i++) 76.0 + 22.0 * (1 + rnd.nextInt(12))];
}

Future<void> _flings(WidgetTester tester, math.Random rnd, int n) async {
  for (var f = 0; f < n; f++) {
    await tester.fling(
      find.byType(ScrollablePositionedList),
      Offset(0, -(150 + rnd.nextInt(250)).toDouble()),
      (1000 + rnd.nextInt(3000)).toDouble(),
    );
    await tester.pumpAndSettle();
  }
}

/// 카드 1~15는 186dp, 나머지는 208dp. target 0에서 멀리 스크롤한 뒤 raw jumpTo로 붙잡으면
/// 재활용된 칸의 옛 오프셋(22dp 차이)이 쌓여 페이지가 밀리는 함정.
List<double> _trapHeights() =>
    [for (var i = 0; i < 50; i++) (i >= 1 && i <= 15) ? 186.0 : 208.0];

/// 카드 30~44(점프 target 45 바로 위)는 22dp 짧고 나머지는 208dp.
List<double> _reverseTrapHeights() =>
    [for (var i = 0; i < 50; i++) (i >= 30 && i <= 44) ? 186.0 : 208.0];

void main() {
  // ───────────────────────── C2: 접기/보이기 붙잡기 ─────────────────────────

  /// target 0에서 카드 20까지 스크롤(5 화면 분량)해 뷰포트 30% 위치에 두고 첫 탭.
  /// 반환: 탭 전후 카드 20 위쪽 가장자리 이동량(dp).
  Future<double> firstToggleAfterFarScroll(WidgetTester tester, _Rig rig) async {
    await _mount(tester, rig);
    _primary(tester)
        .jumpTo(_sum(rig.heights, 0, 20) - 0.3 * kVp); // target 0 그대로, 점프 없이 스크롤만
    await tester.pumpAndSettle();
    final before = _top(tester, 20)!;
    expect(before - kListTop, closeTo(0.3 * kVp, 0.5));
    await tester.tap(_card(20));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(rig.folded, contains(20));
    if (_card(20).evaluate().isEmpty) return double.negativeInfinity;
    // 바로 아래 칠해진 카드는 반드시 21번이어야 한다 (손가락 밑에 다른 카드가 미끄러져 오지 않는다)
    expect(_top(tester, 21), closeTo(_top(tester, 20)! + 60, 0.5));
    return _top(tester, 20)! - before;
  }

  group('C2 접기/보이기: target 이상 칸은 건드리지 않는다', () {
    testWidgets('arm 1: target 0에서 멀리 스크롤한 칸을 눌러도 제자리 · 다시 마운트 안 함',
        (tester) async {
      final rig = _Rig(_trapHeights());
      await _mount(tester, rig);
      _primary(tester).jumpTo(_sum(rig.heights, 0, 20) - 0.3 * kVp);
      await tester.pumpAndSettle();
      final before = _top(tester, 20)!;
      final tileBefore = tester.element(_card(20));
      final epochBefore = rig.spl.epoch;

      await tester.tap(_card(20));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(rig.folded, contains(20));
      // target 이상 칸은 위쪽 가장자리가 원래 고정이다 — 붙잡으려고 목록을 다시 마운트하면 안 된다
      // (보이는 칸이 전부 새로 만들어져 물결·접근성 포커스가 끊긴다).
      expect(rig.spl.epoch, epochBefore, reason: 'target 이상 칸은 다시 마운트하지 않는다');
      expect(identical(tester.element(_card(20)), tileBefore), isTrue,
          reason: '같은 칸 요소가 그대로 살아 있어야 한다');
      expect(_top(tester, 20)! - before, closeTo(0, 1.0));
      expect(_top(tester, 21), closeTo(_top(tester, 20)! + 60, 0.5));
    });

    testWidgets('arm 2 (전제 확인): 옛 규칙(635d4bd)은 raw jumpTo가 페이지를 100dp 넘게 민다',
        (tester) async {
      final rig = _Rig(_trapHeights(), mode: _Mode.rawJump, pin: _pin635);
      final d = await firstToggleAfterFarScroll(tester, rig);
      // ignore: avoid_print
      print('635d4bd rule moved the tapped card by $d dp');
      expect(d, lessThan(-100));
    });

    testWidgets('arm 3: 점프 target 위쪽 칸은 붙잡아서 제자리 (다시 마운트)', (tester) async {
      final rig = _Rig(
          [for (var i = 0; i < 50; i++) 150.0 + (i % 4) * 40]);
      await _mount(tester, rig);
      rig.jump(40); // 위치 복원·검색 닫기·스크롤바가 착지시킨 상황
      await tester.pumpAndSettle();
      expect(rig.spl.targetIndex, 40, reason: '점프와 같이 target이 기록돼야 한다');
      _primary(tester).jumpTo(_primary(tester).pixels - 500); // 사용자가 조금 위로 스크롤
      await tester.pumpAndSettle();
      final t = rig.ipl.itemPositions.value
          .where((p) =>
              p.index < 40 && p.itemLeadingEdge >= 0.05 && p.itemLeadingEdge <= 0.8)
          .map((p) => p.index)
          .reduce(math.min);
      final before = _top(tester, t)!;
      final epochBefore = rig.spl.epoch;

      await tester.tap(_card(t));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(rig.spl.epoch, greaterThan(epochBefore), reason: 'target 위쪽 칸은 붙잡아야 한다');
      expect(_top(tester, t)! - before, closeTo(0, 1.0));
    });

    testWidgets('arm 4 (전제 확인): 붙잡지 않으면 target 위쪽 칸이 미끄러진다', (tester) async {
      final rig = _Rig(
          [for (var i = 0; i < 50; i++) 150.0 + (i % 4) * 40],
          pin: _pinNever);
      await _mount(tester, rig);
      rig.jump(40);
      await tester.pumpAndSettle();
      _primary(tester).jumpTo(_primary(tester).pixels - 500);
      await tester.pumpAndSettle();
      final t = rig.ipl.itemPositions.value
          .where((p) =>
              p.index < 40 && p.itemLeadingEdge >= 0.05 && p.itemLeadingEdge <= 0.8)
          .map((p) => p.index)
          .reduce(math.min);
      final before = _top(tester, t)!;
      await tester.tap(_card(t));
      await tester.pumpAndSettle();
      final d = _top(tester, t)! - before;
      // ignore: avoid_print
      print('no re-anchor above target moved the tapped card by $d dp');
      expect(d.abs(), greaterThan(50));
    });

    /// target 45 착지 뒤 위로 5 화면 분량 스크롤한 칸(20번)을 눌러 첫 토글. 이동량(dp) 반환.
    Future<double> toggleFarAboveTarget(WidgetTester tester, _Rig rig) async {
      await _mount(tester, rig);
      rig.jump(45);
      await tester.pumpAndSettle();
      final dist = _sum(rig.heights, 20, 45);
      _primary(tester).jumpTo(_primary(tester).pixels - dist - 0.3 * kVp);
      await tester.pumpAndSettle();
      final before = _top(tester, 20)!;
      await tester.tap(_card(20));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(rig.folded, contains(20));
      expect(rig.isc.isAttached, isTrue);
      if (_card(20).evaluate().isEmpty) return double.infinity;
      expect(_top(tester, 21), closeTo(_top(tester, 20)! + 60, 0.5));
      return _top(tester, 20)! - before;
    }

    testWidgets('arm 5: target에서 5 화면 위쪽 칸도 다시 마운트로 제자리', (tester) async {
      final d = await toggleFarAboveTarget(tester, _Rig(_reverseTrapHeights()));
      expect(d, closeTo(0, 1.0));
    });

    testWidgets('arm 5 (전제 확인): raw jumpTo로 붙잡으면 멀리 위쪽 칸이 100dp 넘게 밀린다',
        (tester) async {
      final d = await toggleFarAboveTarget(
        tester,
        _Rig(_reverseTrapHeights(), mode: _Mode.rawJump, pin: _pinRawAbove),
      );
      // ignore: avoid_print
      print('jumpTo re-anchor far above target moved the tapped card by $d dp');
      expect(d.abs(), greaterThan(100));
    });

    testWidgets('arm 6: 점프가 아닌 새 마운트 뒤에는 기록된 target이 실제보다 커도 불필요하게 다시 마운트하지 않는다',
        (tester) async {
      // 점프(target 40) 뒤 목록이 사라졌다가(스피너 등) 다시 올라오면 새 SPL은 target 0이다. 기록된
      // target(40)은 실제보다 크다 — 값싼 사전 검사(인덱스)는 통과시키지만 렌더 트리 판별이 막아야 한다.
      final rig = _Rig(_trapHeights());
      await _mount(tester, rig);
      rig.jump(40);
      await tester.pumpAndSettle();
      rig.setOuter(() => rig.showList = false);
      await tester.pump();
      rig.setOuter(() => rig.showList = true);
      await tester.pumpAndSettle();
      expect(rig.spl.targetIndex, 40, reason: '이 상황이 맞는지 확인: 기록된 target은 그대로');
      expect(_top(tester, 0), closeTo(kListTop, 1.0), reason: '새 마운트는 맨 위에서 시작');

      _primary(tester).jumpTo(_sum(rig.heights, 0, 20) - 0.3 * kVp);
      await tester.pumpAndSettle();
      final before = _top(tester, 20)!;
      final epochBefore = rig.spl.epoch;
      await tester.tap(_card(20)); // 20 < 기록된 target 40 이지만 실제로는 target(0) 이상 칸
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(rig.folded, contains(20));
      expect(rig.spl.epoch, epochBefore, reason: '실제 target 이상 칸은 다시 마운트하지 않는다');
      expect(_top(tester, 20)! - before, closeTo(0, 1.0));
    });

    testWidgets('붙잡기는 목록이 안 떠 있으면(isAttached=false) 아무것도 하지 않는다',
        (tester) async {
      final rig = _Rig(_trapHeights());
      await _mount(tester, rig);
      rig.setOuter(() => rig.showList = false);
      await tester.pump();
      expect(rig.isc.isAttached, isFalse);
      final epochBefore = rig.spl.epoch;
      final pinned = reanchorTappedCard(
        spl: rig.spl,
        itemContext: tester.element(find.byType(Scaffold)),
        index: 5,
        itemCount: 50,
        kind: CardResizeKind.questionToggle,
        setState: rig.setOuter,
      );
      expect(pinned, isFalse);
      expect(rig.spl.epoch, epochBefore);
    });
  });

  // ─────────────── laidOutAboveListTarget = 인덱스 규칙과 같은지 (렌더 트리 기준) ───────────────

  group('laidOutAboveListTarget (렌더 트리) ↔ tappedCardNeedsPin (인덱스)', () {
    void expectEquivalent(WidgetTester tester, _Rig rig, {required int target}) {
      var checked = 0;
      var above = 0;
      for (var i = 0; i < rig.heights.length; i++) {
        final f = _card(i);
        if (f.evaluate().isEmpty) continue; // 레이아웃된 칸만
        final byTree = laidOutAboveListTarget(tester.element(f));
        final byIndex = tappedCardNeedsPin(
          tappedIndex: i,
          targetIndex: target,
          itemCount: rig.heights.length,
        );
        expect(byTree, byIndex, reason: 'card $i (target $target)');
        expect(byTree, i < target, reason: 'card $i (target $target)');
        checked++;
        if (byTree) above++;
      }
      expect(checked, greaterThan(3));
      // 대조가 의미 있으려면 위쪽 칸도 아래쪽 칸도 실제로 검사했어야 한다.
      if (target > 0) expect(above, greaterThan(0));
      expect(checked - above, greaterThan(0));
    }

    testWidgets('새 마운트(target 0): 레이아웃된 칸은 전부 target 이상', (tester) async {
      final rig = _Rig(_trapHeights());
      await _mount(tester, rig);
      expectEquivalent(tester, rig, target: 0);
    });

    testWidgets('점프(target 40) 뒤 위로 스크롤: 40 미만만 위쪽 칸', (tester) async {
      final rig = _Rig(_trapHeights());
      await _mount(tester, rig);
      rig.jump(40);
      await tester.pumpAndSettle();
      _primary(tester).jumpTo(_primary(tester).pixels - 600);
      await tester.pumpAndSettle();
      expect(rig.spl.targetIndex, 40);
      expectEquivalent(tester, rig, target: 40);
    });
  });

  // ───────────── F2 · F3 · F4: 점프가 정확히 그 자리에 착지한다 ─────────────

  /// 전체 목록(150장)을 3번 fling한 뒤 [action]. 반환: 목표 카드가 맨 위(±1dp)에 오지 못한 시드 수.
  Future<int> countMisses(
    WidgetTester tester,
    _Mode mode,
    Iterable<int> seeds,
    Future<int> Function(_Rig rig, math.Random rnd, int seed) scenario,
  ) async {
    var off = 0;
    for (final seed in seeds) {
      final rnd = math.Random(seed * 31 + 7);
      final rig = _Rig(_randomHeights(seed, 150), mode: mode);
      await _mount(tester, rig);
      await _flings(tester, rnd, 3);
      final target = await scenario(rig, rnd, seed);
      final top = _top(tester, target);
      if (top == null || (top - kListTop).abs() > 1) off++;
      expect(tester.takeException(), isNull, reason: 'seed $seed');
    }
    return off;
  }

  group('F2 새 검색 결과 묶음은 맨 위에서 열린다', () {
    Future<int> newResultSet(_Rig rig, math.Random rnd, int seed) async {
      // _performSearch: setState(결과로 교체) 직후 _jumpSplTo(0)
      final results = _randomHeights(seed + 1000, 50);
      rig.setOuter(() => rig.heights = results);
      rig.jump(0);
      return 0;
    }

    testWidgets('깊이 스크롤한 뒤 새 결과: 카드 0이 항상 맨 위', (tester) async {
      final off = await countMisses(tester, _Mode.remount, [for (var s = 301; s <= 340; s++) s],
          (rig, rnd, seed) async {
        final t = await newResultSet(rig, rnd, seed);
        await tester.pump();
        await tester.pumpAndSettle();
        return t;
      });
      expect(off, 0);
    });

    testWidgets('(전제 확인) raw jumpTo(0)는 일부 시드에서 맨 위가 아니다', (tester) async {
      final off = await countMisses(tester, _Mode.rawJump, [for (var s = 301; s <= 340; s++) s],
          (rig, rnd, seed) async {
        final t = await newResultSet(rig, rnd, seed);
        await tester.pump();
        await tester.pumpAndSettle();
        return t;
      });
      // ignore: avoid_print
      print('raw jumpTo(0): new result set did not open at the top: $off/40');
      expect(off, greaterThan(0));
    });
  });

  group('F3 검색을 닫으면 앵커 카드가 맨 위에 온다', () {
    Future<int> run(WidgetTester tester, _Mode mode) async {
      var off = 0;
      var n = 0;
      for (var seed = 401; seed <= 440; seed++) {
        final rnd = math.Random(seed * 31 + 7);
        final full = _randomHeights(seed, 150);
        final rig = _Rig([for (var r = 0; r < 50; r++) full[3 * r]], mode: mode);
        await _mount(tester, rig);
        await _flings(tester, rnd, 3);
        final vis = rig.ipl.itemPositions.value
            .where((q) => q.itemLeadingEdge >= 0)
            .map((q) => q.index)
            .toList()
          ..sort();
        if (vis.isEmpty) continue;
        final anchor = 3 * vis.first; // 화면 맨 위 결과 → 전체 목록 인덱스
        rig.setOuter(() => rig.heights = full);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (rig.isc.isAttached) rig.jump(anchor);
        });
        await tester.pump();
        await tester.pump();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'seed $seed');
        n++;
        final top = _top(tester, anchor);
        if (top == null || (top - kListTop).abs() > 1) off++;
      }
      expect(n, greaterThan(30));
      return off;
    }

    testWidgets('멀리 스크롤한 결과 목록을 닫아도 앵커가 항상 맨 위', (tester) async {
      expect(await run(tester, _Mode.remount), 0);
    });

    testWidgets('(전제 확인) raw jumpTo(앵커)는 일부 시드에서 앵커가 화면 밖/아래로 벗어난다',
        (tester) async {
      final off = await run(tester, _Mode.rawJump);
      // ignore: avoid_print
      print('raw jumpTo(anchor): exit anchor landed off: $off');
      expect(off, greaterThan(0));
    });
  });

  group('F4 기존 위치 복원 점프(savedIndex)도 정확히 착지한다', () {
    Future<int> restore(_Rig rig, math.Random rnd, int seed) async {
      // _loadCards 끝의 위치 복원: 보이던 첫 칸 주변의 먼 칸으로 post-frame 점프
      final first = rig.ipl.itemPositions.value.map((q) => q.index).reduce(math.min);
      final x = math.min(149, first + rnd.nextInt(40));
      rig.jump(x);
      return x;
    }

    testWidgets('먼 칸 점프가 항상 그 칸을 맨 위에 둔다', (tester) async {
      final off = await countMisses(tester, _Mode.remount, [for (var s = 201; s <= 240; s++) s],
          (rig, rnd, seed) async {
        final x = await restore(rig, rnd, seed);
        await tester.pump();
        await tester.pumpAndSettle();
        return x;
      });
      expect(off, 0);
    });

    testWidgets('(전제 확인) raw jumpTo(index)는 일부 시드에서 어긋난다', (tester) async {
      final off = await countMisses(tester, _Mode.rawJump, [for (var s = 201; s <= 240; s++) s],
          (rig, rnd, seed) async {
        final x = await restore(rig, rnd, seed);
        await tester.pump();
        await tester.pumpAndSettle();
        return x;
      });
      // ignore: avoid_print
      print('raw jumpTo(index): far jump landed off: $off/40');
      expect(off, greaterThan(0));
    });
  });

  // ───────────────────── 다시 마운트 후에도 컨트롤러가 붙어 있다 ─────────────────────

  group('다시 마운트의 안전성', () {
    testWidgets('다시 마운트 뒤에도 isAttached이고 위치 리스너가 새 위치로 갱신된다', (tester) async {
      final rig = _Rig(_randomHeights(5, 100));
      await _mount(tester, rig);
      var notifications = 0;
      rig.ipl.itemPositions.addListener(() => notifications++);
      expect(rig.isc.isAttached, isTrue);

      rig.jump(30);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(rig.isc.isAttached, isTrue, reason: '옛 SPL이 떼어낸 뒤 새 SPL이 붙어야 한다');
      var p30 = rig.ipl.itemPositions.value.where((p) => p.index == 30);
      expect(p30, isNotEmpty, reason: '위치 리스너가 새 SPL의 위치를 받아야 한다');
      expect(p30.first.itemLeadingEdge, closeTo(0, 0.01));
      expect(notifications, greaterThan(0));

      final before = notifications;
      rig.jump(70);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(rig.isc.isAttached, isTrue);
      expect(notifications, greaterThan(before));
      expect(rig.ipl.itemPositions.value.any((p) => p.index == 70), isTrue);
      expect(rig.ipl.itemPositions.value.any((p) => p.index == 30), isFalse,
          reason: '옛 위치가 남아 있으면 안 된다');

      // 컨트롤러가 여전히 쓸 수 있다 (붙잡기·스크롤바 점프가 계속 동작)
      rig.jump(10, alignment: 0.25);
      await tester.pumpAndSettle();
      expect(_top(tester, 10)! - kListTop, closeTo(0.25 * kVp, 1.0));
    });

    testWidgets('점프 없는 일반 재빌드(제자리 카드 갱신·접기 상태 변경)는 목록을 다시 마운트하지 않는다',
        (tester) async {
      // 랜덤 정렬의 _refreshCardInList·_removeCardsLocally 같은 제자리 갱신은 setState만 부른다.
      // 키(epoch)가 점프 때만 바뀌어야 스크롤 위치·칸 요소가 그대로 유지된다.
      final rig = _Rig(_randomHeights(11, 100));
      await _mount(tester, rig);
      rig.jump(30);
      await tester.pumpAndSettle();
      final epochBefore = rig.spl.epoch;
      final tileBefore = tester.element(_card(30));
      final topBefore = _top(tester, 30)!;

      rig.setOuter(() => rig.heights[31] = rig.heights[31] + 40); // 카드 하나 제자리 갱신
      await tester.pumpAndSettle();
      rig.setOuter(() => rig.heights = [...rig.heights]); // 목록 통째 재빌드
      await tester.pumpAndSettle();

      expect(rig.spl.epoch, epochBefore);
      expect(identical(tester.element(_card(30)), tileBefore), isTrue);
      expect(_top(tester, 30), closeTo(topBefore, 0.5));
    });

    testWidgets('알림 모드(스모크): 첫 마운트 뒤 post-frame에서 대상 카드로 점프하면 붙어 있고 그 카드가 맨 위', (tester) async {
      // _initLoad: setState(카드 로드) → post-frame에서 isAttached 확인 뒤 _jumpSplTo(targetIndex)
      final rig = _Rig(_trapHeights()); // 칸 높이가 들쭉날쭉해야 raw jumpTo가 틀어진다
      await _mount(tester, rig);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (rig.isc.isAttached) rig.jump(45);
      });
      rig.setOuter(() {}); // 카드가 로드된 프레임(setState) — 그 프레임 뒤에 위 콜백이 돈다
      await tester.pump();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(rig.isc.isAttached, isTrue);
      expect(_top(tester, 45), closeTo(kListTop, 1.0));
    });

    testWidgets('같은 프레임에 점프가 여러 번 불리면 마지막 하나만 남는다', (tester) async {
      final rig = _Rig(_randomHeights(6, 100));
      await _mount(tester, rig);
      rig.jump(10);
      rig.jump(60);
      rig.jump(25);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(rig.isc.isAttached, isTrue);
      expect(_top(tester, 25), closeTo(kListTop, 1.0));
    });

    testWidgets('점프가 아닌 새 마운트(스피너→목록)는 옛 시작 위치가 아니라 맨 위에서 열린다', (tester) async {
      final rig = _Rig(_randomHeights(7, 100));
      await _mount(tester, rig);
      rig.jump(40);
      await tester.pumpAndSettle();
      expect(_top(tester, 40), closeTo(kListTop, 1.0));
      expect(rig.spl.initialIndex, 0, reason: '새 SPL이 시작 위치를 읽은 뒤에는 되돌려야 한다');
      rig.setOuter(() => rig.showList = false);
      await tester.pump();
      rig.setOuter(() => rig.showList = true);
      await tester.pumpAndSettle();
      expect(_top(tester, 0), closeTo(kListTop, 1.0));
    });

    testWidgets('같은 프레임에 더 새로운 점프가 있으면 앞 점프의 되돌리기가 그 시작 위치를 지우지 않는다',
        (tester) async {
      final rig = _Rig(_randomHeights(8, 100));
      await _mount(tester, rig);
      // post-frame 콜백은 등록 순서대로 돈다. 아래 순서면 "점프(20)"가 "점프(10)의 되돌리기"보다 먼저 돈다.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        rig.spl.jumpTo(20, setState: rig.setOuter);
      });
      rig.spl.jumpTo(10, setState: rig.setOuter);
      await tester.pump(); // 10으로 마운트 → post-frame에서 20 점프 → 앞 점프 되돌리기는 건너뛰어야 한다
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(_top(tester, 20), closeTo(kListTop, 1.0));
    });

    testWidgets('투명(Opacity 0) 목록 안에서도 붙어 있고, 다시 보이는 첫 프레임부터 정확한 자리 (L4)',
        (tester) async {
      final rig = _Rig(_randomHeights(9, 100), wrapInOpacity: true)..settling = true;
      await _mount(tester, rig);
      expect(rig.isc.isAttached, isTrue);

      // _settleAfterSearchExit: 투명한 채로 점프 → 같은 프레임에 finally로 다시 보이게
      rig.jump(30);
      await tester.pumpAndSettle();
      expect(rig.isc.isAttached, isTrue);
      expect(rig.ipl.itemPositions.value.any((p) => p.index == 30), isTrue,
          reason: '투명해도 레이아웃은 되므로 위치를 읽을 수 있어야 한다');
      expect(_top(tester, 30), closeTo(kListTop, 1.0));

      rig.jump(55);
      rig.setOuter(() => rig.settling = false);
      await tester.pump(); // 딱 한 프레임
      expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 1.0);
      expect(_top(tester, 55), closeTo(kListTop, 1.0),
          reason: '다시 보이는 첫 프레임부터 앵커가 맨 위여야 한다 (엉뚱한 위치가 번쩍이면 안 된다)');
    });

    testWidgets('래퍼(SizedBox.expand) 덕에 Stack 직계 자식이어도 키 교체가 안전하다', (tester) async {
      // _Rig는 목록을 Stack의 자식으로 둔다. 래퍼가 없으면 새 SPL이 옛 SPL을 치우기 전에 붙으려다
      // ItemScrollController assert가 나고 isAttached가 false가 된다.
      final rig = _Rig(_randomHeights(10, 60));
      await _mount(tester, rig);
      rig.jump(20);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(rig.isc.isAttached, isTrue);
      expect(rig.ipl.itemPositions.value, isNotEmpty);
    });
  });

  // ─────────────── 화면 소스가 SPL jumpTo를 직접 부르지 못하게 하는 가드 ───────────────

  group('화면 소스 가드', () {
    late String source;

    setUpAll(() {
      final raw = File('lib/screens/card_list_screen.dart').readAsStringSync();
      // 주석 제거 (설명 주석이 호출처럼 보이는 것 방지)
      source = raw
          .split('\n')
          .map((l) => l.replaceFirst(RegExp(r'//[^\r\n]*'), ''))
          .join('\n');
    });

    test('ItemScrollController.jumpTo/scrollTo를 직접 부르지 않는다 (SplRemountController만)', () {
      final direct = RegExp(r'[iI]temScrollController\s*\.\s*(jumpTo|scrollTo)\s*\(');
      expect(direct.hasMatch(source), isFalse,
          reason: 'SPL jumpTo는 먼 칸으로 점프하면 페이지 전체를 민다 — _jumpSplTo(다시 마운트)를 쓸 것');
    });

    test('ScrollablePositionedList는 SplRemountController.build 한 곳에서만 만든다', () {
      expect(RegExp(r'ScrollablePositionedList\.builder\(').allMatches(source).length, 1);
    });

    // ── 배선 가드 (C2b-3): 도우미가 아무리 맞아도 화면이 그 도우미를 부르지 않거나 엉뚱한 인자를 주면
    //    기기에서만 깨진다(화면은 sqlite 때문에 위젯 테스트로 못 띄운다). 호출 자리와 인자를 소스에서 확인한다.

    String body(String signature) {
      final b = functionBody(source, signature);
      expect(b, isNotNull, reason: '함수 $signature 를 소스에서 못 찾았다 (이름이 바뀌었으면 가드를 옮길 것)');
      expect(b!.length, greaterThan(20), reason: '$signature 본문이 비었다');
      return b;
    }

    void expectIn(String b, RegExp re, String what) {
      expect(re.hasMatch(b), isTrue, reason: what);
    }

    test('접기/보이기는 붙잡기(_keepTappedCardInPlace)를 setState 전에 칸 컨텍스트(itemContext)와 의도(kind)로 부른다', () {
      // 질문 탭: 늘어나든 줄어들든 위쪽 가장자리 고정 → 항상 questionToggle.
      final q = body('void _toggleQuestionFold');
      final qPin = RegExp(
              r'_keepTappedCardInPlace\(\s*cardId\s*,\s*itemContext\s*,\s*CardResizeKind\.questionToggle\s*\)')
          .firstMatch(q);
      expect(qPin, isNotNull,
          reason: '_toggleQuestionFold가 _keepTappedCardInPlace(cardId, itemContext, CardResizeKind.questionToggle)를 부르지 않는다');
      expect(q.indexOf('setState('), greaterThan(qPin!.start),
          reason: '_toggleQuestionFold: 붙잡기는 높이를 바꾸는 setState보다 먼저여야 한다');
      expect(q.contains('answerHide') || q.contains('answerReveal'), isFalse,
          reason: '질문 탭이 답 숨기기(아래쪽 고정) 의도를 쓰면 잘린 카드의 손가락 밑 카드가 바뀐다');

      // 답 탭: 숨김 모드일 때만(answerTapResizeKind가 null이면 건너뜀), 지금 보이는 상태에서 의도를 정한다.
      final a = body('void _toggleAnswerReveal');
      final kindRe = RegExp(
          r'final\s+kind\s*=\s*answerTapResizeKind\(\s*allAnswersHidden:\s*_allAnswersHidden\s*,\s*answerRevealed:\s*_revealedCards\.contains\(\s*cardId\s*\)\s*,?\s*\)\s*;');
      final kindM = kindRe.firstMatch(a);
      expect(kindM, isNotNull,
          reason: '_toggleAnswerReveal이 answerTapResizeKind(allAnswersHidden: _allAnswersHidden, answerRevealed: _revealedCards.contains(cardId))로 의도를 정하지 않는다');
      final aPin = RegExp(
              r'if\s*\(\s*kind\s*!=\s*null\s*\)\s*_keepTappedCardInPlace\(\s*cardId\s*,\s*itemContext\s*,\s*kind\s*\)\s*;')
          .firstMatch(a);
      expect(aPin, isNotNull,
          reason: '_toggleAnswerReveal이 kind != null일 때만 _keepTappedCardInPlace(cardId, itemContext, kind)를 부르지 않는다 (숨김 모드가 아니면 붙잡기 금지)');
      expect(aPin!.start, greaterThan(kindM!.end));
      expect(a.indexOf('setState('), greaterThan(aPin.start),
          reason: '_toggleAnswerReveal: 붙잡기는 높이를 바꾸는 setState보다 먼저여야 한다');
    });

    test('_keepTappedCardInPlace는 reanchorTappedCard에 컨트롤러·칸 컨텍스트·setState를 넘긴다', () {
      final b = body('void _keepTappedCardInPlace');
      expectIn(b, RegExp(r'reanchorTappedCard\('), 'reanchorTappedCard 호출');
      expectIn(b, RegExp(r'spl:\s*_spl\b'), 'spl: _spl');
      expectIn(b, RegExp(r'itemContext:\s*itemContext\b'), 'itemContext: itemContext');
      expectIn(b, RegExp(r'index:\s*index\b'), 'index: index');
      expectIn(b, RegExp(r'itemCount:\s*_cards\.length\b'), 'itemCount: _cards.length');
      expectIn(b, RegExp(r'kind:\s*kind\b'), 'kind: kind (호출자가 말한 의도를 그대로 넘긴다)');
      expectIn(b, RegExp(r'setState:\s*setState\b'), 'setState: setState');
    });

    test('칸 빌더는 접기/보이기에 목록 context가 아니라 칸 안쪽 itemContext(Builder)를 넘긴다', () {
      final b = body('Widget _buildCardItem');
      expectIn(b, RegExp(r'Builder\(\s*builder:\s*\(\s*itemContext\s*\)'), 'Builder(builder: (itemContext)');
      expectIn(
          b,
          RegExp(r'onQuestionTap:[^;]*?_toggleQuestionFold\(\s*card\s*,\s*itemContext\s*\)'),
          'onQuestionTap → _toggleQuestionFold(card, itemContext)');
      expectIn(
          b,
          RegExp(r'onAnswerTap:[^;]*?_toggleAnswerReveal\(\s*card\s*,\s*itemContext\s*\)'),
          'onAnswerTap → _toggleAnswerReveal(card, itemContext)');
      expect(RegExp(r'_toggle(QuestionFold|AnswerReveal)\(\s*card\s*,\s*context\s*\)').hasMatch(b), isFalse,
          reason: '목록 context를 넘기면 칸의 렌더 객체가 아니라 목록 전체를 보게 된다');
    });

    test('스크롤바 썸 드래그: 시작에서 beginThumbDrag, 점프는 thumbDragJumpTo(_pendingJumpIndex)', () {
      final start = functionBodyAfter(source, 'onVerticalDragStart: (details)');
      expect(start, isNotNull);
      expectIn(start!, RegExp(r'_spl\.beginThumbDrag\(\s*\)'), 'onVerticalDragStart에서 _spl.beginThumbDrag()');
      expectIn(start, RegExp(r'_jumpToFraction\('), 'onVerticalDragStart에서 _jumpToFraction');
      final b = body('void _jumpToFraction');
      expectIn(b, RegExp(r'_spl\.thumbDragJumpTo\(\s*_pendingJumpIndex\s*,\s*setState:\s*setState\s*\)'),
          '_jumpToFraction의 post-frame에서 _spl.thumbDragJumpTo(_pendingJumpIndex, setState: setState)');
    });

    test('새 검색 결과 묶음은 맨 위로 점프한다 (_performSearch)', () {
      final b = body('Future<void> _performSearch');
      expectIn(
          b,
          RegExp(r'if\s*\(\s*isNewResultSet\s*\)\s*\{[^}]*_jumpSplTo\(\s*0\s*\)'),
          'if (isNewResultSet) { ... _jumpSplTo(0) }');
    });

    test('검색을 닫으면 앵커 칸(없으면 맨 위)으로 점프한다 (_settleAfterSearchExit)', () {
      final b = body('void _settleAfterSearchExit');
      expectIn(b, RegExp(r'_jumpSplTo\(\s*idx\s*>=\s*0\s*\?\s*idx\s*:\s*0\s*\)'),
          '_jumpSplTo(idx >= 0 ? idx : 0)');
      expectIn(b, RegExp(r'_finishSearchExitSettle\(\s*\)'), 'finally에서 _finishSearchExitSettle');
    });

    test('알림 진입 점프와 위치 복원 점프도 _jumpSplTo로 한다', () {
      expectIn(body('Future<void> _initLoad'), RegExp(r'_jumpSplTo\(\s*targetIndex\s*\)'),
          '_initLoad: _jumpSplTo(targetIndex)');
      expectIn(body('Future<void> _loadCards'), RegExp(r'_jumpSplTo\(\s*idx\s*\)'),
          '_loadCards 위치 복원: _jumpSplTo(idx)');
    });

    test('_jumpSplTo는 컨트롤러 jumpTo로만 간다', () {
      expectIn(body('void _jumpSplTo'),
          RegExp(r'_spl\.jumpTo\(\s*index\s*,\s*alignment:\s*alignment\s*,\s*setState:\s*setState\s*\)'),
          '_spl.jumpTo(index, alignment: alignment, setState: setState)');
    });

    // 가드 도구 자체의 대조군: 정규식·본문 추출이 "좋은 소스"는 통과시키고 "깨진 소스"는 잡는지.
    test('가드 대조군: 좋은 소스는 통과, 깨뜨린 소스(호출 삭제·context 전달·본문 밖)는 실패', () {
      const good = '''
class S {
  void _toggleAnswerReveal(CardModel card, BuildContext itemContext) {
    final cardId = card.id;
    _keepTappedCardInPlace(cardId, itemContext);
    setState(() { _revealed.add(cardId); });
  }
  void other({int a = 0}) {
    final cardId = 1;
    _keepTappedCardInPlace(cardId, itemContext);
  }
}''';
      final pinRe = RegExp(r'_keepTappedCardInPlace\(\s*cardId\s*,\s*itemContext\s*\)');
      final g = functionBody(good, 'void _toggleAnswerReveal')!;
      expect(pinRe.hasMatch(g), isTrue);
      // 호출 삭제
      final removed = good.replaceFirst('_keepTappedCardInPlace(cardId, itemContext);', '');
      expect(pinRe.hasMatch(functionBody(removed, 'void _toggleAnswerReveal')!), isFalse);
      // 목록 context 전달
      final wrongCtx = good.replaceFirst('(cardId, itemContext)', '(cardId, context)');
      expect(pinRe.hasMatch(functionBody(wrongCtx, 'void _toggleAnswerReveal')!), isFalse);
      // 다른 함수 본문에 같은 호출이 있어도 이 함수 본문이 아니면 잡는다 (본문 범위 검사)
      final moved = good.replaceFirst('_keepTappedCardInPlace(cardId, itemContext);\n    setState', 'setState');
      expect(moved, isNot(good), reason: '대조군 치환이 실제로 일어나야 한다');
      expect(pinRe.hasMatch(moved), isTrue, reason: '소스 전체에는 같은 호출이 남아 있다(다른 함수)');
      expect(pinRe.hasMatch(functionBody(moved, 'void _toggleAnswerReveal')!), isFalse);
      expect(pinRe.hasMatch(functionBody(good, 'void other')!), isTrue,
          reason: '이름 있는 매개변수({}) 뒤의 본문도 찾는다');
      expect(functionBody(good, 'void noSuchFunction'), isNull);
      // 닫는 중괄호를 지나쳐 다음 함수까지 먹지 않는다
      expect(functionBody(good, 'void _toggleAnswerReveal')!.contains('void other'), isFalse);
    });
  });
}

/// [signature]( 로 시작하는 함수 선언의 본문(`{ ... }` 안쪽). 소스에 없으면 null.
/// 매개변수 목록의 괄호를 짝 맞춰 건너뛴 뒤(이름 있는 매개변수의 `{}` 때문에 단순히 첫 `{`를 찾으면
/// 안 된다) 본문 중괄호를 짝 맞춰 찾는다.
String? functionBody(String source, String signature) {
  final at = source.indexOf('$signature(');
  if (at < 0) return null;
  var i = source.indexOf('(', at);
  var depth = 0;
  for (; i < source.length; i++) {
    final c = source[i];
    if (c == '(') depth++;
    if (c == ')') {
      depth--;
      if (depth == 0) break;
    }
  }
  return _braced(source, i + 1);
}

/// [marker] 바로 뒤(공백 제외)에 오는 `{ ... }` 블록의 안쪽 (예: 클로저 `onVerticalDragStart: (details) {`).
String? functionBodyAfter(String source, String marker) {
  final at = source.indexOf(marker);
  if (at < 0) return null;
  return _braced(source, at + marker.length);
}

String? _braced(String source, int from) {
  var i = source.indexOf('{', from);
  if (i < 0) return null;
  // `) async {` 처럼 `{` 앞에 `;`가 먼저 나오면 본문이 아니라 선언만 있는 것이다.
  final semi = source.indexOf(';', from);
  if (semi >= 0 && semi < i) return null;
  final start = i + 1;
  var depth = 0;
  for (; i < source.length; i++) {
    final c = source[i];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return source.substring(start, i);
    }
  }
  return null;
}
