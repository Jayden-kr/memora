import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memora/screens/card_list_screen.dart';

/// 검색을 닫은 뒤 소량 목록(ListView)에서 누른 카드를 맨 위로 올리는 로직의 계약.
///
/// 화면(sqlite 의존)은 못 띄우므로 같은 최상위 함수들을 평범한 ListView에 붙여서 검증한다.
/// 핵심: 카드 높이가 제각각이어도(≤30장) 앵커가 항상 화면에 오고, 중간에 빈 화면 프레임이 없다.
/// 예전 구현은 "전체 길이 중 인덱스 비율"로 어림 점프를 3번까지만 시도해서, 높이가 들쭉날쭉하면
/// 앵커가 화면 밖에 남거나(약 5%) 빈 프레임이 끼었다(약 13%).

Widget listApp(
  ScrollController c,
  List<double> heights, {
  double? cacheExtent,
  EdgeInsets? padding,
  bool scrollbar = false,
}) {
  Widget list = ListView.builder(
    controller: c,
    padding: padding,
    cacheExtent: cacheExtent,
    itemCount: heights.length,
    itemBuilder: (ctx, i) =>
        SizedBox(height: heights[i], child: Text('card $i')),
    physics: const ClampOnResizeScrollPhysics(),
  );
  if (scrollbar) {
    list = Scrollbar(controller: c, thumbVisibility: true, child: list);
  }
  return MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('t')),
      body: Column(children: [
        const SizedBox(height: 50),
        Expanded(child: list),
      ]),
    ),
  );
}

void setView(WidgetTester tester, double h) {
  tester.view.physicalSize = Size(400, h);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

// ─── 프로덕션 코드와 무관하게 실제 렌더링 결과로 재는 도구 ───

Rect viewportRect(WidgetTester t) => t.getRect(find.byType(Scrollable));

/// 화면(뷰포트)과 겹치는 칸이 하나라도 있는가 — false면 빈 화면 프레임.
bool anyTileVisible(WidgetTester t) {
  final vp = viewportRect(t);
  final tiles = find.textContaining('card ');
  final count = tiles.evaluate().length;
  for (var i = 0; i < count; i++) {
    final r = t.getRect(tiles.at(i));
    if (r.bottom > vp.top && r.top < vp.bottom) return true;
  }
  return false;
}

/// [i]번 칸이 뷰포트와 겹치는가.
bool tileOnScreen(WidgetTester t, int i) {
  final f = find.text('card $i');
  if (f.evaluate().isEmpty) return false;
  final vp = viewportRect(t);
  final r = t.getRect(f);
  return r.bottom > vp.top && r.top < vp.bottom;
}

/// [i]번 칸이 맨 위에 있는가 — 맨 위에 못 오는 경우는 스크롤 끝에 닿아 더 올릴 수 없을 때뿐이다.
bool tileAtTopOrListEnd(WidgetTester t, ScrollController c, int i) {
  final f = find.text('card $i');
  if (f.evaluate().isEmpty) return false;
  final top = t.getTopLeft(f).dy - viewportRect(t).top;
  final atEnd = c.position.pixels >= c.position.maxScrollExtent - 0.5;
  return top.abs() < 1.0 || (atEnd && top > -0.5);
}

const _frame = Duration(milliseconds: 16);

class _Run {
  int doneCount = 0;
  int? doneFrame;
  int blankFrames = 0;
}

/// 기본 캐시 범위(화면 몇 장 분량만 레이아웃)의 ListView에서 [anchor]를 찾아 올린다.
/// 프레임마다 16ms씩 흘려 실기기와 같은 조건(범위를 벗어난 위치의 되돌림 애니메이션 등)으로 돌린다.
Future<_Run> _runSeek(
  WidgetTester tester,
  ScrollController c,
  List<double> heights,
  int anchor, {
  int? startAt,
}) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(listApp(c, heights));
  if (startAt != null) {
    // 먼저 정상적으로 [startAt]까지 가서 완전히 멈춘 상태에서 시작한다 — 어림 위치로 억지로
    // 점프해 두면 범위를 벗어난 위치의 되돌림 애니메이션이 측정에 섞인다.
    seekSimpleListToIndex(c,
        indexOf: () => startAt,
        isCurrent: () => true,
        itemCount: () => heights.length);
    for (var i = 0; i < heights.length + 20; i++) {
      await tester.pump(_frame);
    }
  }
  final run = _Run();
  var frame = 0;
  seekSimpleListToIndex(
    c,
    indexOf: () => anchor,
    isCurrent: () => true,
    itemCount: () => heights.length,
    onDone: () {
      run.doneCount++;
      run.doneFrame ??= frame;
    },
  );
  for (frame = 1; frame <= heights.length + 6; frame++) {
    await tester.pump(_frame);
    if (!anyTileVisible(tester)) run.blankFrames++;
  }
  return run;
}

