import 'dart:async';

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
/// PressObserver(onRelease) → CardTile → 탭 → keepTappedCardUnderFinger → setState)으로 소량 목록(ListView)과
/// 대량 목록(SPL) 호스트에 붙여 검증한다 (화면은 sqlite 때문에 위젯 테스트로 못 띄운다. 화면 쪽 배선은
/// card_list_spl_remount_test의 소스 가드가 지킨다).
///
/// 계약: 접기/보이기/숨기기를 눌러 카드가 줄어들 때, 카드의 질문·답·안내 문구든 그 둘레든 **손가락 밑에 그 카드가
/// 남는다**(다른 카드가 아니다). 첫 프레임부터 최종 위치다(번쩍임 없음). 커지는 탭은 위쪽 가장자리 그대로. 위쪽을
/// 그대로 둬도 손가락 밑이면 움직이지 않는다. 목록 맨 처음/끝은 스크롤 범위가 막아 손가락 밑이 아닐 수 있지만
/// 빈 공간 없이 가장자리에 붙는다. 예측 높이(predictCardTileHeightAfterTap)는 실제 높이와 같아야 한다.
///
/// 회귀 배경: 위로 잘린 카드의 질문 탭을 "줄어드는 카드"로 보고 아래쪽 가장자리를 고정(다음 칸을 target으로)하면,
/// 접을 때 카드가 [-8,249]→[169,249]로 밀려 손가락 밑이 윗 카드가 되고, 펼 때 질문 줄이 177dp 위로 사라졌다.

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

String _lines(String p, int n) =>
    [for (var k = 0; k < n; k++) '$p L$k'].join(String.fromCharCode(10));

CardModel _mk(
  int i, {
  String? q,
  String? a,
  List<String> aImages = const [],
  List<String> qImages = const [],
}) =>
    CardModel(
      id: i + 1,
      uuid: 'u$i',
      folderId: 1,
      question: q ?? 'Q$i word',
      answer: a ?? List.filled(4 + (i % 3) * 3, 'answer text line').join(' '),
      answerImagePath: aImages.isNotEmpty ? aImages[0] : null,
      answerImagePath2: aImages.length > 1 ? aImages[1] : null,
      questionImagePath: qImages.isNotEmpty ? qImages[0] : null,
    );

class _Host extends StatefulWidget {
  const _Host({
    super.key,
    required this.cards,
    this.allFolded = false,
    this.allHidden = false,
    this.revealed = const {},
    this.simple = false,
    this.guard = true,
    this.rule = true,
    this.clampOnResize = true,
  });
  final List<CardModel> cards;
  final bool allFolded; // 모든 카드가 접힌 상태로 시작 (탭하면 펴진다)
  final bool allHidden; // 화면의 _allAnswersHidden
  final Set<int> revealed; // 숨김 모드에서 이미 펼쳐진 카드 id
  final bool simple; // true = 소량 목록(ListView), false = 대량 목록(SPL)
  final bool guard; // false = 다시 빌드 대기 중 가드를 끈 대조군 (hostContext: itemContext)
  final bool rule; // false = 붙잡지 않는 대조군
  final bool clampOnResize; // false = 화면의 ClampOnResizeScrollPhysics 대신 평범한 ClampingScrollPhysics (대조군)
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  final isc = ItemScrollController();
  final ipl = ItemPositionsListener.create();
  late final SplRemountController spl =
      SplRemountController(itemScrollController: isc, itemPositionsListener: ipl);
  final sc = ScrollController();
  late List<CardModel> cards = widget.cards;
  final toggled = <int>{};
  late final Set<int> revealed = {...widget.revealed};
  final log = <String>[];
  double? predicted; // 마지막 탭 직전에 예측한 높이
  Offset? release; // 화면의 _releaseGlobal
  int releases = 0;
  int overscrolls = 0; // OverscrollNotification count/sum (physics A/B comparison)
  double overscrollSum = 0;
  int _token = 0;

  /// 테스트가 State 밖에서 setState를 부르기 위한 통로.
  void rebuild(VoidCallback fn) => setState(fn);

  /// 화면의 _recordRelease
  void rec(Offset p) {
    release = p;
    releases++;
    final t = ++_token;
    scheduleMicrotask(() {
      if (t == _token) release = null;
    });
  }

  bool folded(CardModel c) => widget.allFolded ? !toggled.contains(c.id) : toggled.contains(c.id);

  /// 화면의 _keepTappedCardUnderFinger
  bool keep(int index, BuildContext itemContext, CardTileTap tap) {
    predicted = predictCardTileHeightAfterTap(itemContext, tap);
    if (!widget.rule) return false;
    return keepTappedCardUnderFinger(
      hostContext: widget.guard ? context : itemContext,
      itemContext: itemContext,
      index: index,
      itemCount: cards.length,
      tap: tap,
      fingerGlobal: release,
      spl: widget.simple ? null : spl,
      setState: setState,
    );
  }

