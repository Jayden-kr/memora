import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memora/l10n/app_localizations.dart';
import 'package:memora/models/card.dart';
import 'package:memora/screens/card_list_screen.dart';
import 'package:memora/widgets/card_tile.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// 스크롤바 썸 드래그 점프의 비용·정확도 계약 (SplRemountController.thumbDragJumpTo).
///
/// 배경: 점프를 "다시 마운트"로 바꾼 뒤(57e90b2), 썸을 천천히 끌 때도 매 프레임 목록이 새로 만들어졌다
/// (칸이 안 바뀌어도). 같은 드래그에서 같은 칸이면 건너뛰어 칸이 실제로 바뀔 때만 다시 마운트한다.
/// 화면(sqlite 의존)은 못 띄우므로, 화면의 _buildScrollIndicator/_jumpToFraction과 같은 모양
/// (프레임당 1회 스로틀 + 같은 컨트롤러 메서드)의 호스트로 검증한다. 화면이 그 메서드를 실제로 부르는지는
/// card_list_spl_remount_test.dart의 소스 가드가 지킨다.

enum _Mode {
  /// 옛 방식: 매 프레임 spl.jumpTo (칸이 같아도 다시 마운트)
  remountEveryFrame,

  /// 화면과 같은 방식: spl.thumbDragJumpTo (같은 칸이면 건너뜀)
  dedupe,

  /// 부모 수준 기준선: 평범한 SPL + raw jumpTo (이전 커밋들의 방식, 칸이 같으면 거의 비용 없음)
  raw,
}

List<CardModel> _cards(int n, int seed) {
  final rnd = math.Random(seed);
  const words = ['apple', 'banana', 'cherry', 'delta', 'echo', 'foxtrot', 'golf'];
  String sentence(int w) =>
      [for (var i = 0; i < w; i++) words[rnd.nextInt(words.length)]].join(' ');
  return [
    for (var i = 0; i < n; i++)
      CardModel(
        id: i + 1,
        uuid: 'u$i',
        folderId: 1,
        question: sentence(2 + rnd.nextInt(10)),
        answer: sentence(3 + rnd.nextInt(40)),
      ),
  ];
}

class _Host extends StatefulWidget {
  const _Host({super.key, required this.cards, required this.mode});
  final List<CardModel> cards;
  final _Mode mode;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  final isc = ItemScrollController();
  final ipl = ItemPositionsListener.create();
  late final SplRemountController spl =
      SplRemountController(itemScrollController: isc, itemPositionsListener: ipl);
  final scrollFraction = ValueNotifier<double>(0);
  bool jumpScheduled = false;
  int pendingJump = -1;
  int jumps = 0; // 실제로 점프한 횟수

  // 화면의 _jumpToFraction과 같은 모양 (프레임당 1회 스로틀)
  void jumpToFraction(double localY, double trackHeight, double indicatorHeight) {
    final fraction =
        ((localY - indicatorHeight / 2) / (trackHeight - indicatorHeight)).clamp(0.0, 1.0);
    scrollFraction.value = fraction;
    if (!isc.isAttached) return;
    pendingJump = (fraction * (widget.cards.length - 1)).round();
    if (!jumpScheduled) {
      jumpScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        jumpScheduled = false;
        if (!mounted || !isc.isAttached) return;
        switch (widget.mode) {
          case _Mode.remountEveryFrame:
            spl.jumpTo(pendingJump, setState: setState);
            jumps++;
          case _Mode.dedupe:
            if (spl.thumbDragJumpTo(pendingJump, setState: setState)) jumps++;
          case _Mode.raw:
            isc.jumpTo(index: pendingJump);
            jumps++;
        }
      });
    }
  }

  Widget item(BuildContext context, int index) => PressObserver(
        onPress: () {},
        child: CardTile(
          card: widget.cards[index],
          cardNumber: index + 1,
          onQuestionTap: () {},
          onAnswerTap: () {},
          onTap: () {},
          onLongPress: () {},
          onMenuAction: (_) {},
        ),
      );

  Widget indicator() => LayoutBuilder(builder: (context, constraints) {
        final trackHeight = constraints.maxHeight;
        const indicatorHeight = 28.0;
        final maxOffset = trackHeight - indicatorHeight;
        return GestureDetector(
          behavior: HitTestBehavior.deferToChild,
          onVerticalDragStart: (d) {
            spl.beginThumbDrag();
            jumpToFraction(d.localPosition.dy, trackHeight, indicatorHeight);
          },
          onVerticalDragUpdate: (d) =>
              jumpToFraction(d.localPosition.dy, trackHeight, indicatorHeight),
          child: ValueListenableBuilder<double>(
            valueListenable: scrollFraction,
            builder: (context, fraction, _) {
              final top = (fraction * maxOffset).clamp(0.0, maxOffset);
              return Stack(children: [
                Positioned(
                  top: top,
                  right: 0,
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                        key: const ValueKey('thumb'),
                        width: 60,
                        height: indicatorHeight,
                        color: Colors.red),
                  ),
                ),
              ]);
            },
          ),
        );
      });

  @override
  Widget build(BuildContext context) {
    final Widget list = widget.mode == _Mode.raw
        ? SizedBox.expand(
            child: ScrollablePositionedList.builder(
              itemCount: widget.cards.length,
              itemBuilder: item,
              itemScrollController: isc,
              itemPositionsListener: ipl,
              physics: const ClampingScrollPhysics(),
            ),
          )
        : spl.build(
            itemCount: widget.cards.length,
            itemBuilder: item,
            physics: const ClampingScrollPhysics(),
          );
    return Scaffold(
      appBar: AppBar(title: Text('Folder (${widget.cards.length})')),
      body: Stack(children: [
        list,
        Positioned(right: 0, top: 0, bottom: 0, width: 80, child: indicator()),
      ]),
    );
  }
}