void main() {
  group('simpleListItemPositions', () {
    testWidgets('padding·스크롤바가 있어도 실제 화면 위치와 일치한다', (tester) async {
      setView(tester, 800);
      final c = ScrollController();
      final heights = [for (var i = 0; i < 30; i++) 90.0 + (i * 37) % 150];
      await tester.pumpWidget(listApp(c, heights,
          scrollbar: true,
          padding: const EdgeInsets.only(top: 37, bottom: 48)));
      c.jumpTo(333);
      await tester.pump();
      final vp = viewportRect(tester);
      var checked = 0;
      for (final p in simpleListItemPositions(c)) {
        final f = find.text('card ${p.index}');
        if (f.evaluate().isEmpty) continue;
        final r = tester.getRect(f);
        expect((r.top - vp.top) / vp.height, closeTo(p.itemLeadingEdge, 1e-6));
        expect((r.bottom - vp.top) / vp.height,
            closeTo(p.itemTrailingEdge, 1e-6));
        checked++;
      }
      expect(checked, greaterThan(3)); // 비교가 실제로 일어났는지
    });

    test('컨트롤러가 어디에도 안 붙어 있으면 빈 목록', () {
      expect(simpleListItemPositions(ScrollController()), isEmpty);
    });

    testWidgets('붙기만 하고 레이아웃 전인 ListView에서도 던지지 않는다', (tester) async {
      final c = ScrollController();
      await tester.pumpWidget(
        listApp(c, [for (var i = 0; i < 10; i++) 100.0]),
        phase: EnginePhase.build,
      );
      expect(c.hasClients, isTrue);
      expect(simpleListItemPositions(c), isEmpty);
      expect(seekSimpleListStep(c, 3, itemCount: 10), SimpleListSeekStep.notReady);
      expect(jumpToStartIfLaidOut(c), isFalse);
      expect(tester.takeException(), isNull);
      // 레이아웃을 거치고 나면 정상 동작한다.
      await tester.pump();
      expect(simpleListItemPositions(c), isNotEmpty);
    });
  });

  group('jumpToStartIfLaidOut', () {
    test('붙어 있지 않으면 false', () {
      expect(jumpToStartIfLaidOut(ScrollController()), isFalse);
    });

    testWidgets('레이아웃이 끝난 목록은 맨 위로 보낸다', (tester) async {
      setView(tester, 800);
      final c = ScrollController();
      await tester.pumpWidget(listApp(c, [for (var i = 0; i < 30; i++) 200.0]));
      c.jumpTo(900);
      await tester.pump();
      expect(c.position.pixels, 900);
      expect(jumpToStartIfLaidOut(c), isTrue);
      expect(c.position.pixels, 0);
    });
  });

  group('seekSimpleListToIndex — 기본 캐시 범위 (레이아웃된 칸에서 걸어간다)', () {
    testWidgets('앞쪽이 큰 폴더(800px x10 + 120px x20)에서 앵커 15·25가 화면 맨 위에 온다',
        (tester) async {
      setView(tester, 800);
      final heights = [
        for (var i = 0; i < 10; i++) 800.0,
        for (var i = 0; i < 20; i++) 120.0,
      ];
      for (final anchor in [15, 25]) {
        final c = ScrollController();
        final run = await _runSeek(tester, c, heights, anchor);
        expect(run.doneCount, 1, reason: 'anchor $anchor: onDone은 정확히 한 번');
        expect(run.blankFrames, 0, reason: 'anchor $anchor: 빈 화면 프레임');
        expect(tileOnScreen(tester, anchor), isTrue, reason: 'anchor $anchor 화면 안');
        expect(tileAtTopOrListEnd(tester, c, anchor), isTrue,
            reason: 'anchor $anchor 맨 위');
      }
    });

    testWidgets('높이가 제각각인 15~30장 무작위 폴더 150개(고정 시드)에서 항상 도착하고 빈 프레임이 없다',
        (tester) async {
      setView(tester, 800);
      final rnd = math.Random(7);
      final fails = <String>[];
      for (var t = 0; t < 150; t++) {
        final n = 15 + rnd.nextInt(16);
        final heights = [
          for (var i = 0; i < n; i++)
            100.0 +
                rnd.nextInt(80) +
                (rnd.nextDouble() < 0.25 ? 300.0 + rnd.nextInt(400) : 0.0),
        ];
        final anchor = rnd.nextInt(n);
        final c = ScrollController();
        final run = await _runSeek(tester, c, heights, anchor);
        final ok = run.doneCount == 1 &&
            run.blankFrames == 0 &&
            tileOnScreen(tester, anchor) &&
            tileAtTopOrListEnd(tester, c, anchor);
        if (!ok) {
          fails.add('n=$n anchor=$anchor done=${run.doneCount} '
              'blank=${run.blankFrames} onScreen=${tileOnScreen(tester, anchor)} '
              'heights=${heights.map((h) => h.toInt()).toList()}');
        }
      }
      expect(fails, isEmpty, reason: '실패 ${fails.length}/150\n${fails.take(3).join('\n')}');
    });

    testWidgets('위쪽 칸으로도 걸어간다 (끝 칸에서 시작해 앵커 3)', (tester) async {
      setView(tester, 800);
      final heights = [
        for (var i = 0; i < 10; i++) 800.0,
        for (var i = 0; i < 20; i++) 120.0,
      ];
      final c = ScrollController();
      final run = await _runSeek(tester, c, heights, 3, startAt: 29);
      expect(run.doneCount, 1);
      expect(run.blankFrames, 0);
      expect(tileOnScreen(tester, 3), isTrue);
      expect(tileAtTopOrListEnd(tester, c, 3), isTrue);
    });

    testWidgets('이미 맨 위에 있는 칸은 첫 프레임에 바로 끝난다', (tester) async {
      setView(tester, 800);
      final heights = [for (var i = 0; i < 20; i++) 150.0];
      final c = ScrollController();
      final run = await _runSeek(tester, c, heights, 2);
      expect(run.doneFrame, 1);
      expect(tileAtTopOrListEnd(tester, c, 2), isTrue);
    });
  });

  group('seekSimpleListToIndex — 중단·종료 규약', () {
    Future<(ScrollController, List<double>)> mount(WidgetTester tester) async {
      setView(tester, 800);
      final heights = [
        for (var i = 0; i < 10; i++) 800.0,
        for (var i = 0; i < 20; i++) 120.0,
      ];
      final c = ScrollController();
      await tester.pumpWidget(listApp(c, heights));
      return (c, heights);
    }

    testWidgets('isCurrent가 false면 손대지 않고 onDone은 한 번', (tester) async {
      final (c, heights) = await mount(tester);
      var done = 0;
      seekSimpleListToIndex(
        c,
        indexOf: () => 25,
        isCurrent: () => false,
        itemCount: () => heights.length,
        onDone: () => done++,
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(_frame);
      }
      expect(done, 1);
      expect(c.position.pixels, 0);
    });

    testWidgets('도중에 isCurrent가 false가 되면 그 자리에서 멈추고 onDone은 한 번', (tester) async {
      final (c, heights) = await mount(tester);
      var done = 0;
      var current = true;
      seekSimpleListToIndex(
        c,
        indexOf: () => 25,
        isCurrent: () => current,
        itemCount: () => heights.length,
        onDone: () => done++,
      );
      await tester.pump(_frame); // 첫 걸음
      expect(done, 0);
      final stoppedAt = c.position.pixels;
      current = false;
      for (var i = 0; i < 6; i++) {
        await tester.pump(_frame);
      }
      expect(done, 1);
      expect(c.position.pixels, stoppedAt);
    });

    testWidgets('카드가 사라졌으면(indexOf 음수) 손대지 않고 끝낸다', (tester) async {
      final (c, heights) = await mount(tester);
      var done = 0;
      seekSimpleListToIndex(
        c,
        indexOf: () => -1,
        isCurrent: () => true,
        itemCount: () => heights.length,
        onDone: () => done++,
      );
      await tester.pump(_frame);
      await tester.pump(_frame);
      expect(done, 1);
      expect(c.position.pixels, 0);
    });

    testWidgets('걸음 수 제한에 닿으면 포기하고 onDone은 한 번 (끝없이 돌지 않는다)', (tester) async {
      final (c, _) = await mount(tester);
      var done = 0;
      // 걸음 수 제한 1: 먼 앵커(25)에는 한 걸음으로 못 닿는다.
      seekSimpleListToIndex(
        c,
        indexOf: () => 25,
        isCurrent: () => true,
        itemCount: () => 30,
        maxAttempts: 1,
        onDone: () => done++,
      );
      await tester.pump(_frame);
      expect(done, 1);
      final after = c.position.pixels;
      for (var i = 0; i < 6; i++) {
        await tester.pump(_frame);
      }
      expect(c.position.pixels, after, reason: '포기한 뒤에는 더 움직이지 않는다');
      expect(done, 1);
    });

    testWidgets('걸음 도중 예외가 나도 onDone은 불린다 (가려 둔 목록이 영영 안 보이는 사고 방지)',
        (tester) async {
      final (c, heights) = await mount(tester);
      var done = 0;
      seekSimpleListToIndex(
        c,
        indexOf: () => throw StateError('boom'),
        isCurrent: () => true,
        itemCount: () => heights.length,
        onDone: () => done++,
      );
      await tester.pump(_frame);
      expect(done, 1);
      expect(tester.takeException(), isA<StateError>());
    });
  });

  group('검색 닫기 조합 — 큰 캐시 범위 + 투명 처리 (화면이 쓰는 도우미 그대로)', () {
    // 화면(_buildCardList)과 같은 조합: settling이면 Opacity 0 + 큰 cacheExtent.
    // 닫기 직전에는 결과 목록에서 물려받은 엉뚱한 위치(startFraction)에 있다.
    Future<String?> runSettle(
      WidgetTester tester,
      List<double> heights,
      int anchor,
      double startFraction,
    ) async {
      final c = ScrollController();
      var settling = false;
      late StateSetter setOuter;
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(builder: (ctx, ss) {
            setOuter = ss;
            return Opacity(
              key: const Key('list-opacity'),
              opacity: searchExitListOpacity(settling: settling),
              child: ListView.builder(
                controller: c,
                cacheExtent: searchExitCacheExtent(settling: settling),
                itemCount: heights.length,
                itemBuilder: (ctx, i) =>
                    SizedBox(height: heights[i], child: Text('card $i')),
                physics: const ClampOnResizeScrollPhysics(),
              ),
            );
          }),
        ),
      ));
      double opacity() =>
          tester.widget<Opacity>(find.byKey(const Key('list-opacity'))).opacity;
      c.jumpTo(c.position.maxScrollExtent * startFraction);
      await tester.pump(_frame);
      if (opacity() != 1.0) return '평소엔 보여야 한다';

      // 전체 목록이 올라온 순간: 가리고 큰 캐시를 켠 채 위치를 잡는다.
      var done = 0;
      setOuter(() => settling = true);
      seekSimpleListToIndex(
        c,
        indexOf: () => anchor,
        isCurrent: () => true,
        itemCount: () => heights.length,
        onDone: () {
          done++;
          setOuter(() => settling = false);
        },
      );
      await tester.pump(_frame); // 첫 프레임: 가려진 채 레이아웃 → 위치 읽고 점프
      if (opacity() != 0.0) return '엉뚱한 위치의 첫 프레임이 가려지지 않았다';
      if (done != 1) return '첫 프레임에 한 번의 점프로 끝나지 않았다 (done=$done)';
      for (var i = 0; i < heights.length; i++) {
        // skipOffstage: false — 캐시 범위에만 걸친(화면 밖) 칸도 찾아야 "전부 레이아웃됨"을 알 수 있다.
        if (find.text('card $i', skipOffstage: false).evaluate().isEmpty) {
          return '첫 프레임에 모든 칸이 레이아웃되지 않았다 (card $i 없음)';
        }
      }
      await tester.pump(_frame); // 둘째 프레임: 보임 + 평소 캐시로 복귀
      if (opacity() != 1.0) return '위치를 잡은 뒤에도 목록이 가려져 있다';
      if (!anyTileVisible(tester)) return '빈 화면 프레임';
      if (!tileOnScreen(tester, anchor)) return '앵커가 화면 밖';
      if (!tileAtTopOrListEnd(tester, c, anchor)) return '앵커가 맨 위가 아님';
      return null;
    }

    testWidgets('앞쪽이 큰 폴더: 앵커 15·25 (물려받은 위치가 맨 위/중간/끝)', (tester) async {
      setView(tester, 800);
      final heights = [
        for (var i = 0; i < 10; i++) 800.0,
        for (var i = 0; i < 20; i++) 120.0,
      ];
      final fails = <String>[];
      for (final anchor in [15, 25]) {
        for (final start in [0.0, 0.4, 0.9]) {
          final r = await runSettle(tester, heights, anchor, start);
          if (r != null) fails.add('anchor $anchor start $start: $r');
        }
      }
      expect(fails, isEmpty, reason: fails.join('\n'));
    });

    testWidgets('높이가 제각각인 15~30장 무작위 폴더 150개(고정 시드)', (tester) async {
      setView(tester, 800);
      final rnd = math.Random(7);
      final fails = <String>[];
      for (var t = 0; t < 150; t++) {
        final n = 15 + rnd.nextInt(16);
        final heights = [
          for (var i = 0; i < n; i++)
            100.0 +
                rnd.nextInt(80) +
                (rnd.nextDouble() < 0.25 ? 300.0 + rnd.nextInt(400) : 0.0),
        ];
        final anchor = rnd.nextInt(n);
        final r = await runSettle(tester, heights, anchor, rnd.nextDouble());
        if (r != null) {
          fails.add('n=$n anchor=$anchor: $r '
              'heights=${heights.map((h) => h.toInt()).toList()}');
        }
      }
      expect(fails, isEmpty,
          reason: '실패 ${fails.length}/150\n${fails.take(3).join('\n')}');
    });

    test('평소(settling=false)에는 기본 캐시 범위와 불투명이다', () {
      expect(searchExitCacheExtent(settling: false), isNull);
      expect(searchExitListOpacity(settling: false), 1.0);
      expect(searchExitCacheExtent(settling: true), kSearchExitSeekCacheExtent);
      expect(searchExitListOpacity(settling: true), 0.0);
    });
  });
}
