import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memora/l10n/app_localizations.dart';
import 'package:memora/models/card.dart';
import 'package:memora/screens/card_list_screen.dart';
import 'package:memora/widgets/card_tile.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// 접기/보이기 탭 후에도 **누른 그 카드가 손가락 밑에 남는다** (다른 카드가 미끄러져 오면 안 된다).
///
/// 진짜 CardTile(질문 줄·답 영역·접힘/숨김 높이가 실제 값)을 화면과 같은 배선(Builder(itemContext) →
/// PressObserver → CardTile → 탭 → reanchorTappedCard → setState)으로 평범한 SPL 호스트에 붙여 검증한다
/// (화면은 sqlite 때문에 위젯 테스트로 못 띄운다. 화면 쪽 배선은 card_list_spl_remount_test의 소스 가드가 지킨다).
/// 호스트는 화면과 같은 순수 규칙 answerTapResizeKind를 그대로 쓴다.
///
/// 회귀 배경: 위로 잘린 카드의 질문 탭을 "줄어드는 카드"로 보고 아래쪽 가장자리를 고정(다음 칸을 target으로)하면,
/// 접을 때 카드가 [-8,249]→[169,249]로 밀려 손가락 밑이 윗 카드가 되고, 펼 때 질문 줄이 177dp 위로 사라졌다.
/// 질문 탭은 위쪽 가장자리 고정이 맞다 (부모 980c791과 같은 결과).

List<CardModel> _cards(int n, {Map<int, int> answerRepeats = const {}}) => [
      for (var i = 0; i < n; i++)
        CardModel(
          id: i + 1,
          uuid: 'u$i',
          folderId: 1,
          question: 'Q$i word',
          answer: List.filled(answerRepeats[i] ?? (4 + (i % 3) * 3), 'answer text line').join(' '),
        ),
    ];

class _Host extends StatefulWidget {
  const _Host({
    super.key,
    required this.cards,
    this.allFolded = false,
    this.allHidden = false,
    this.revealed = const {},
  });
  final List<CardModel> cards;
  final bool allFolded; // 모든 카드가 접힌 상태로 시작 (탭하면 펴진다)
  final bool allHidden; // 화면의 _allAnswersHidden
  final Set<int> revealed; // 숨김 모드에서 이미 펼쳐진 카드 id
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  final isc = ItemScrollController();
  final ipl = ItemPositionsListener.create();
  late final SplRemountController spl =
      SplRemountController(itemScrollController: isc, itemPositionsListener: ipl);
  final toggled = <int>{};
  late final Set<int> revealed = {...widget.revealed};
  final log = <String>[];

  /// 테스트가 State 밖에서 setState를 부르기 위한 통로.
  void rebuild(VoidCallback fn) => setState(fn);

  bool folded(CardModel c) => widget.allFolded ? !toggled.contains(c.id) : toggled.contains(c.id);

