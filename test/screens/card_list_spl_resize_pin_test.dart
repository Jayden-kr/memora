import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memora/screens/card_list_screen.dart';
import 'package:memora/widgets/card_tile.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// 접기/보이기 붙잡기(keepTappedCardUnderFinger / keptTopAfterResize)의 계약.
///
/// - keptTopAfterResize(순수 규칙): 커지거나 높이를 모르면 위쪽 가장자리 그대로, 줄어들면 손가락이 줄어든 카드의
///   위/아래 가장자리 안쪽이 되도록 위쪽을 최소한만 내리고(위로는 안 올린다) 스크롤 범위 안으로 자른다.
///   진짜 CardTile로 두 목록(ListView·SPL)을 돌려 손가락 밑·첫 프레임·예측 높이를 보는 검증은
///   card_list_fold_keep_under_finger_test.dart가 한다.
/// - (C2b-4) 누른 칸의 위치는 ItemPositionsListener가 아니라 렌더 트리에서 읽는다 (스크롤 없이 칸 높이만
///   바뀌면 리스너 값이 낡는다). 이 파일의 합성 칸(CardTile 아님)은 새 높이를 모르므로(예측 null) 위쪽 가장자리를
///   그대로 두는 경로를 검증한다.
/// - (C2b-5) SPL을 자기만의 PageStorage로 감싸서, 위쪽 PageStorageKey가 있어도 initialScrollIndex가 이긴다.
///
/// 화면(sqlite 의존)은 못 띄우므로 화면이 쓰는 같은 최상위 도우미를 평범한 SPL 호스트에 붙여 검증한다.
/// 기기 크기는 실기기(S20, 뷰포트 약 636dp, 목록 위쪽 약 193dp)와 같게 맞춘다.

const double kTop = 193;
const double kVp = 636;

class _Rig {
  _Rig(this.heights);

  final List<double> heights;
  final isc = ItemScrollController();
  final ipl = ItemPositionsListener.create();
  late final SplRemountController spl =
      SplRemountController(itemScrollController: isc, itemPositionsListener: ipl);
  final folded = <int>{};
  final extra = <int, ValueNotifier<double>>{};
  late StateSetter setOuter;
  late BuildContext hostContext; // 화면 State의 context 자리 (다시 빌드 대기 중이면 붙잡지 않는다)

  Widget _item(BuildContext context, int i) => Builder(
        builder: (itemContext) => GestureDetector(
          key: ValueKey('card$i'),
          behavior: HitTestBehavior.opaque,
          onTap: () {
            keepTappedCardUnderFinger(
              hostContext: hostContext,
              itemContext: itemContext,
              index: i,
              itemCount: heights.length,
              tap: CardTileTap.question,
              fingerGlobal: null,
              spl: spl,
              setState: setOuter,
            );
            setOuter(() {
              if (!folded.remove(i)) folded.add(i);
            });
          },
          child: ValueListenableBuilder<double>(
            valueListenable: extra.putIfAbsent(i, () => ValueNotifier<double>(0)),
            builder: (_, e, _) => SizedBox(
              height: (folded.contains(i) ? 60 : heights[i]) + e,
              child: Text('card $i'),
            ),
          ),
        ),
      );