Set<Element> _allElements(WidgetTester tester) => Set<Element>.identity()
  ..addAll(collectAllElementsFrom(tester.binding.rootElement!, skipOffstage: false));

class _DragResult {
  _DragResult(this.avgNewElems, this.jumps, this.landIdx, this.landTop);
  final double avgNewElems; // 프레임당 새로 만들어진 요소 수 평균
  final int jumps;
  final int landIdx;
  final double? landTop; // 착지 칸의 위쪽 가장자리 (뷰포트 위쪽 기준 dp), 화면에 없으면 null
}

Future<_DragResult> _drag(
  WidgetTester tester,
  _Mode mode, {
  required double dy,
  required int frames,
  double preScroll = 0,
}) async {
  final key = GlobalKey<_HostState>();
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: _Host(key: key, cards: _cards(150, 42), mode: mode),
  ));
  await tester.pumpAndSettle();
  if (preScroll > 0) {
    tester.state<ScrollableState>(find.byType(Scrollable).first).position.jumpTo(preScroll);
    await tester.pumpAndSettle();
  }
  final g = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('thumb'))));
  var newTotal = 0;
  for (var f = 0; f < frames; f++) {
    await g.moveBy(Offset(0, dy));
    final before = _allElements(tester);
    await tester.pump(const Duration(milliseconds: 16));
    for (final e in _allElements(tester)) {
      if (!before.contains(e)) newTotal++;
    }
  }
  await g.up();
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  final st = key.currentState!;
  final idx = st.pendingJump;
  final p = st.ipl.itemPositions.value.where((q) => q.index == idx);
  final vp = tester.getSize(find.byType(ScrollablePositionedList)).height;
  return _DragResult(
    newTotal / frames,
    st.jumps,
    idx,
    p.isEmpty ? null : p.first.itemLeadingEdge * vp,
  );
}