  Widget item(BuildContext context, int index) {
    final card = cards[index];
    return Builder(
      builder: (itemContext) => PressObserver(
        onPress: () {},
        onRelease: rec,
        child: KeyedSubtree(
          key: ValueKey('card${card.id}'),
          child: CardTile(
            card: card,
            isFolded: folded(card),
            isHidden: widget.allHidden,
            isRevealed: widget.allHidden ? revealed.contains(card.id) : true,
            // 화면의 _toggleQuestionFold
            onQuestionTap: () {
              final did = keep(index, itemContext, CardTileTap.question);
              log.add('question $index remount=$did');
              setState(() {
                if (!toggled.remove(card.id)) toggled.add(card.id!);
              });
            },
            // 화면의 _toggleAnswerReveal — 숨김 모드가 아니면 붙잡지 않는다
            onAnswerTap: () {
              var did = false;
              if (widget.allHidden) did = keep(index, itemContext, CardTileTap.answer);
              log.add('answer $index remount=$did');
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
        body: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n is OverscrollNotification) {
              overscrolls++;
              overscrollSum += n.overscroll;
            }
            return false;
          },
          child: Stack(children: [
          widget.simple
              ? ListView.builder(
                  controller: sc,
                  itemCount: cards.length,
                  itemBuilder: item,
                  // 화면(_buildCardList)의 소량 목록과 같은 물리 — 소스 가드는 card_list_spl_remount_test
                  physics: widget.clampOnResize
                      ? const ClampOnResizeScrollPhysics()
                      : const ClampingScrollPhysics(),
                )
              : spl.build(
                  itemCount: cards.length,
                  itemBuilder: item,
                  physics: const ClampingScrollPhysics(),
                ),
          ]),
        ),
      );
}

class _Fx {
  _Fx(this.tester, this.key, this.vpTop, this.vpH);
  final WidgetTester tester;
  final GlobalKey<_HostState> key;
  final double vpTop;
  final double vpH;

  _HostState get host => key.currentState!;
  int get n => host.cards.length;
  ScrollPosition get pos => tester.state<ScrollableState>(find.byType(Scrollable).first).position;

  Finder card(int i) => find.byKey(ValueKey('card${host.cards[i].id}'));

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
  Future<void> bring(int i, double top, {bool strict = true}) async {
    for (var k = 0; k < 80 && rect(i) == null; k++) {
      var lowest = -1;
      for (var j = 0; j < n; j++) {
        if (rect(j) != null) {
          lowest = j;
          break;
        }
      }
      pos.jumpTo(pos.pixels + (i < lowest ? -400 : 400));
      await tester.pumpAndSettle();
    }
    expect(rect(i), isNotNull, reason: '카드 $i를 레이아웃시키지 못했다');
    pos.jumpTo(pos.pixels + (rect(i)!.top - top));
    await tester.pumpAndSettle();
    if (strict) expect(rect(i)!.top, closeTo(top, 0.5));
  }

  Future<void> tapAtViewportY(double y) async {
    await tester.tapAt(Offset(150, vpTop + y));
    await tester.pumpAndSettle();
  }
}

/// [aboveTarget]이면 target을 40번으로 옮겨 둬서 눌릴 카드(<40)가 target 위쪽(역방향 sliver) 칸이 되게 한다.
/// [target]은 직접 지정(대량 목록 전용).
Future<_Fx> _mount(
  WidgetTester tester, {
  required List<CardModel> cards,
  bool allFolded = false,
  bool allHidden = false,
  Set<int> revealed = const {},
  bool aboveTarget = false,
  int? target,
  bool simple = false,
  bool guard = true,
  bool rule = true,
  bool clampOnResize = true,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  final key = GlobalKey<_HostState>();
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(colorSchemeSeed: const Color(0xFFFF6B6B), useMaterial3: true),
    locale: const Locale('ko'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: _Host(
      key: key,
      cards: cards,
      allFolded: allFolded,
      allHidden: allHidden,
      revealed: revealed,
      simple: simple,
      guard: guard,
      rule: rule,
      clampOnResize: clampOnResize,
    ),
  ));
  await tester.pumpAndSettle();
  final lf = simple ? find.byType(ListView) : find.byType(ScrollablePositionedList);
  final fx = _Fx(tester, key, tester.getTopLeft(lf).dy, tester.getSize(lf).height);
  final t = target ?? (aboveTarget ? 40 : null);
  if (t != null) {
    fx.host.spl.jumpTo(t, setState: fx.host.rebuild);
    await tester.pumpAndSettle();
  }
  return fx;
}

void _expectSide(WidgetTester tester, _Fx fx, int idx, {required bool aboveTarget}) {
  expect(laidOutAboveListTarget(tester.element(fx.card(idx))), aboveTarget,
      reason: '이 시나리오의 전제: 카드 $idx는 target ${aboveTarget ? "위쪽" : "이상"} 칸');
}

String _fmt(Rect? r) => r == null ? 'off' : '${r.top.toStringAsFixed(1)}..${r.bottom.toStringAsFixed(1)}';

// ───────────── 진짜 CardTile 탭 한 번의 결과 + 규칙 검사 ─────────────

typedef _Tap = ({
  Rect before,
  Rect? first,
  Rect? after,
  int? underBefore,
  int? underAfter,
  double? pred,
  int epochDelta,
  Object? exception,
  double pixels,
  double minExtent,
  double maxExtent,
  double firstOver, // 첫 프레임의 스크롤 위치가 [min, max] 범위를 벗어난 만큼 (소량 목록만, 아니면 0)
  double firstBlank, // 첫 프레임에서 마지막 카드 아래의 빈 공간 dp (마지막 카드가 그려졌을 때만, 아니면 0)
  bool lastLaidBefore, // 탭 직전에 마지막 카드가 레이아웃돼 있었나
  double settledMax, // 정착 뒤 maxScrollExtent (탭 직전 값은 마지막 카드가 레이아웃 전이면 추정치다)
  double settledBlank, // 정착 뒤 마지막 카드 아래 빈 공간 dp (소량 목록만)
});

/// 뷰포트 y [finger]를 눌러 첫 프레임(pump 한 번)과 정착 뒤(pumpAndSettle)를 각각 읽는다.
Future<_Tap> _tap(WidgetTester tester, _Fx fx, int idx, double finger) async {
  final before = fx.rect(idx)!;
  final ub = fx.under(finger);
  final p = fx.pos.pixels, mn = fx.pos.minScrollExtent, mx = fx.pos.maxScrollExtent;
  final e0 = fx.host.spl.epoch;
  final lastLaidBefore = fx.rect(fx.n - 1) != null;
  fx.host.predicted = null;
  await tester.tapAt(Offset(150, fx.vpTop + finger));
  await tester.pump();
  final first = fx.rect(idx);
  var firstOver = 0.0, firstBlank = 0.0;
  if (fx.host.widget.simple) {
    final pos = fx.pos;
    firstOver = [pos.pixels - pos.maxScrollExtent, pos.minScrollExtent - pos.pixels, 0.0].reduce((a, b) => a > b ? a : b);
    final last = fx.rect(fx.n - 1);
    if (last != null && last.bottom < fx.vpH) firstBlank = fx.vpH - last.bottom;
  }
  await tester.pumpAndSettle();
  var settledBlank = 0.0;
  if (fx.host.widget.simple) {
    final last = fx.rect(fx.n - 1);
    if (last != null && last.bottom < fx.vpH) settledBlank = fx.vpH - last.bottom;
  }
  return (
    before: before,
    first: first,
    after: fx.rect(idx),
    underBefore: ub,
    underAfter: fx.under(finger),
    pred: fx.host.predicted,
    epochDelta: fx.host.spl.epoch - e0,
    exception: tester.takeException(),
    pixels: p,
    minExtent: mn,
    maxExtent: mx,
    firstOver: firstOver,
    firstBlank: firstBlank,
    lastLaidBefore: lastLaidBefore,
    settledMax: fx.pos.maxScrollExtent,
    settledBlank: settledBlank,
  );
}

/// [_tap] 뒤 규칙 전부를 검사한다: 예외 없음, 손가락이 눌린 카드 위, 첫 프레임 == 정착, 예측 == 실제(±0.5),
/// 위쪽 == keptTopAfterResize, 커지면 위쪽 그대로, 가능하면(범위 자르기가 안 걸리면) 손가락이 카드 몸체 안,
/// 위쪽을 그대로 둬도 되는 경우는 움직이지 않는다.
Future<_Tap> _tapAndCheck(WidgetTester tester, _Fx fx, int idx, double finger, String name) async {
  final r = await _tap(tester, fx, idx, finger);
  final before = r.before, first = r.first, after = r.after, pred = r.pred;
  // 소량 목록: 탭 직전 maxScrollExtent는 마지막 카드가 레이아웃 전이면 추정치라, 범위 자르기의 기준은 정착 뒤 실제 끝이다
  // (줄어든 만큼을 되돌려 넣는다 — keptTopAfterResize가 다시 뺀다).
  final shrunk = pred != null && pred < before.height ? before.height - pred : 0.0;
  final maxForRule = fx.host.widget.simple ? r.settledMax + shrunk : r.maxExtent;
  final expTop = keptTopAfterResize(
      top: before.top, height: before.height, newHeight: pred, fingerY: finger,
      pixels: r.pixels, minScrollExtent: r.minExtent, maxScrollExtent: maxForRule);
  final wanted = keptTopAfterResize(
      top: before.top, height: before.height, newHeight: pred, fingerY: finger,
      pixels: 0, minScrollExtent: -1e9, maxScrollExtent: 1e9);
  final feasible = (expTop - wanted).abs() < 0.5;
  final problems = <String>[];
  if (r.exception != null) problems.add('EXC ${r.exception}');
  if (r.firstOver > 0.5) problems.add('FIRST FRAME OUT OF RANGE by ${r.firstOver.toStringAsFixed(1)}');
  // 내용이 뷰포트보다 짧은 목록(정착 뒤 maxScrollExtent == 0)은 마지막 카드 아래가 비는 게 정상이다 — 스크롤이 되는 목록만 검사한다.
  final canScroll = r.settledMax > 0.5;
  if (canScroll && r.settledBlank > 0.5) problems.add('BLANK below last card ${r.settledBlank.toStringAsFixed(1)} after settle');
  if (canScroll && r.firstBlank > 0.5) problems.add('BLANK below last card ${r.firstBlank.toStringAsFixed(1)} in first frame');
  if (r.underBefore != idx) problems.add('precondition: finger not on card before (under=${r.underBefore})');
  if (first == null || after == null) {
    problems.add('card offscreen first=${_fmt(first)} after=${_fmt(after)}');
  } else {
    if ((first.top - after.top).abs() > 0.5 || (first.height - after.height).abs() > 0.5) {
      problems.add('FLASH first=${_fmt(first)} settled=${_fmt(after)}');
    }
    if (pred != null && (pred - after.height).abs() > 0.5) {
      problems.add('PRED ${pred.toStringAsFixed(1)} vs actual ${after.height.toStringAsFixed(1)}');
    }
    if ((after.top - expTop).abs() > 0.5) {
      problems.add('RULE top ${after.top.toStringAsFixed(1)} expected ${expTop.toStringAsFixed(1)}');
    }
    if (after.height >= before.height - 0.5 && (after.top - before.top).abs() > 0.5) {
      problems.add('GROW moved top ${before.top.toStringAsFixed(1)}->${after.top.toStringAsFixed(1)}');
    }
    final onBody = finger >= after.top + 4 && finger <= after.bottom - 4;
    if (feasible && !onBody) problems.add('NOT UNDER FINGER');
    if (feasible &&
        before.top + after.height - kFingerInsetOnCard >= finger &&
        (after.top - before.top).abs() > 0.5) {
      problems.add('MOVED though top-fixed would keep it');
    }
  }
  expect(
    problems,
    isEmpty,
    reason: '$name | finger=${finger.toStringAsFixed(1)} before=${_fmt(before)} first=${_fmt(first)} '
        'after=${_fmt(after)} pred=${pred?.toStringAsFixed(1)} exp=${expTop.toStringAsFixed(1)} '
        'feasible=$feasible under ${r.underBefore}->${r.underAfter} epoch+${r.epochDelta}',
  );
  return r;
}

enum _L { splFwd, splAbove, splTarget, listView }

int _nFor(_L l) => l == _L.listView ? 25 : 80;
int _idxFor(_L l) => switch (l) { _L.splFwd => 10, _L.splAbove => 37, _L.splTarget => 40, _L.listView => 10 };
int? _targetFor(_L l) => (l == _L.splAbove || l == _L.splTarget) ? 40 : null;

Future<_Fx> _setup(
  WidgetTester tester,
  _L l,
  List<CardModel> Function(int n, int idx) cards, {
  bool allFolded = false,
  bool allHidden = false,
  bool revealTarget = false,
  bool rule = true,
}) =>
    _mount(
      tester,
      cards: cards(_nFor(l), _idxFor(l)),
      allFolded: allFolded,
      allHidden: allHidden,
      revealed: revealTarget ? {_idxFor(l) + 1} : const {},
      simple: l == _L.listView,
      target: _targetFor(l),
      rule: rule,
    );

/// FOLD: [q]줄 질문의 첫/마지막 줄을 눌러 접는다 (위쪽 y=[top]).
Future<_Tap> _foldCase(WidgetTester tester, _L l, int q, String line, double top,
    {bool rule = true, bool check = true}) async {
  final idx = _idxFor(l);
  final fx = await _setup(tester, l,
      (n, idx) => [for (var i = 0; i < n; i++) i == idx ? _mk(i, q: _lines('Q$i', q)) : _mk(i)],
      rule: rule);
  await fx.bring(idx, top);
  final qr = fx.inCard(idx, find.textContaining('Q$idx L0'));
  final lh = qr.height / q;
  final finger = line == 'first' ? qr.top + lh / 2 : qr.top + (q - 0.5) * lh;
  expect(finger, inInclusiveRange(2, fx.vpH - 2), reason: '눌 줄이 화면에 보여야 한다 ($finger)');
  final name = 'FOLD ${l.name} q=$q $line top=$top';
  return check ? _tapAndCheck(tester, fx, idx, finger, name) : _tap(tester, fx, idx, finger);
}

/// HIDE: [a]줄 답의 위/가운데/아래를 눌러 숨긴다 (위쪽 y=[top]).
Future<_Tap> _hideCase(WidgetTester tester, _L l, int a, String at, double top,
    {bool rule = true, bool check = true}) async {
  final idx = _idxFor(l);
  final fx = await _setup(tester, l,
      (n, idx) => [for (var i = 0; i < n; i++) i == idx ? _mk(i, a: _lines('A$i', a)) : _mk(i)],
      allHidden: true, revealTarget: true, rule: rule);
  await fx.bring(idx, top);
  final ar = fx.inCard(idx, find.textContaining('A$idx L0'));
  final vt = ar.top < 0 ? 0.0 : ar.top;
  final vb = ar.bottom > fx.vpH ? fx.vpH : ar.bottom;
  expect(vb - vt, greaterThan(6), reason: '눌 답 본문이 화면에 보여야 한다 ($vt..$vb)');
  final finger = at == 'top' ? vt + 3 : at == 'mid' ? (vt + vb) / 2 : vb - 3;
  final name = 'HIDE ${l.name} a=$a $at top=$top';
  return check ? _tapAndCheck(tester, fx, idx, finger, name) : _tap(tester, fx, idx, finger);
}

/// NEAREND: 소량 목록(15칸) 끝 근처 카드의 긴 답(a줄)을 숨긴다. 숨기기 전엔 마지막 카드가 레이아웃 밖이라
/// maxScrollExtent가 추정치다 — 점프가 레이아웃 전이라 범위가 틀리면 첫 프레임이 끝 아래 빈 공간으로 그려진다.
Future<_Tap> _nearEndCase(WidgetTester tester, int a, int fromEnd, double top,
    {bool clampOnResize = true, bool check = true}) async {
  const n = 15;
  final idx = n - fromEnd;
  final fx = await _mount(tester,
      cards: [for (var i = 0; i < n; i++) i == idx ? _mk(i, a: _lines('A$i', a)) : _mk(i)],
      allHidden: true, revealed: {idx + 1}, simple: true, clampOnResize: clampOnResize);
  await fx.bring(idx, top, strict: false);
  final ar = fx.inCard(idx, find.textContaining('A$idx L0'));
  final vt = ar.top < 0 ? 0.0 : ar.top;
  final vb = ar.bottom > fx.vpH ? fx.vpH : ar.bottom;
  expect(vb - vt, greaterThan(6), reason: '눌 답 본문이 화면에 보여야 한다 ($vt..$vb)');
  final finger = (vt + vb) / 2;
  final name = 'NEAREND a=$a fromEnd=$fromEnd top=$top';
  return check ? _tapAndCheck(tester, fx, idx, finger, name) : _tap(tester, fx, idx, finger);
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
        '답 숨기기(줄어듦): 위로 150dp 잘리고 아래쪽이 화면 안인 카드가 손가락 밑에 남는다 — 위쪽을 내려서 (${aboveTarget ? "target 위쪽 칸" : "target 이상 칸"})',
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
      expect(before.bottom, lessThan(fx.vpH - 100));
      final a = fx.answerText(idx);
      final fingerY = a.bottom - 6; // 보이는 답 본문의 맨 아래쪽
      expect(fingerY, greaterThan(0));
      expect(fx.under(fingerY), idx);
      final epoch = fx.host.spl.epoch;

      final r = await _tapAndCheck(tester, fx, idx, fingerY, 'HIDE cut 22-line answer aboveTarget=$aboveTarget');

      expect(fx.host.revealed, isNot(contains(idx + 1)), reason: '답이 가려졌다');
      expect(r.after!.height, lessThan(before.height - 100), reason: '줄어들었다');
      expect(r.after!.top, greaterThan(before.top + 1), reason: '새 규칙: 위쪽을 내려서 손가락 밑에 남긴다 (위쪽 고정이면 카드가 사라진다)');
      expect(r.after!.contains(Offset(150, fingerY)), isTrue, reason: '손가락 밑에 그 카드가 남는다');
      expect(fx.under(fingerY), idx);
      expect(fx.host.spl.epoch, greaterThan(epoch),
          reason: aboveTarget ? 'target 위쪽 칸은 위쪽이 움직이므로 새 위치로 다시 마운트' : '위쪽을 내려야 하므로 새 위치로 다시 마운트');
      expect(fx.host.log.last, contains('remount=true'));
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
        expect(fx.host.log.last, contains('remount=false'));
        expect(fx.host.revealed, contains(idx + 1), reason: '탭 자체는 처리됐다');
        expect(fx.host.spl.epoch, epoch, reason: '높이가 안 바뀌는 탭은 목록을 다시 마운트하지 않는다');
        final after = fx.rect(idx)!;
        expect(after.top, closeTo(before.top, 0.5));
        expect(after.bottom, closeTo(before.bottom, 0.5));
        expect(fx.under(fingerY), idx);
      });
    }
  }

  // ───────────── 진짜 CardTile 매트릭스: 손가락 밑 · 첫 프레임 == 정착 · 예측 == 실제 ─────────────
  // 목록 4종: splFwd(target 이상 칸) · splAbove(target 위쪽 칸) · splTarget(target 자신) · listView(소량).
  for (final l in _L.values) {
    group('MATRIX ${l.name}', () {
      for (final top in [200.0, -5.0, -150.0]) {
        testWidgets('FOLD q=8 last line top=$top', (tester) async {
          await _foldCase(tester, l, 8, 'last', top);
        });
      }
      // (계획은 첫 줄이었지만 top=-40에서 첫 줄 중심은 y=-9.5라 화면 밖 — 마지막 줄을 누른다)
      testWidgets('FOLD q=3 last line top=-40', (tester) async {
        await _foldCase(tester, l, 3, 'last', -40);
      });
      testWidgets('FOLD q=1 top=0', (tester) async {
        await _foldCase(tester, l, 1, 'first', 0);
      });
      for (final at in ['top', 'mid', 'bottom']) {
        for (final top in [-40.0, 200.0]) {
          testWidgets('HIDE a=12 $at top=$top', (tester) async {
            await _hideCase(tester, l, 12, at, top);
          });
        }
      }
      testWidgets('HIDE a=60 mid top=0', (tester) async {
        await _hideCase(tester, l, 60, 'mid', 0);
      });
      testWidgets('HIDE a=6 bottom top=-5', (tester) async {
        await _hideCase(tester, l, 6, 'bottom', -5);
      });
      for (final a in [0, 1, 3]) {
        testWidgets('REVEAL a=$a top=0', (tester) async {
          final idx = _idxFor(l);
          final fx = await _setup(
              tester,
              l,
              (n, idx) => [
                    for (var i = 0; i < n; i++)
                      i == idx ? _mk(i, a: a == 0 ? '' : _lines('A$i', a)) : _mk(i)
                  ],
              allHidden: true);
          await fx.bring(idx, 0);
          await _tapAndCheck(tester, fx, idx, fx.revealHint(idx).center.dy, 'REVEAL ${l.name} a=$a');
        });
      }
      testWidgets('UNFOLD q=8 top=-20', (tester) async {
        final idx = _idxFor(l);
        final fx = await _setup(tester, l,
            (n, idx) => [for (var i = 0; i < n; i++) i == idx ? _mk(i, q: _lines('Q$i', 8)) : _mk(i)],
            allFolded: true);
        await fx.bring(idx, -20);
        final qr = fx.inCard(idx, find.textContaining('Q$idx L0'));
        final finger = (qr.top < 0 ? 0.0 : qr.top) / 2 + qr.bottom / 2;
        final r = await _tapAndCheck(tester, fx, idx, finger, 'UNFOLD ${l.name}');
        expect(r.pred, isNull, reason: '펴기는 예측하지 않는다(항상 커진다)');
        expect(r.after!.height, greaterThan(r.before.height));
      });
    });
  }

  // ───────────── 목록 끝(물리적 한계): 빈 공간 없이 가장자리에 붙는다 ─────────────
  for (final simple in [false, true]) {
    testWidgets('END 맨 첫 카드: 12줄 답을 아래쪽에서 눌러 숨긴다 simple=$simple', (tester) async {
      final n = simple ? 25 : 80;
      final fx = await _mount(tester,
          cards: [for (var i = 0; i < n; i++) i == 0 ? _mk(i, a: _lines('A0', 12)) : _mk(i)],
          allHidden: true, revealed: {1}, simple: simple);
      final ar = fx.inCard(0, find.textContaining('A0 L0'));
      await _tapAndCheck(tester, fx, 0, ar.bottom - 3, 'END first simple=$simple');
      expect(fx.rect(0)!.top, closeTo(0, 0.5), reason: '맨 첫 카드는 목록 맨 위에 붙는다');
    });
    for (final which in ['last', 'second-last']) {
      testWidgets('END $which 카드: 목록 끝에서 12줄 답 숨기기 simple=$simple', (tester) async {
        final n = simple ? 25 : 80;
        final idx = which == 'last' ? n - 1 : n - 2;
        final fx = await _mount(tester,
            cards: [for (var i = 0; i < n; i++) i == idx ? _mk(i, a: _lines('A$i', 12)) : _mk(i)],
            allHidden: true, revealed: {idx + 1}, simple: simple);
        for (var k = 0; k < 80 && fx.rect(n - 1) == null; k++) {
          fx.pos.jumpTo(fx.pos.pixels + 600);
          await tester.pumpAndSettle();
        }
        fx.pos.jumpTo(fx.pos.maxScrollExtent);
        await tester.pumpAndSettle();
        for (final at in ['top', 'bottom']) {
          if (at == 'bottom') {
            await _tapAndCheck(tester, fx, idx, fx.revealHint(idx).center.dy, 'END $which re-reveal simple=$simple');
            fx.pos.jumpTo(fx.pos.maxScrollExtent);
            await tester.pumpAndSettle();
          }
          final a2 = fx.inCard(idx, find.textContaining('A$idx L0'));
          final y = at == 'top' ? (a2.top < 0 ? 3.0 : a2.top + 3) : a2.bottom - 3;
          await _tapAndCheck(tester, fx, idx, y, 'END $which $at simple=$simple');
          expect(fx.rect(n - 1)!.bottom, closeTo(fx.vpH, 0.5), reason: '마지막 카드 아래에 빈 공간이 없다');
        }
      });
    }
  }

  // ───────────── NEAREND: 마지막 카드가 아직 레이아웃되지 않은 소량 목록 끝 근처 (스프링 미끄러짐 회귀) ─────────────
  // 숨기기는 레이아웃 전에 position.jumpTo로 목록을 옮긴다. 마지막 카드가 레이아웃 전이면 maxScrollExtent가
  // 추정치라 위치가 범위 밖이 될 수 있고, 픽셀을 일부러 바꿨으니 기본 물리(RangeMaintaining)도 범위를 안 지킨다.
  // → 첫 프레임에 끝 아래 빈 공간이 보였다가 스프링으로 미끄러진다. ClampOnResizeScrollPhysics가 같은 레이아웃에서 자른다.
  for (final a in [35, 45, 60]) {
    for (final fromEnd in [2, 3]) {
      for (final top in [-100.0, 50.0, 150.0]) {
        testWidgets('NEAREND a=$a 끝에서 $fromEnd번째 top=$top: 첫 프레임 == 정착, 끝 아래 빈 공간 없음, 손가락 밑', (tester) async {
          await _nearEndCase(tester, a, fromEnd, top);
        });
      }
    }
  }

  testWidgets('NEAREND 전제: 45줄 답, 끝에서 2번째, top=50 — 숨기기 전에 마지막 카드가 레이아웃 밖이고 숨긴 뒤 안으로 들어온다', (tester) async {
    final r = await _nearEndCase(tester, 45, 2, 50);
    expect(r.lastLaidBefore, isFalse, reason: '이 시나리오의 전제: 탭 전엔 마지막 카드가 레이아웃되지 않았다 (maxScrollExtent가 추정치)');
    expect(r.after!.height, lessThan(r.before.height - 500), reason: '크게 줄어들었다');
  });

  // 내용이 뷰포트보다 짧은 목록: 마지막 카드 아래 빈 공간은 정상이므로 BLANK 검사를 건너뛴다 (가드가 실제로 쓰이는 사례).
  testWidgets('SHORT 뷰포트보다 짧은 목록(카드 2장): 질문 접기 — 끝 아래 빈 공간 검사를 건너뛰고 나머지 규칙은 그대로', (tester) async {
    final fx = await _mount(tester,
        cards: [for (var i = 0; i < 2; i++) i == 1 ? _mk(i, q: _lines('Q$i', 8)) : _mk(i)], simple: true);
    expect(fx.pos.maxScrollExtent, 0, reason: '전제: 내용이 뷰포트보다 짧아 스크롤 범위가 0');
    final qr = fx.inCard(1, find.textContaining('Q1 L7'));
    final r = await _tapAndCheck(tester, fx, 1, qr.center.dy, 'SHORT fold q=8');
    expect(r.settledMax, 0, reason: '접은 뒤에도 짧은 목록');
    expect(r.settledBlank, greaterThan(0.5), reason: '마지막 카드 아래가 비는 게 정상 — 가드가 없으면 BLANK로 실패하는 사례');
  });

  // 음성 대조: 평범한 ClampingScrollPhysics(옛 동작)면 같은 시나리오가 범위 밖 첫 프레임 + 미끄러짐으로 실제로 깨진다.
  testWidgets('NC-D 평범한 ClampingScrollPhysics면 NEAREND a=45 끝에서 2번째 top=50: 첫 프레임이 범위 밖(빈 공간)이고 정착과 다르다', (tester) async {
    final r = await _nearEndCase(tester, 45, 2, 50, clampOnResize: false, check: false);
    expect(r.lastLaidBefore, isFalse);
    expect(r.firstOver, greaterThan(50), reason: '첫 프레임 위치가 스크롤 범위 밖 (seen over=${r.firstOver})');
    expect(r.firstBlank, greaterThan(50), reason: '마지막 카드 아래 빈 공간이 보인다 (seen blank=${r.firstBlank})');
    expect((r.first!.top - r.after!.top).abs(), greaterThan(50), reason: '정착까지 미끄러진다 (first=${_fmt(r.first)} settled=${_fmt(r.after)})');
  });

  // 끌고 있는 중(isScrolling)에는 기존 동작 그대로 — 물리가 드래그를 방해하지 않는다.
  // 같은 스크립트(양방향 관성 + 양 끝 오버스크롤 드래그)를 ClampOnResizeScrollPhysics와 ClampingScrollPhysics로 각각 돌려
  // 프레임마다 픽셀과 OverscrollNotification 개수/합이 같은지 본다. (정지 중 크기 변경만 다르다 — 위 NEAREND/NC-D)
  testWidgets('ClampOnResizeScrollPhysics: 평소 스크롤(드래그·관성·양 끝 오버스크롤)은 ClampingScrollPhysics와 프레임마다 같다', (tester) async {
    Future<({List<String> trace, int os, double osSum, bool isClampOnResize})> run(bool clampOnResize) async {
      final fx = await _mount(tester, cards: _cards(25), simple: true, clampOnResize: clampOnResize);
      final pos = fx.pos;
      final trace = <String>[];
      void frame(String label) =>
          trace.add('$label:${pos.pixels.toStringAsFixed(2)}/${pos.maxScrollExtent.toStringAsFixed(2)}');
      Future<void> frames(String label, int count) async {
        for (var i = 0; i < count; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          frame('$label$i');
        }
      }

      final list = find.byType(ListView);
      frame('mount');
      // 양방향 관성 (느림/빠름)
      for (final v in [2500.0, 9000.0]) {
        await tester.fling(list, const Offset(0, -300), v);
        frame('fd$v');
        await frames('fd$v-', 150);
        await tester.fling(list, const Offset(0, 300), v);
        frame('fu$v');
        await frames('fu$v-', 150);
      }
      // 끝에서 위로 더 끌기 (아래쪽 끝 오버스크롤)
      pos.jumpTo(pos.maxScrollExtent);
      await tester.pumpAndSettle();
      frame('end');
      final g = await tester.startGesture(tester.getCenter(list));
      for (var i = 0; i < 20; i++) {
        await g.moveBy(const Offset(0, -25));
        await tester.pump(const Duration(milliseconds: 16));
        frame('oe$i');
      }
      await g.up();
      await frames('oeR', 40);
      // 처음에서 아래로 더 끌기 (위쪽 끝 오버스크롤)
      pos.jumpTo(0);
      await tester.pumpAndSettle();
      frame('start');
      final g2 = await tester.startGesture(tester.getCenter(list));
      for (var i = 0; i < 20; i++) {
        await g2.moveBy(const Offset(0, 25));
        await tester.pump(const Duration(milliseconds: 16));
        frame('ot$i');
      }
      await g2.up();
      await frames('otR', 40);
      final r = (
        trace: trace,
        os: fx.host.overscrolls,
        osSum: fx.host.overscrollSum,
        isClampOnResize: pos.physics is ClampOnResizeScrollPhysics,
      );
      await tester.pumpWidget(const SizedBox());
      return r;
    }

    final a = await run(true);
    final b = await run(false);
    expect(a.isClampOnResize, isTrue, reason: '화면이 쓰는 물리로 돌았다');
    expect(b.isClampOnResize, isFalse, reason: '대조군은 평범한 ClampingScrollPhysics');
    expect(a.trace, b.trace, reason: '프레임마다 pixels/max가 같다');
    expect(a.os, b.os, reason: 'OverscrollNotification 개수가 같다');
    expect(a.osSum, closeTo(b.osSum, 1e-9), reason: 'OverscrollNotification 합이 같다');
    // 빈손으로 통과하지 않게: 관성이 실제로 움직였고 양 끝 오버스크롤 알림이 실제로 났다
    expect(a.trace.length, greaterThan(600));
    expect(a.trace.map((t) => t.split(':').last.split('/').first).toSet().length, greaterThan(100), reason: '픽셀이 실제로 많이 움직였다');
    expect(a.os, greaterThan(10), reason: '양 끝 오버스크롤 알림이 났다');
    expect(a.osSum, isNot(0));
  });

  // 정지 중(isScrolling 아님) 크기 변경은 새 범위로 자른다.
  test('ClampOnResizeScrollPhysics: 멈춰 있을 때 범위가 줄면 새 범위로 자른다', () {
    const physics = ClampOnResizeScrollPhysics();
    final m = FixedScrollMetrics(
        minScrollExtent: 0, maxScrollExtent: 1000, pixels: 1200, viewportDimension: 800, axisDirection: AxisDirection.down, devicePixelRatio: 1);
    expect(
        physics.adjustPositionForNewDimensions(oldPosition: m, newPosition: m, isScrolling: false, velocity: 0),
        1000, reason: '멈춰 있으면 새 범위로 자른다');
  });

  // ───────────── 이미지(디코딩 실패 뒤 80dp 오류 상자) ─────────────
  for (final simple in [false, true]) {
    for (final at in ['img1', 'img2', 'bottom']) {
      testWidgets('IMG 이미지 2장 답 숨기기, $at 누름 simple=$simple', (tester) async {
        final n = simple ? 25 : 80;
        const idx = 10;
        final fx = await _mount(tester,
            cards: [
              for (var i = 0; i < n; i++)
                i == idx
                    ? _mk(i,
                        a: _lines('A$i', 3),
                        aImages: ['/nonexistent/h$at$simple-a.png', '/nonexistent/h$at$simple-b.png'])
                    : _mk(i)
            ],
            allHidden: true, revealed: {idx + 1}, simple: simple);
        await fx.bring(idx, 40);
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
        await tester.pumpAndSettle();
        await fx.bring(idx, 40);
        final imgs = find.descendant(of: fx.card(idx), matching: find.byIcon(Icons.broken_image));
        expect(imgs, findsNWidgets(2), reason: 'errorBuilder 상자가 배치됐다');
        final r1 = tester.getRect(imgs.at(0)).shift(Offset(0, -fx.vpTop));
        final r2 = tester.getRect(imgs.at(1)).shift(Offset(0, -fx.vpTop));
        final y = at == 'img1' ? r1.center.dy : at == 'img2' ? r2.center.dy : r2.bottom - 3;
        await _tapAndCheck(tester, fx, idx, y, 'IMG hide $at simple=$simple');
      });
    }
    testWidgets('IMG 이미지 2장 답 보이기(디코딩 전): 위쪽 가장자리 그대로 simple=$simple', (tester) async {
      final n = simple ? 25 : 80;
      const idx = 10;
      final fx = await _mount(tester,
          cards: [
            for (var i = 0; i < n; i++)
              i == idx
                  ? _mk(i, a: '', aImages: ['/nonexistent/r$simple-a.png', '/nonexistent/r$simple-b.png'])
                  : _mk(i)
          ],
          allHidden: true, simple: simple);
      await fx.bring(idx, 100);
      final finger = fx.revealHint(idx).center.dy;
      final before = fx.rect(idx)!;
      await tester.tapAt(Offset(150, fx.vpTop + finger));
      await tester.pump();
      final first = fx.rect(idx)!;
      expect(fx.host.predicted, isNull, reason: '이미지가 있는 보이기는 예측하지 않는다(커지는 탭으로 본다)');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      final after = fx.rect(idx)!;
      expect(first.top, closeTo(before.top, 0.5), reason: '이미지가 있는 보이기는 위쪽 가장자리 그대로');
      expect(after.top, closeTo(before.top, 0.5));
      expect(fx.under(finger), idx);
    });
  }

  // ───────────── RH: 보이기 → 숨기기를 같은 자리에서 — 위쪽이 그대로여야 한다 ─────────────
  for (final simple in [false, true]) {
    for (final cut in [5.0, 40.0]) {
      for (final a in [1, 6]) {
        testWidgets('RH 보이기 뒤 같은 자리에서 숨기기 cut=$cut a=$a simple=$simple', (tester) async {
          final n = simple ? 25 : 80;
          const idx = 10;
          final fx = await _mount(tester,
              cards: [for (var i = 0; i < n; i++) i == idx ? _mk(i, a: _lines('A$i', a)) : _mk(i)],
              allHidden: true, simple: simple);
          await fx.bring(idx, -cut);
          final y = fx.revealHint(idx).center.dy;
          final top0 = fx.rect(idx)!.top;
          await _tapAndCheck(tester, fx, idx, y, 'RH reveal cut=$cut a=$a simple=$simple');
          await _tapAndCheck(tester, fx, idx, y, 'RH hide cut=$cut a=$a simple=$simple');
          expect(fx.rect(idx)!.top, closeTo(top0, 0.5), reason: '보이기 뒤 숨겨도 위쪽 가장자리가 그대로 (손가락은 여전히 그 카드)');
        });
      }
    }
  }

  // ───────────── 손가락 없는 탭(접근성): 보이는 맨 위를 손가락으로 본다 ─────────────
  for (final simple in [false, true]) {
    testWidgets('A11Y 포인터 없이 크게 잘린 카드를 접으면 카드가 화면에 남고 첫 프레임이 최종이다 simple=$simple', (tester) async {
      final n = simple ? 25 : 80;
      const idx = 10;
      final fx = await _mount(tester,
          cards: [for (var i = 0; i < n; i++) i == idx ? _mk(i, q: _lines('Q$i', 8)) : _mk(i)],
          simple: simple);
      await fx.bring(idx, -200);
      final tile = tester.widget<CardTile>(find.descendant(of: fx.card(idx), matching: find.byType(CardTile)));
      expect(fx.host.release, isNull, reason: '포인터가 없으니 손가락 위치도 없다');
      tile.onQuestionTap!();
      await tester.pump();
      final first = fx.rect(idx);
      await tester.pumpAndSettle();
      final after = fx.rect(idx);
      expect(tester.takeException(), isNull);
      expect(after, isNotNull);
      expect(after!.bottom, greaterThanOrEqualTo(kFingerInsetOnCard - 0.5), reason: '접힌 카드가 화면에 보인다');
      expect(first!.top, closeTo(after.top, 0.5), reason: '첫 프레임 == 정착');
    });
  }

  // ───────────── 손가락이 이 카드 밖이면 믿지 않는다 (옛 값·다른 곳 뗌) ─────────────
  for (final simple in [false, true]) {
    testWidgets('손가락 위치가 누른 카드 밖이면 무시하고 위쪽 그대로 둔다 simple=$simple', (tester) async {
      final n = simple ? 25 : 80;
      const idx = 10;
      final fx = await _mount(tester,
          cards: [for (var i = 0; i < n; i++) i == idx ? _mk(i, q: _lines('Q$i', 8)) : _mk(i)],
          simple: simple);
      await fx.bring(idx, 150);
      final before = fx.rect(idx)!;
      final tile = tester.widget<CardTile>(find.descendant(of: fx.card(idx), matching: find.byType(CardTile)));
      // 손가락이 카드 아래쪽 밖에 있다고 꾸민다 (포인터 없이 같은 동작 안에서 탭 콜백만 부른다).
      fx.host.release = Offset(150, fx.vpTop + before.bottom + 60);
      tile.onQuestionTap!();
      await tester.pump();
      final first = fx.rect(idx)!;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(first.top, closeTo(before.top, 0.5), reason: '카드 밖 손가락은 믿지 않아 보이는 맨 위 기준으로 위쪽이 그대로다');
      expect(fx.rect(idx)!.top, closeTo(before.top, 0.5));
    });
  }

  testWidgets('손가락 위치는 포인터 이벤트 처리 직후 마이크로태스크에서 지워진다 (드래그 뒤 옛 값이 남지 않는다)', (tester) async {
    final fx = await _mount(tester, cards: _cards(80));
    expect(fx.host.releases, 0);
    await tester.dragFrom(Offset(150, fx.vpTop + 300), const Offset(0, -100));
    expect(fx.host.releases, 1, reason: '드래그도 손가락 뗌으로 기록된다');
    await tester.pump();
    expect(fx.host.release, isNull);
  });

  testWidgets('NOHIDE 숨김 모드가 아닐 때 target 위쪽 칸의 답 탭은 다시 마운트하지 않는다', (tester) async {
    final fx = await _mount(tester, cards: [for (var i = 0; i < 80; i++) _mk(i)], target: 40);
    await fx.bring(37, 100);
    final e0 = fx.host.spl.epoch;
    final before = fx.rect(37)!;
    final ar = fx.inCard(37, find.textContaining('answer text line'));
    await tester.tapAt(Offset(150, fx.vpTop + ar.center.dy));
    await tester.pumpAndSettle();
    expect(fx.host.spl.epoch, e0);
    expect(fx.rect(37)!.top, closeTo(before.top, 0.5));
  });

  // ───────────── RACE: 새 검색 결과·점프가 setState만 해 두고 아직 안 그려진 사이의 탭 ─────────────
  for (final simple in [false, true]) {
    testWidgets('RACE 새 목록 + 맨 위 점프 직후 프레임 전에 탭해도 새 목록이 맨 위에서 열린다 simple=$simple', (tester) async {
      final n = simple ? 25 : 80;
      const idx = 10;
      final fx = await _mount(tester,
          cards: [for (var i = 0; i < n; i++) i == idx ? _mk(i, a: _lines('A$i', 12)) : _mk(i)],
          allHidden: true, revealed: {idx + 1}, simple: simple);
      await fx.bring(idx, -40);
      final y = fx.inCard(idx, find.textContaining('A$idx L0')).bottom - 3;
      final e0 = fx.host.spl.epoch;
      final fresh = [for (var i = 0; i < n; i++) _mk(i + 500)];
      fx.host.rebuild(() => fx.host.cards = fresh);
      if (simple) {
        jumpToStartIfLaidOut(fx.host.sc);
      } else {
        fx.host.spl.jumpTo(0, setState: fx.host.rebuild);
      }
      await tester.tapAt(Offset(150, fx.vpTop + y));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final r0 = fx.rect(0);
      expect(r0, isNotNull);
      expect(r0!.top, closeTo(0, 0.5), reason: '새 결과는 맨 위에서 열린다 (낡은 렌더 트리로 붙잡지 않는다)');
      if (!simple) expect(fx.host.spl.epoch - e0, 1, reason: '맨 위 점프 하나뿐');
    });
  }

  // ───────────── 음성 대조 (이 테스트들이 실제로 잡는 것을 못박는다) ─────────────

  // NC-A: 붙잡지 않으면(rule: false) 매트릭스의 각 시나리오가 실제로 어긋난다 — 손가락 밑이 다른 카드가 되거나 카드가 사라진다.
  testWidgets('NC-A 붙잡지 않으면 FOLD listView q=8 last top=200: 손가락 밑이 다른 카드', (tester) async {
    final r = await _foldCase(tester, _L.listView, 8, 'last', 200, rule: false, check: false);
    expect(r.underBefore, 10);
    expect(r.underAfter, isNot(10));
    expect(r.underAfter, isNotNull);
  });
  testWidgets('NC-A 붙잡지 않으면 FOLD splAbove q=8 last top=200: 손가락 밑이 다른 카드', (tester) async {
    final r = await _foldCase(tester, _L.splAbove, 8, 'last', 200, rule: false, check: false);
    expect(r.underBefore, 37);
    expect(r.underAfter, isNot(37));
    expect(r.underAfter, isNotNull);
  });
  testWidgets('NC-A 붙잡지 않으면 HIDE splFwd a=12 top top=-150: 카드가 화면 밖으로 사라진다', (tester) async {
    final r = await _hideCase(tester, _L.splFwd, 12, 'top', -150, rule: false, check: false);
    expect(r.underBefore, 10);
    expect(r.after == null || r.after!.bottom <= 0, isTrue, reason: '위쪽이 화면 밖에 고정된 채 줄어들어 사라진다: ${_fmt(r.after)}');
  });

  // NC-B: 다시 빌드 대기 중 가드를 끄면(hostContext: itemContext) 낡은 렌더 트리로 붙잡아 새 목록이 맨 위에서 안 열린다.
  testWidgets('NC-B 가드를 끄면 새 목록이 맨 위에서 열리지 않는다 (RACE 대조)', (tester) async {
    const n = 80, idx = 10;
    final fx = await _mount(tester,
        cards: [for (var i = 0; i < n; i++) i == idx ? _mk(i, a: _lines('A$i', 12)) : _mk(i)],
        allHidden: true, revealed: {idx + 1}, guard: false);
    await fx.bring(idx, -40);
    final y = fx.inCard(idx, find.textContaining('A$idx L0')).bottom - 3;
    final fresh = [for (var i = 0; i < n; i++) _mk(i + 500)];
    fx.host.rebuild(() => fx.host.cards = fresh);
    fx.host.spl.jumpTo(0, setState: fx.host.rebuild);
    await tester.tapAt(Offset(150, fx.vpTop + y));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final r0 = fx.rect(0);
    expect(r0 == null || r0.top.abs() > 0.5, isTrue, reason: '가드 없이는 새 목록이 맨 위에서 안 열린다 (seen ${_fmt(r0)})');
  });

  // NC-C: 한 프레임 늦은 보정(addPostFrameCallback)은 첫 프레임 != 정착 — 첫 프레임 검사가 번쩍임을 잡는다.
  testWidgets('NC-C 늦은 보정은 첫 프레임이 다르다 (첫 프레임 == 정착 검사의 대조)', (tester) async {
    final sc = ScrollController();
    final heights = [for (var i = 0; i < 25; i++) i == 10 ? 600.0 : 150.0];
    final folded = <int>{};
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(builder: (context, s) {
          return ListView.builder(
            controller: sc,
            itemCount: heights.length,
            itemBuilder: (c, i) => GestureDetector(
              key: ValueKey('c$i'),
              behavior: HitTestBehavior.opaque,
              onTap: () {
                // 늦게: 접기를 적용한 프레임 뒤에 스크롤 보정이 돈다
                WidgetsBinding.instance.addPostFrameCallback((_) => sc.position.jumpTo(sc.position.pixels - 300));
                s(() => folded.add(i));
              },
              child: SizedBox(height: folded.contains(i) ? 100 : heights[i]),
            ),
          );
        }),
      ),
    ));
    sc.jumpTo(1500 - 100); // 카드 10의 위쪽이 100
    await tester.pumpAndSettle();
    final top0 = tester.getTopLeft(find.byKey(const ValueKey('c10'))).dy;
    await tester.tapAt(Offset(100, top0 + 450));
    await tester.pump();
    final first = tester.getTopLeft(find.byKey(const ValueKey('c10'))).dy;
    await tester.pumpAndSettle();
    final settled = tester.getTopLeft(find.byKey(const ValueKey('c10'))).dy;
    expect((first - settled).abs(), greaterThan(100), reason: '늦은 보정은 별도 프레임으로 보인다 (first=$first settled=$settled)');
  });
}
