import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memora/screens/card_list_screen.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// 접기/보이기 붙잡기(reanchorTappedCard / resizePinFor)의 남은 계약.
///
/// - (C2b-2) target 이상 칸이 **위로 잘려 있고 아래쪽이 화면 안**일 때 접으면 카드가 통째로 위로 사라지고
///   다음 카드가 손가락 밑으로 미끄러졌다 → 다음 칸을 이 카드의 아래쪽 가장자리에 맞춰 target으로 삼는다.
/// - (C2b-4) 누른 칸의 위치는 ItemPositionsListener가 아니라 렌더 트리에서 읽는다 (스크롤 없이 칸 높이만
///   바뀌면 리스너 값이 낡는다).
/// - (C2b-5) SPL을 자기만의 PageStorage로 감싸서, 위쪽 PageStorageKey가 있어도 initialScrollIndex가 이긴다.
///
/// 화면(sqlite 의존)은 못 띄우므로 화면이 쓰는 같은 최상위 도우미를 평범한 SPL 호스트에 붙여 검증한다.
/// 기기 크기는 실기기(S20, 뷰포트 약 636dp, 목록 위쪽 약 193dp)와 같게 맞춘다.

const double kTop = 193;
const double kVp = 636;

class _Rig {
  _Rig(this.heights, {this.pin = true});

  final List<double> heights;
  final bool pin; // false면 붙잡지 않는 대조군
  final isc = ItemScrollController();
  final ipl = ItemPositionsListener.create();
  late final SplRemountController spl =
      SplRemountController(itemScrollController: isc, itemPositionsListener: ipl);
  final folded = <int>{};
  final extra = <int, ValueNotifier<double>>{};
  late StateSetter setOuter;