  Widget item(BuildContext context, int index) {
    final card = widget.cards[index];
    return Builder(
      builder: (itemContext) => PressObserver(
        onPress: () {},
        child: KeyedSubtree(
          key: ValueKey('card$index'),
          child: CardTile(
            card: card,
            isFolded: folded(card),
            isHidden: widget.allHidden,
            isRevealed: widget.allHidden ? revealed.contains(card.id) : true,
            // 화면의 _toggleQuestionFold
            onQuestionTap: () {
              final did = reanchorTappedCard(
                spl: spl,
                itemContext: itemContext,
                index: index,
                itemCount: widget.cards.length,
                kind: CardResizeKind.questionToggle,
                setState: setState,
              );
              log.add('question $index remount=$did');
              setState(() {
                if (!toggled.remove(card.id)) toggled.add(card.id!);
              });
            },
            // 화면의 _toggleAnswerReveal
            onAnswerTap: () {
              final kind = answerTapResizeKind(
                allAnswersHidden: widget.allHidden,
                answerRevealed: revealed.contains(card.id),
              );
              var did = false;
              if (kind != null) {
                did = reanchorTappedCard(
                  spl: spl,
                  itemContext: itemContext,
                  index: index,
                  itemCount: widget.cards.length,
                  kind: kind,
                  setState: setState,
                );
              }
              log.add('answer $index kind=$kind remount=$did');
              setState(() {
                if (!revealed.remove(card.id)) revealed.add(card.id!);
              });
            },
            onTap: () => log.add('EDIT $index'),
            onLongPress: () {},
            onMenuAction: (_) {},
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Folder')),
        body: Stack(children: [
          spl.build(
            itemCount: widget.cards.length,
            itemBuilder: item,
            physics: const ClampingScrollPhysics(),
          ),
        ]),
      );
}

class _Fx {
  _Fx(this.tester, this.key, this.vpTop, this.n);
  final WidgetTester tester;
  final GlobalKey<_HostState> key;
  final double vpTop;
  final int n;

  _HostState get host => key.currentState!;
  ScrollPosition get pos => tester.state<ScrollableState>(find.byType(Scrollable).first).position;

  Finder card(int i) => find.byKey(ValueKey('card$i'));

  Rect? rect(int i) {
    final f = card(i);
    if (f.evaluate().isEmpty) return null;
    return tester.getRect(f).shift(Offset(0, -vpTop));
  }

  Rect inCard(int i, Finder matching) =>
      tester.getRect(find.descendant(of: card(i), matching: matching)).shift(Offset(0, -vpTop));

  Rect question(int i) => inCard(i, find.text('Q$i word'));

  /// 답 영역의 본문(보이는 답) — 숨김 모드에서 가려진 답은 이탤릭 안내 문구.
  Rect answerText(int i) => inCard(i, find.textContaining('answer text line'));
  Rect revealHint(int i) => inCard(
      i,
      find.byWidgetPredicate(
          (w) => w is Text && w.style?.fontStyle == FontStyle.italic));

  int? under(double y) {
    for (var i = 0; i < n; i++) {
      final r = rect(i);
      if (r != null && r.top <= y && y < r.bottom) return i;
    }
    return null;
  }

  /// 카드 [i]의 위쪽이 목록 뷰포트 위쪽 기준 [top]에 오도록 스크롤한다 (레이아웃된 칸이 될 때까지 이동).
  Future<void> bring(int i, double top) async {
    for (var n = 0; n < 40 && rect(i) == null; n++) {
      var lowest = -1;
      for (var k = 0; k < this.n; k++) {
        if (rect(k) != null) {
          lowest = k;
          break;
        }
      }
      pos.jumpTo(pos.pixels + (i < lowest ? -400 : 400));
      await tester.pumpAndSettle();
    }
    expect(rect(i), isNotNull, reason: '카드 $i를 레이아웃시키지 못했다');
    pos.jumpTo(pos.pixels + (rect(i)!.top - top));
    await tester.pumpAndSettle();
    expect(rect(i)!.top, closeTo(top, 0.5));
  }

  Future<void> tapAtViewportY(double y) async {
    await tester.tapAt(Offset(150, vpTop + y));
    await tester.pumpAndSettle();
  }
}

/// [aboveTarget]이면 target을 40번으로 옮겨 둬서 눌릴 카드(<40)가 target 위쪽(역방향 sliver) 칸이 되게 한다.
Future<_Fx> _mount(
  WidgetTester tester, {
  required List<CardModel> cards,
  bool allFolded = false,
  bool allHidden = false,
  Set<int> revealed = const {},
  bool aboveTarget = false,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  final key = GlobalKey<_HostState>();
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: _Host(key: key, cards: cards, allFolded: allFolded, allHidden: allHidden, revealed: revealed),
  ));
  await tester.pumpAndSettle();
  final vpTop = tester.getTopLeft(find.byType(ScrollablePositionedList)).dy;
  final fx = _Fx(tester, key, vpTop, cards.length);
  if (aboveTarget) {
    fx.host.spl.jumpTo(40, setState: fx.host.rebuild);
    await tester.pumpAndSettle();
  }
  return fx;
}

void _expectSide(WidgetTester tester, _Fx fx, int idx, {required bool aboveTarget}) {
  expect(laidOutAboveListTarget(tester.element(fx.card(idx))), aboveTarget,
      reason: '이 시나리오의 전제: 카드 $idx는 target ${aboveTarget ? "위쪽" : "이상"} 칸');
}

void main() {
  // ───────────── 질문 탭: 위로 잘린 카드, 보이는 질문 줄을 눌러도 그 카드가 손가락 밑에 남는다 ─────────────
  for (final aboveTarget in [false, true]) {
    for (final allFolded in [false, true]) {
      for (final cut in [8.0, 15.0, 30.0]) {
        final idx = aboveTarget ? 37 : 10;
        testWidgets(
            '질문 탭 ${allFolded ? "펴기" : "접기"}: 위로 $cut dp 잘린 카드, 첫 질문 줄 (${aboveTarget ? "target 위쪽 칸" : "target 이상 칸"})',
            (tester) async {
          final fx = await _mount(tester,
              cards: _cards(80), allFolded: allFolded, aboveTarget: aboveTarget);
          await fx.bring(idx, -cut);
          _expectSide(tester, fx, idx, aboveTarget: aboveTarget);
          final before = fx.rect(idx)!;
          final q = fx.question(idx);
          final fingerY = (q.top < 0 ? 0 : q.top) / 2 + q.bottom / 2;
          expect(fingerY, greaterThan(0));
          expect(fx.under(fingerY), idx);
          final epoch = fx.host.spl.epoch;

          await fx.tapAtViewportY(fingerY);

          expect(tester.takeException(), isNull);
          expect(fx.host.toggled, contains(idx + 1), reason: '탭이 질문 접기/펴기로 처리됐다');
          final after = fx.rect(idx);
          expect(after, isNotNull, reason: '카드가 화면에서 사라지면 안 된다');
          expect(after!.top, closeTo(before.top, 1.0), reason: '위쪽 가장자리 고정 (부모 980c791과 같은 결과)');
          expect(fx.question(idx).top, closeTo(q.top, 1.0), reason: '질문 줄이 손가락 밑에서 안 움직인다');
          expect(fx.under(fingerY), idx, reason: '손가락 밑은 여전히 누른 카드');
          if (allFolded) {
            expect(after.height, greaterThan(before.height), reason: '펴졌다');
          } else {
            expect(after.height, lessThan(before.height), reason: '접혔다');
          }
          if (aboveTarget) {
            expect(fx.host.spl.epoch, greaterThan(epoch), reason: 'target 위쪽 칸은 위쪽 가장자리를 붙잡으려고 다시 마운트');
          } else {
            expect(fx.host.spl.epoch, epoch, reason: 'target 이상 칸은 위쪽이 원래 고정 — 다시 마운트하지 않는다');
          }
        });
      }
    }
  }

  testWidgets('질문 탭 접고 바로 다시 펴기: 둘 다 질문 줄이 제자리 (위로 잘린 target 위쪽 칸)', (tester) async {
    final fx = await _mount(tester, cards: _cards(80), aboveTarget: true);
    await fx.bring(37, -20);
    final q = fx.question(37);
    final fingerY = (q.top < 0 ? 0 : q.top) / 2 + q.bottom / 2;
    final top = fx.rect(37)!.top;
    await fx.tapAtViewportY(fingerY); // 접기
    expect(fx.rect(37)!.top, closeTo(top, 1.0));
    expect(fx.under(fingerY), 37);
    await fx.tapAtViewportY(fingerY); // 펴기
    expect(tester.takeException(), isNull);
    expect(fx.host.toggled, isEmpty);
    expect(fx.rect(37)!.top, closeTo(top, 1.0));
    expect(fx.question(37).top, closeTo(q.top, 1.0));
    expect(fx.under(fingerY), 37);
  });

  testWidgets('맨 위 카드(0번)가 target 위쪽 칸으로 조금 잘렸을 때 접어도 목록 맨 위까지 올라갈 수 있다', (tester) async {
    final fx = await _mount(tester, cards: _cards(80), aboveTarget: false);
    fx.host.spl.jumpTo(3, setState: fx.host.rebuild);
    await tester.pumpAndSettle();
    await fx.bring(0, -20);
    _expectSide(tester, fx, 0, aboveTarget: true);
    final q = fx.question(0);
    final fingerY = (q.top < 0 ? 0 : q.top) / 2 + q.bottom / 2;
    final epoch = fx.host.spl.epoch;
    await fx.tapAtViewportY(fingerY);
    expect(tester.takeException(), isNull);
    expect(fx.host.spl.epoch, greaterThan(epoch));
    expect(fx.rect(0)!.top, closeTo(-20, 1.0));
    expect(fx.under(fingerY), 0);
    // 위로 끝까지 끌어내리면 0번 카드가 맨 위(0)에 닿는다 (음수 정렬로 다시 마운트해도 위쪽 범위가 막히지 않는다)
    await tester.dragFrom(Offset(150, fx.vpTop + 300), const Offset(0, 2000));
    await tester.pumpAndSettle();
    expect(fx.rect(0)!.top, closeTo(0, 0.5));
  });

  // ───────────── 답 탭: 숨김 모드 ─────────────
  for (final aboveTarget in [false, true]) {
    testWidgets(
        '답 숨기기(줄어듦): 위로 150dp 잘리고 아래쪽이 화면 안인 카드는 아래쪽 가장자리 고정, 손가락 밑에 남는다 (${aboveTarget ? "target 위쪽 칸" : "target 이상 칸"})',
        (tester) async {
      final idx = aboveTarget ? 37 : 10;
      final fx = await _mount(tester,
          cards: _cards(80, answerRepeats: {idx: 22}),
          allHidden: true,
          revealed: {idx + 1},
          aboveTarget: aboveTarget);
      await fx.bring(idx, -150);
      _expectSide(tester, fx, idx, aboveTarget: aboveTarget);
      final before = fx.rect(idx)!;
      expect(before.bottom, greaterThan(100));
      expect(before.bottom, lessThan(tester.getSize(find.byType(ScrollablePositionedList)).height - 100));
      final a = fx.answerText(idx);
      final fingerY = a.bottom - 6; // 보이는 답 본문의 맨 아래쪽
      expect(fingerY, greaterThan(0));
      expect(fx.under(fingerY), idx);
      final below = fx.rect(idx + 1)!;
      final epoch = fx.host.spl.epoch;

      await fx.tapAtViewportY(fingerY);

      expect(tester.takeException(), isNull);
      expect(fx.host.log.last, contains('kind=CardResizeKind.answerHide'));
      expect(fx.host.revealed, isNot(contains(idx + 1)), reason: '답이 가려졌다');
      final after = fx.rect(idx);
      expect(after, isNotNull, reason: '카드가 화면에서 사라지면 안 된다');
      expect(after!.bottom, closeTo(before.bottom, 1.0), reason: '아래쪽 가장자리 고정');
      expect(after.height, lessThan(before.height - 100), reason: '줄어들었다');
      expect(fx.rect(idx + 1)!.top, closeTo(below.top, 1.0), reason: '바로 아래 카드는 그대로');
      expect(after.contains(Offset(150, fingerY)), isTrue, reason: '손가락 밑에 그 카드가 남는다');
      expect(fx.under(fingerY), idx);
      if (aboveTarget) {
        expect(fx.host.spl.epoch, epoch, reason: 'target 위쪽 칸은 원래 아래쪽이 고정 — 다시 마운트하지 않는다');
      } else {
        expect(fx.host.spl.epoch, greaterThan(epoch), reason: '다음 칸을 아래쪽 가장자리에 맞춰 다시 마운트');
      }
    });

    for (final top in [-30.0, 100.0]) {
      testWidgets(
          '답 보이기(커짐): 위쪽 가장자리가 고정된다 — 위쪽 y=$top (${aboveTarget ? "target 위쪽 칸" : "target 이상 칸"})',
          (tester) async {
        final idx = aboveTarget ? 37 : 10;
        final fx = await _mount(tester,
            cards: _cards(80), allHidden: true, aboveTarget: aboveTarget);
        await fx.bring(idx, top);
        _expectSide(tester, fx, idx, aboveTarget: aboveTarget);
        final before = fx.rect(idx)!;
        final h = fx.revealHint(idx);
        final fingerY = (h.top < 0 ? 0 : h.top) / 2 + h.bottom / 2;
        expect(fingerY, greaterThan(0));
        expect(fx.under(fingerY), idx);
        final q = fx.question(idx);
        final epoch = fx.host.spl.epoch;

        await fx.tapAtViewportY(fingerY);

        expect(tester.takeException(), isNull);
        expect(fx.host.log.last, contains('kind=CardResizeKind.answerReveal'));
        expect(fx.host.revealed, contains(idx + 1));
        final after = fx.rect(idx)!;
        expect(after.height, greaterThan(before.height), reason: '커졌다');
        expect(after.top, closeTo(before.top, 1.0), reason: '위쪽 가장자리 고정');
        expect(fx.question(idx).top, closeTo(q.top, 1.0), reason: '질문 줄이 안 움직인다');
        expect(fx.under(fingerY), idx, reason: '손가락 밑은 여전히 누른 카드');
        if (aboveTarget) {
          expect(fx.host.spl.epoch, greaterThan(epoch), reason: 'target 위쪽 칸은 위쪽을 붙잡으려고 다시 마운트');
        } else {
          expect(fx.host.spl.epoch, epoch, reason: 'target 이상 칸은 위쪽이 원래 고정 — 다시 마운트하지 않는다');
        }
      });
    }

    for (final top in [-30.0, 100.0]) {
      testWidgets(
          '숨김 모드가 아닐 때 답 탭은 높이가 안 바뀌므로 다시 마운트하지 않는다 — 위쪽 y=$top (${aboveTarget ? "target 위쪽 칸" : "target 이상 칸"})',
          (tester) async {
        final idx = aboveTarget ? 37 : 10;
        final fx = await _mount(tester, cards: _cards(80), allHidden: false, aboveTarget: aboveTarget);
        await fx.bring(idx, top);
        _expectSide(tester, fx, idx, aboveTarget: aboveTarget);
        final before = fx.rect(idx)!;
        final a = fx.answerText(idx);
        final fingerY = (a.top < 0 ? 0 : a.top) / 2 + a.bottom / 2;
        expect(fingerY, greaterThan(0));
        expect(fx.under(fingerY), idx);
        final epoch = fx.host.spl.epoch;

        await fx.tapAtViewportY(fingerY);

        expect(tester.takeException(), isNull);
        expect(fx.host.log.last, contains('kind=null remount=false'));
        expect(fx.host.revealed, contains(idx + 1), reason: '탭 자체는 처리됐다');
        expect(fx.host.spl.epoch, epoch, reason: '높이가 안 바뀌는 탭은 목록을 다시 마운트하지 않는다');
        final after = fx.rect(idx)!;
        expect(after.top, closeTo(before.top, 0.5));
        expect(after.bottom, closeTo(before.bottom, 0.5));
        expect(fx.under(fingerY), idx);
      });
    }
  }
}