  Widget build() => MaterialApp(
        home: Scaffold(
          body: Column(children: [
            const SizedBox(height: kTop),
            SizedBox(
              height: kVp,
              child: StatefulBuilder(builder: (context, ss) {
                setOuter = ss;
                hostContext = context;
                return Stack(children: [
                  spl.build(
                    itemCount: heights.length,
                    itemBuilder: _item,
                    physics: const ClampingScrollPhysics(),
                  ),
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
  await tester.pumpAndSettle();
}

ScrollPosition _primary(WidgetTester t) =>
    t.state<ScrollableState>(find.byType(Scrollable).first).position;

Finder _card(int i) => find.byKey(ValueKey('card$i'));

/// 뷰포트 위쪽 기준 카드 사각형. 레이아웃 안 된 칸은 null.
Rect? _rect(WidgetTester t, int i) {
  final f = _card(i);
  if (f.evaluate().isEmpty) return null;
  return t.getRect(f).shift(const Offset(0, -kTop));
}

void main() {
  group('keptTopAfterResize (순수 규칙)', () {
    // 기준: 위쪽 100, 높이 400, 스크롤 1000(범위 0..5000). 손가락/새 높이만 바꿔 본다.
    double kept({
      double top = 100,
      double height = 400,
      double? newHeight,
      double? fingerY,
      double pixels = 1000,
      double min = 0,
      double max = 5000,
    }) =>
        keptTopAfterResize(
          top: top,
          height: height,
          newHeight: newHeight,
          fingerY: fingerY,
          pixels: pixels,
          minScrollExtent: min,
          maxScrollExtent: max,
        );

    test('K1 커지면 위쪽 그대로 (커질 때 손가락 규칙을 적용하면 빨강)', () {
      expect(kept(newHeight: 500, fingerY: 480), 100);
      expect(kept(newHeight: 400, fingerY: 480), 100, reason: '같은 높이도 그대로');
      // 손가락이 카드 위쪽 가까이(105)면 줄어드는 규칙이 적용될 때 위쪽이 93으로 올라간다 — 커질 땐 그대로여야 한다.
      expect(kept(newHeight: 500, fingerY: 105), 100);
    });
    test('K2 새 높이를 모르면(null) 위쪽 그대로', () {
      expect(kept(newHeight: null, fingerY: 450), 100);
    });
    test('K3 줄어든 카드를 위쪽 그대로 둬도 손가락 밑이면 그대로 (항상 아래쪽을 맞추면 82라 빨강)', () {
      expect(kept(newHeight: 80, fingerY: 150), 100);
    });
    test('K4 위쪽 그대로면 손가락이 줄어든 카드 밖이면 최소한만 내린다 (위쪽 고정이면 100, 옛 아래쪽 고정이면 420이라 빨강)', () {
      expect(kept(newHeight: 80, fingerY: 450), 382);
    });
    test('K5 경계: 손가락이 줄어든 카드 아래쪽 안쪽 12dp이면 그대로, 0.5dp 넘으면 0.5만 내린다', () {
      expect(kept(newHeight: 80, fingerY: 168), 100);
      expect(kept(newHeight: 80, fingerY: 168.5), 100.5);
    });
    test('K6 아주 작은 새 높이(10): ArgumentError 없이 안쪽 여백이 높이 절반(5)으로 줄어든다 (고정 12면 빨강)', () {
      expect(kept(newHeight: 10, fingerY: 150), 145);
    });
    test('K7 목록 맨 위 근처(스크롤 50): 범위 밖으로 올리지 않는다 (범위 자르기가 없으면 382라 빨강)', () {
      expect(kept(newHeight: 80, fingerY: 450, pixels: 50), 150);
    });
    test('K8 목록 맨 끝 근처(스크롤 4900): 줄어든 만큼 범위가 줄어 카드를 더 아래로 둬야 한다 (자르기 없으면 100이라 빨강)', () {
      expect(kept(newHeight: 80, fingerY: 150, pixels: 4900), 320);
    });
    test('K9 범위가 거의 없는 짧은 목록: 위/아래 한계가 같아 200으로 고정', () {
      expect(kept(newHeight: 80, fingerY: 150, pixels: 100, max: 100), 200);
    });
    test('K10 손가락을 모르면(접근성 탭) 보이는 맨 위를 손가락으로 본다 — 위로 잘린 카드도 아래쪽이 12dp 이상 남는다', () {
      final t = kept(top: -200, newHeight: 80, fingerY: null);
      expect(t, -56);
      expect(t + 80, greaterThanOrEqualTo(kFingerInsetOnCard));
    });
    test('K11 새 높이가 NaN/무한대면 위쪽 그대로', () {
      expect(kept(newHeight: double.nan, fingerY: 450), 100);
      expect(kept(newHeight: double.infinity, fingerY: 450), 100);
      expect(kept(newHeight: double.negativeInfinity, fingerY: 450), 100);
    });
  });

  // ───────────── (4) 낡은 ItemPositionsListener가 아니라 렌더 트리에서 읽는다 ─────────────

  group('누른 칸 위치는 렌더 트리에서 읽는다', () {
    testWidgets('누른 칸과 target 사이 카드가 (스크롤 없이) 100dp 커진 뒤 눌러도 누른 카드가 안 움직인다',
        (tester) async {
      final h = [for (var i = 0; i < 60; i++) 200.0];
      final rig = _Rig(h);
      await _mount(tester, rig);
      rig.spl.jumpTo(40, setState: rig.setOuter);
      await tester.pumpAndSettle();
      _primary(tester).jumpTo(_primary(tester).pixels - 500);
      await tester.pumpAndSettle();
      final lead38Stale = rig.ipl.itemPositions.value.firstWhere((p) => p.index == 38).itemLeadingEdge;

      rig.extra[39]!.value = 100; // 이미지 디코딩이 끝난 것처럼 카드 하나만 다시 빌드되어 커진다
      await tester.pumpAndSettle();
      final lead38Listener =
          rig.ipl.itemPositions.value.firstWhere((p) => p.index == 38).itemLeadingEdge;
      final topBefore = _rect(tester, 38)!.top;
      expect(lead38Listener * kVp, closeTo(lead38Stale * kVp, 0.5),
          reason: '이 상황이 맞는지 확인: 리스너 값은 낡았다(스크롤이 없어서 갱신 안 됨)');
      expect((lead38Listener * kVp - topBefore).abs(), greaterThan(50),
          reason: '이 상황이 맞는지 확인: 리스너 값과 실제 위치가 크게 다르다');
      final epochBefore = rig.spl.epoch;

      await tester.tapAt(Offset(100, kTop + topBefore + 20));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(rig.folded, contains(38));
      expect(rig.spl.epoch, greaterThan(epochBefore), reason: 'target 위쪽 칸은 붙잡는다');
      expect(_rect(tester, 38)!.top - topBefore, closeTo(0, 1.0));
    });

    testWidgets('tappedItemEdges: 렌더 트리 값이 낡은 리스너 값보다 우선하고, 트리를 못 읽을 때만 리스너로 대신한다',
        (tester) async {
      final h = [for (var i = 0; i < 60; i++) 200.0];
      final rig = _Rig(h);
      await _mount(tester, rig);
      rig.spl.jumpTo(40, setState: rig.setOuter);
      await tester.pumpAndSettle();
      _primary(tester).jumpTo(_primary(tester).pixels - 500);
      await tester.pumpAndSettle();
      rig.extra[39]!.value = 100;
      await tester.pumpAndSettle();
      final positions = rig.ipl.itemPositions.value;

      final e = tappedItemEdges(
          itemContext: tester.element(_card(38)), positions: positions, index: 38)!;
      expect(e.leading * kVp, closeTo(_rect(tester, 38)!.top, 0.5));
      expect(e.trailing * kVp, closeTo(_rect(tester, 38)!.bottom, 0.5));

      // 칸 컨텍스트가 아닌(렌더 박스는 있지만 뷰포트가 없는) 컨텍스트 → 리스너 값으로 대신한다
      final fallback = tappedItemEdges(
          itemContext: tester.element(find.byType(Scaffold)), positions: positions, index: 38)!;
      final listener = positions.firstWhere((p) => p.index == 38);
      expect(fallback.leading, listener.itemLeadingEdge);
      expect(fallback.trailing, listener.itemTrailingEdge);
      // 리스너에도 없으면 null
      expect(
          tappedItemEdges(
              itemContext: tester.element(find.byType(Scaffold)), positions: positions, index: 5),
          isNull);
    });
  });

  // ───────────── (5) 위쪽에 PageStorageKey가 있어도 점프가 이긴다 ─────────────

  group('PageStorage 격리', () {
    Future<(SplRemountController, ItemPositionsListener, StateSetter, ValueNotifier<bool>)>
        mountKeyed(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      final isc = ItemScrollController();
      final ipl = ItemPositionsListener.create();
      final spl = SplRemountController(itemScrollController: isc, itemPositionsListener: ipl);
      final show = ValueNotifier<bool>(true);
      late StateSetter ss;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(builder: (context, s) {
            ss = s;
            return KeyedSubtree(
              key: const PageStorageKey('cards'),
              child: show.value
                  ? spl.build(
                      itemCount: 100,
                      itemBuilder: (c, i) => SizedBox(height: 100, child: Text('card $i')),
                    )
                  : const SizedBox(),
            );
          }),
        ),
      ));
      await tester.pumpAndSettle();
      return (spl, ipl, ss, show);
    }

    int firstVisible(ItemPositionsListener ipl) => ipl.itemPositions.value
        .where((p) => p.itemTrailingEdge > 0)
        .map((p) => p.index)
        .reduce(math.min);

    testWidgets('PageStorageKey 조상이 있어도 30번을 요청하면 30번에서 열린다', (tester) async {
      final (spl, ipl, ss, _) = await mountKeyed(tester);
      spl.jumpTo(30, setState: ss);
      await tester.pumpAndSettle();
      expect(firstVisible(ipl), 30);
      final p = ipl.itemPositions.value.firstWhere((p) => p.index == 30);
      expect(p.itemLeadingEdge, closeTo(0, 0.001));
      spl.jumpTo(70, alignment: 0.25, setState: ss);
      await tester.pumpAndSettle();
      final p70 = ipl.itemPositions.value.firstWhere((p) => p.index == 70);
      expect(p70.itemLeadingEdge, closeTo(0.25, 0.001));
    });

    testWidgets('PageStorageKey 조상이 있어도 점프가 아닌 새 마운트(스피너→목록)는 맨 위에서 열린다', (tester) async {
      final (spl, ipl, ss, show) = await mountKeyed(tester);
      spl.jumpTo(30, setState: ss);
      await tester.pumpAndSettle();
      _primary(tester).jumpTo(_primary(tester).pixels + 700); // 스크롤 위치가 저장될 만큼 스크롤
      await tester.pumpAndSettle();
      ss(() => show.value = false);
      await tester.pump();
      ss(() => show.value = true);
      await tester.pumpAndSettle();
      expect(firstVisible(ipl), 0);
    });

    testWidgets('(전제 확인) 격리 래퍼가 없는 평범한 SPL은 PageStorageKey 조상이 있으면 시작 칸을 못 이룬다',
        (tester) async {
      // 이 대조군이 초록→빨강이 되면(SPL이 바뀌어 복원을 안 하게 되면) PageStorage 격리는 필요 없어질 수 있다.
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      final ipl = ItemPositionsListener.create();
      late StateSetter ss;
      var epoch = 0;
      Widget list() => SizedBox.expand(
            child: ScrollablePositionedList.builder(
              key: ValueKey(epoch),
              initialScrollIndex: epoch == 0 ? 0 : 30,
              itemCount: 100,
              itemBuilder: (c, i) => SizedBox(height: 100, child: Text('card $i')),
              itemPositionsListener: ipl,
            ),
          );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(builder: (context, s) {
            ss = s;
            return KeyedSubtree(key: const PageStorageKey('cards'), child: list());
          }),
        ),
      ));
      await tester.pumpAndSettle();
      ss(() => epoch = 1);
      await tester.pumpAndSettle();
      expect(firstVisible(ipl), isNot(30));
    });
  });
}