  Widget _item(BuildContext context, int i) => Builder(
        builder: (itemContext) => GestureDetector(
          key: ValueKey('card$i'),
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (pin) {
              reanchorTappedCard(
                spl: spl,
                itemContext: itemContext,
                index: i,
                itemCount: heights.length,
                setState: setOuter,
              );
            }
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

double _sum(List<double> h, int from, int to) {
  var s = 0.0;
  for (var i = from; i < to; i++) {
    s += h[i];
  }
  return s;
}

/// 뷰포트 위쪽 기준 카드 사각형. 레이아웃 안 된 칸은 null.
Rect? _rect(WidgetTester t, int i) {
  final f = _card(i);
  if (f.evaluate().isEmpty) return null;
  return t.getRect(f).shift(const Offset(0, -kTop));
}

void main() {
  // ───────────── (2) 위로 잘린 target 이상 칸: 아래쪽 가장자리를 고정 ─────────────

  group('위로 잘린 칸을 접으면 아래쪽 가장자리가 고정되어 카드가 화면에 남는다', () {
    List<double> heights() => [for (var i = 0; i < 30; i++) i == 10 ? 500.0 : 200.0];

    for (final fingerY in [100.0, 300.0]) {
      testWidgets('target 이상 칸 (target 0), 손가락 y=$fingerY', (tester) async {
        final h = heights();
        final rig = _Rig(h);
        await _mount(tester, rig);
        _primary(tester).jumpTo(_sum(h, 0, 10) + 150); // 카드 10 위쪽 -150 (잘림), 아래쪽 350
        await tester.pumpAndSettle();
        expect(_rect(tester, 10)!.top, closeTo(-150, 0.5));
        expect(_rect(tester, 10)!.bottom, closeTo(350, 0.5));
        final epochBefore = rig.spl.epoch;

        await tester.tapAt(Offset(100, kTop + fingerY));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(rig.folded, contains(10));
        expect(rig.spl.epoch, greaterThan(epochBefore), reason: '아래쪽 가장자리를 고정하려고 다시 마운트');
        final r = _rect(tester, 10);
        expect(r, isNotNull, reason: '접힌 카드가 화면에서 사라지면 안 된다');
        expect(r!.bottom, closeTo(350, 1.0), reason: '아래쪽 가장자리 고정');
        expect(r.top, closeTo(290, 1.0));
        expect(_rect(tester, 11)!.top, closeTo(r.bottom, 0.5), reason: '바로 아래는 다음 카드');
        if (fingerY > 290) {
          expect(r.contains(Offset(100, fingerY)), isTrue, reason: '손가락 밑에 그 카드가 남는다');
        }
      });
    }

    testWidgets('(전제 확인) 붙잡지 않으면 카드가 통째로 화면 위로 사라진다', (tester) async {
      final h = heights();
      final rig = _Rig(h, pin: false);
      await _mount(tester, rig);
      _primary(tester).jumpTo(_sum(h, 0, 10) + 150);
      await tester.pumpAndSettle();
      await tester.tapAt(Offset(100, kTop + 300));
      await tester.pumpAndSettle();
      final r = _rect(tester, 10);
      expect(r == null || r.bottom <= 0, isTrue, reason: '위쪽이 화면 밖에 고정된 채 줄어들어 사라진다');
    });

    testWidgets('이어서 다시 누르면(보이기) 위쪽 가장자리가 고정되어 손가락 밑에 남는다', (tester) async {
      final h = heights();
      final rig = _Rig(h);
      await _mount(tester, rig);
      _primary(tester).jumpTo(_sum(h, 0, 10) + 150);
      await tester.pumpAndSettle();
      await tester.tapAt(Offset(100, kTop + 300)); // 접기 → 290..350
      await tester.pumpAndSettle();
      await tester.tapAt(Offset(100, kTop + 300)); // 다시 펼치기
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(rig.folded, isNot(contains(10)));
      final r = _rect(tester, 10)!;
      expect(r.top, closeTo(290, 1.0), reason: '위쪽이 화면 안이면 위쪽 가장자리가 고정');
      expect(r.contains(const Offset(100, 300)), isTrue);
    });

    testWidgets('target 위쪽 칸이 위로 잘린 경우는 원래 아래쪽 가장자리가 고정 — 다시 마운트하지 않는다',
        (tester) async {
      final h = [for (var i = 0; i < 60; i++) i == 20 ? 500.0 : 200.0];
      final rig = _Rig(h);
      await _mount(tester, rig);
      rig.spl.jumpTo(40, setState: rig.setOuter);
      await tester.pumpAndSettle();
      _primary(tester).jumpTo(-_sum(h, 20, 40) + 150); // 카드 20 위쪽 -150
      await tester.pumpAndSettle();
      expect(_rect(tester, 20)!.top, closeTo(-150, 0.5));
      final epochBefore = rig.spl.epoch;

      await tester.tapAt(const Offset(100, kTop + 300));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(rig.folded, contains(20));
      expect(rig.spl.epoch, epochBefore, reason: '이미 아래쪽이 고정이라 건드리지 않는다');
      final r = _rect(tester, 20)!;
      expect(r.bottom, closeTo(350, 1.0));
      expect(r.contains(const Offset(100, 300)), isTrue);
    });

    testWidgets('마지막 칸(다음 칸 없음)이 위로 잘려 있어도 접으면 화면에 남는다', (tester) async {
      final h = [for (var i = 0; i < 30; i++) i == 29 ? 800.0 : 200.0];
      final rig = _Rig(h);
      await _mount(tester, rig);
      _primary(tester).jumpTo(1e7); // 목록 맨 끝
      await tester.pumpAndSettle();
      final before = _rect(tester, 29)!;
      expect(before.bottom, closeTo(kVp, 0.5));
      expect(before.top, lessThan(0), reason: '위로 잘린 마지막 칸이어야 이 시나리오다');
      final epochBefore = rig.spl.epoch;

      await tester.tapAt(const Offset(100, kTop + 300));
      await tester.pump(); // 접힌 첫 프레임부터
      final first = _rect(tester, 29);
      expect(first, isNotNull, reason: '첫 프레임부터 카드가 화면에 있어야 한다');
      expect(first!.bottom, greaterThan(0));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(rig.folded, contains(29));
      expect(rig.spl.epoch, epochBefore, reason: '다음 칸이 없어서 다시 마운트하지 않는다');
      final r = _rect(tester, 29)!;
      expect(r.bottom, closeTo(kVp, 1.0), reason: '목록 끝이라 스크롤 범위가 카드를 화면 아래쪽에 남긴다');
      expect(r.top, greaterThanOrEqualTo(0));
    });
  });

  group('resizePinFor (순수 판정)', () {
    // 렌더 트리 위치는 위 통합 테스트가 보증한다. 여기서는 판정 분기만.
    testWidgets('위쪽이 화면 안인 target 이상 칸은 건드리지 않는다 (null)', (tester) async {
      final h = [for (var i = 0; i < 30; i++) 200.0];
      final rig = _Rig(h);
      await _mount(tester, rig);
      _primary(tester).jumpTo(_sum(h, 0, 5) + 50); // 카드 5 위쪽 -50 → 카드 6 위쪽 150
      await tester.pumpAndSettle();
      final ctx = tester.element(_card(6));
      expect(
        resizePinFor(
          itemContext: ctx,
          positions: rig.ipl.itemPositions.value,
          index: 6,
          targetIndex: 0,
          itemCount: 30,
        ),
        isNull,
      );
      final pin = resizePinFor(
        itemContext: tester.element(_card(5)),
        positions: rig.ipl.itemPositions.value,
        index: 5,
        targetIndex: 0,
        itemCount: 30,
      );
      expect(pin, isNotNull);
      expect(pin!.index, 6);
      expect(pin.alignment, closeTo(150 / kVp, 0.001));
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