void _bigScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('작은 드래그(프레임당 2px): 다시 마운트 비용이 부모(raw) 수준으로 내려오고 착지는 정확하다',
      (tester) async {
    _bigScreen(tester);
    const frames = 60;
    final raw = await _drag(tester, _Mode.raw, dy: 2, frames: frames);
    final every = await _drag(tester, _Mode.remountEveryFrame, dy: 2, frames: frames);
    final dedupe = await _drag(tester, _Mode.dedupe, dy: 2, frames: frames);
    // ignore: avoid_print
    print('thumb drag 2px/frame churn (new elements per frame): raw=${raw.avgNewElems.toStringAsFixed(0)} '
        'remount-every-frame=${every.avgNewElems.toStringAsFixed(0)} '
        'dedupe=${dedupe.avgNewElems.toStringAsFixed(0)}  jumps: every=${every.jumps} dedupe=${dedupe.jumps}');

    // 전제 확인: 매 프레임 다시 마운트는 부모 방식보다 훨씬 비싸다 (이 비교가 의미 있다는 증거)
    expect(every.avgNewElems, greaterThan(raw.avgNewElems * 2));
    // 고침: 부모 수준(+10% 여유)으로 내려온다
    expect(dedupe.avgNewElems, lessThanOrEqualTo(raw.avgNewElems * 1.1 + 5));
    // 같은 칸 점프를 건너뛰어 실제 점프 수가 칸이 바뀐 만큼으로 줄었다
    expect(dedupe.jumps, lessThan(every.jumps ~/ 2));
    // 착지: 마지막 칸이 정확히 맨 위에 온다
    expect(dedupe.landIdx, every.landIdx);
    expect(dedupe.landTop, isNotNull);
    expect(dedupe.landTop!.abs(), lessThan(1.0));
  });

  testWidgets('멀리 스크롤한 뒤 한 프레임짜리 큰 드래그(flick)도 정확히 그 칸에 착지한다', (tester) async {
    _bigScreen(tester);
    for (final mode in [_Mode.dedupe, _Mode.remountEveryFrame]) {
      final r = await _drag(tester, mode, dy: 400, frames: 1, preScroll: 12000);
      expect(r.jumps, 1, reason: '${mode.name}: 한 프레임 드래그는 점프 한 번');
      expect(r.landTop, isNotNull, reason: '${mode.name}: 착지 칸 ${r.landIdx}이 화면에 있어야 한다');
      expect(r.landTop!.abs(), lessThan(1.0), reason: '${mode.name}: 착지 칸이 맨 위여야 한다');
    }
  });

  testWidgets('작은 드래그를 이어 가다 큰 드래그: 칸이 바뀔 때마다 새로 점프해 마지막 칸에 정확히 착지한다',
      (tester) async {
    _bigScreen(tester);
    final key = GlobalKey<_HostState>();
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: _Host(key: key, cards: _cards(150, 7), mode: _Mode.dedupe),
    ));
    await tester.pumpAndSettle();
    final g = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('thumb'))));
    for (var f = 0; f < 15; f++) {
      await g.moveBy(const Offset(0, 2));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final smallJumps = key.currentState!.jumps;
    await g.moveBy(const Offset(0, 300));
    await tester.pump(const Duration(milliseconds: 16));
    await g.up();
    await tester.pumpAndSettle();
    final st = key.currentState!;
    expect(st.jumps, greaterThan(smallJumps), reason: '큰 드래그의 칸 변화는 건너뛰면 안 된다');
    final p = st.ipl.itemPositions.value.firstWhere((q) => q.index == st.pendingJump);
    final vp = tester.getSize(find.byType(ScrollablePositionedList)).height;
    expect((p.itemLeadingEdge * vp).abs(), lessThan(1.0));
  });

  group('thumbDragJumpTo 계약 (컨트롤러)', () {
    Future<(SplRemountController, ItemPositionsListener, StateSetter)> mount(
        WidgetTester tester) async {
      _bigScreen(tester);
      final isc = ItemScrollController();
      final ipl = ItemPositionsListener.create();
      final spl = SplRemountController(itemScrollController: isc, itemPositionsListener: ipl);
      late StateSetter ss;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(builder: (context, s) {
            ss = s;
            return spl.build(
              itemCount: 100,
              itemBuilder: (c, i) => SizedBox(height: 100, child: Text('card $i')),
            );
          }),
        ),
      ));
      await tester.pumpAndSettle();
      return (spl, ipl, ss);
    }

    double leading(ItemPositionsListener ipl, int i) =>
        ipl.itemPositions.value.firstWhere((p) => p.index == i).itemLeadingEdge;

    testWidgets('같은 드래그에서 같은 칸이면 건너뛴다, 다른 칸이면 점프한다', (tester) async {
      final (spl, ipl, ss) = await mount(tester);
      spl.beginThumbDrag();
      expect(spl.thumbDragJumpTo(30, setState: ss), isTrue);
      await tester.pumpAndSettle();
      final epoch = spl.epoch;
      expect(spl.thumbDragJumpTo(30, setState: ss), isFalse);
      expect(spl.epoch, epoch, reason: '건너뛰면 다시 마운트하지 않는다');
      expect(spl.thumbDragJumpTo(31, setState: ss), isTrue);
      await tester.pumpAndSettle();
      expect(leading(ipl, 31), closeTo(0, 0.001));
    });

    testWidgets('그 사이에 다른 점프(epoch 변경)가 있었으면 같은 칸이어도 새로 점프한다', (tester) async {
      final (spl, ipl, ss) = await mount(tester);
      spl.beginThumbDrag();
      spl.thumbDragJumpTo(30, setState: ss);
      await tester.pumpAndSettle();
      spl.jumpTo(10, setState: ss); // 접기 붙잡기·새 결과 같은 다른 점프
      await tester.pumpAndSettle();
      expect(ipl.itemPositions.value.any((p) => p.index == 30), isFalse);
      expect(spl.thumbDragJumpTo(30, setState: ss), isTrue);
      await tester.pumpAndSettle();
      expect(leading(ipl, 30), closeTo(0, 0.001));
    });

    testWidgets('새 드래그(beginThumbDrag)의 첫 점프는 이전 드래그와 같은 칸이어도 항상 한다', (tester) async {
      final (spl, ipl, ss) = await mount(tester);
      spl.beginThumbDrag();
      spl.thumbDragJumpTo(30, setState: ss);
      await tester.pumpAndSettle();
      // 드래그 사이에 사용자가 일반 스크롤로 멀어졌다 (점프가 아니라 epoch는 그대로)
      tester.state<ScrollableState>(find.byType(Scrollable).first).position.jumpTo(
          tester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels + 2500);
      await tester.pumpAndSettle();
      expect(ipl.itemPositions.value.any((p) => p.index == 30), isFalse);
      spl.beginThumbDrag();
      expect(spl.thumbDragJumpTo(30, setState: ss), isTrue);
      await tester.pumpAndSettle();
      expect(leading(ipl, 30), closeTo(0, 0.001));
    });
  });
}
