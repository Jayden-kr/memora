import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memora/l10n/app_localizations.dart';
import 'package:memora/models/card.dart';
import 'package:memora/widgets/card_tile.dart';

/// predictCardTileHeightAfterTap의 계약 — 접기/보이기 직전에 예측한 "바뀐 뒤 높이"가 실제로 다시 배치된
/// 높이와 같아야 한다. 목록(card_list_screen의 keepTappedCardUnderFinger)이 이 값으로 누른 카드를 손가락
/// 밑에 남기므로, 텍스트 배율·언어·화면 폭·검색 강조·카드 번호·이미지가 바뀌어도 어긋나면 안 된다.
///
/// 진짜 CardTile을 일반 ListView에 올린다(sqlite·화면 State는 쓰지 않는다). 각 콜백은 높이를 바꾸는
/// setState 직전에 예측을 불러 기록하고, 탭 뒤 pumpAndSettle로 실제 높이와 비교한다.
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
    this.query,
    this.numbers = false,
  });
  final List<CardModel> cards;
  final bool allFolded;
  final bool allHidden;
  final Set<int> revealed;
  final String? query;
  final bool numbers;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  final sc = ScrollController();
  final toggled = <int>{};
  late final Set<int> revealed = {...widget.revealed};
  bool called = false;
  double? predicted;

  bool folded(CardModel c) =>
      widget.allFolded ? !toggled.contains(c.id) : toggled.contains(c.id);

  Widget item(BuildContext context, int index) {
    final card = widget.cards[index];
    return Builder(
      builder: (itemContext) => KeyedSubtree(
        key: ValueKey('card${card.id}'),
        child: CardTile(
          card: card,
          isFolded: folded(card),
          isHidden: widget.allHidden,
          isRevealed: widget.allHidden ? revealed.contains(card.id) : true,
          searchQuery: widget.query,
          cardNumber: widget.numbers ? index + 1 : null,
          onQuestionTap: () {
            called = true;
            predicted = predictCardTileHeightAfterTap(itemContext, CardTileTap.question);
            setState(() {
              if (!toggled.remove(card.id)) toggled.add(card.id!);
            });
          },
          onAnswerTap: () {
            called = true;
            predicted = predictCardTileHeightAfterTap(itemContext, CardTileTap.answer);
            setState(() {
              if (!revealed.remove(card.id)) revealed.add(card.id!);
            });
          },
          onTap: () {},
          onLongPress: () {},
          onMenuAction: (_) {},
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: ListView.builder(
          controller: sc,
          itemCount: widget.cards.length,
          itemBuilder: item,
          physics: const ClampingScrollPhysics(),
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
  int get n => host.widget.cards.length;
  ScrollPosition get pos => host.sc.position;
  Finder card(int i) => find.byKey(ValueKey('card${host.widget.cards[i].id}'));

  Rect? rect(int i) {
    final f = card(i);
    if (f.evaluate().isEmpty) return null;
    return tester.getRect(f).shift(Offset(0, -vpTop));
  }

  Rect? inCard(int i, Finder m) {
    final f = find.descendant(of: card(i), matching: m);
    if (f.evaluate().isEmpty) return null;
    return tester.getRect(f.first).shift(Offset(0, -vpTop));
  }

  /// [i]번 카드를 위쪽 가장자리가 뷰포트 [top]에 오게 한다.
  Future<void> bring(int i, double top) async {
    for (var k = 0; k < 80 && rect(i) == null; k++) {
      var first = -1;
      for (var j = 0; j < n; j++) {
        if (rect(j) != null) {
          first = j;
          break;
        }
      }
      pos.jumpTo(pos.pixels + (i < first ? -500 : 500));
      await tester.pumpAndSettle();
    }
    expect(rect(i), isNotNull);
    pos.jumpTo(pos.pixels + (rect(i)!.top - top));
    await tester.pumpAndSettle();
  }

  /// 뷰포트 y [finger]를 누르고 (탭 직전 높이, 예측, 탭 뒤 높이)를 돌려준다.
  Future<({double before, double? predicted, double after})> tap(int i, double finger) async {
    final before = rect(i)!.height;
    host.called = false;
    host.predicted = null;
    await tester.tapAt(Offset(150, vpTop + finger));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(host.called, isTrue, reason: 'the tap reached the tile callback (finger=$finger)');
    return (before: before, predicted: host.predicted, after: rect(i)!.height);
  }
}

Future<_Fx> _mount(
  WidgetTester tester, {
  required List<CardModel> cards,
  bool allFolded = false,
  bool allHidden = false,
  Set<int> revealed = const {},
  Locale locale = const Locale('ko'),
  double textScale = 1.0,
  Size size = const Size(1080, 2400),
  String? query,
  bool numbers = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  final key = GlobalKey<_HostState>();
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(colorSchemeSeed: const Color(0xFFFF6B6B), useMaterial3: true),
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: _Host(
      key: key,
      cards: cards,
      allFolded: allFolded,
      allHidden: allHidden,
      revealed: revealed,
      query: query,
      numbers: numbers,
    ),
  ));
  await tester.pumpAndSettle();
  final lf = find.byType(ListView);
  return _Fx(tester, key, tester.getTopLeft(lf).dy, tester.getSize(lf).height);
}

/// 질문 RichText(접기 대상) / 답 RichText 또는 빈 답이면 구분선(숨기기 대상) / 안내 문구(보이기 대상).
Finder _questionText(CardModel c) =>
    find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == c.question);
Finder _answerText(CardModel c) => c.answer.isEmpty
    ? find.byType(Divider)
    : find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == c.answer);
Finder _hintText() =>
    find.byWidgetPredicate((w) => w is Text && w.style?.fontStyle == FontStyle.italic);

/// 보이는 부분의 한가운데(뷰포트 y).
double _mid(Rect r, double vpH) =>
    (r.top < 0 ? 0.0 : r.top) / 2 + (r.bottom > vpH ? vpH : r.bottom) / 2;

void main() {
  // 5가지 모양 + 긴 히브리어 문장(오른쪽에서 왼쪽 글자·다른 줄 높이).
  List<CardModel> sweepCards() => [
        for (var i = 0; i < 25; i++)
          switch (i % 6) {
            0 => _mk(i, q: '긴 질문 문장이 화면 폭을 넘어 여러 줄로 감기는 경우 $i Lorem ipsum dolor sit amet', a: '짧은 답 L'),
            1 => _mk(i, q: _lines('Q$i', 3), a: ''),
            2 => _mk(i, q: 'Supercalifragilisticexpialidociousword$i', a: _lines('A$i', 7)),
            3 => _mk(i, q: 'Q$i', a: List.filled(30, '답변 answer text L').join(' ')),
            4 => _mk(i, q: _lines('Q$i', 2), a: 'A L'),
            _ => _mk(
                i,
                q: 'זהו משפט עברי ארוך מאוד שנועד להתעטף על פני כמה שורות במסך צר כדי לבדוק גובה טקסט $i',
                a: 'תשובה ארוכה L זהו משפט עברי ארוך מאוד שנועד להתעטף על פני כמה שורות במסך צר כדי לבדוק $i',
              ),
          }
      ];

  // 24 설정 x (숨기기 / 보이기 / 접기) 세 번 마운트 x 카드 6장(모양 6가지 모두).
  for (final scale in [1.0, 1.3, 2.0]) {
    for (final loc in ['ko', 'en']) {
      for (final w in [1080.0, 720.0]) {
        for (final query in <String?>[null, 'L']) {
          testWidgets('SWEEP scale=$scale $loc w=$w q=$query', (tester) async {
            final cards = sweepCards();
            for (final mode in ['hide', 'reveal', 'fold']) {
              final fx = await _mount(
                tester,
                cards: cards,
                allHidden: mode != 'fold',
                revealed: mode == 'hide' ? {for (final c in cards) c.id!} : const {},
                locale: Locale(loc),
                textScale: scale,
                size: Size(w, 2400),
                query: query,
              );
              for (final idx in [1, 2, 3, 4, 5, 6]) {
                await fx.bring(idx, 60);
                final c = cards[idx];
                final targetFinder = switch (mode) {
                  'fold' => _questionText(c),
                  'reveal' => _hintText(),
                  _ => _answerText(c),
                };
                var target = fx.inCard(idx, targetFinder);
                expect(target, isNotNull, reason: '$mode idx=$idx target is laid out');
                if (target!.top > fx.vpH - 60) {
                  // 큰 글자에서는 답/안내 문구가 화면 아래로 밀려 있다 — 보이는 곳까지 올린다.
                  fx.pos.jumpTo(fx.pos.pixels + target.top - 200);
                  await tester.pumpAndSettle();
                  target = fx.inCard(idx, targetFinder);
                  expect(target, isNotNull, reason: '$mode idx=$idx target is laid out after scrolling');
                }
                final r = await fx.tap(idx, _mid(target!, fx.vpH));
                final name = 'SWEEP $mode scale=$scale $loc w=$w q=$query idx=$idx';
                expect(r.predicted, isNotNull, reason: name);
                expect((r.predicted! - r.after).abs(), lessThanOrEqualTo(0.5),
                    reason: '$name predicted=${r.predicted} actual=${r.after} before=${r.before}');
              }
            }
          });
        }
      }
    }
  }

  testWidgets('NUMBER 1.0/ko/1080: card number row, 1-line question fold predicts 100', (tester) async {
    final fx = await _mount(
      tester,
      cards: [for (var i = 0; i < 25; i++) _mk(i, q: 'Q$i')],
      numbers: true,
    );
    await fx.bring(3, 60);
    final r = await fx.tap(3, _mid(fx.inCard(3, _questionText(fx.host.widget.cards[3]))!, fx.vpH));
    expect(r.predicted, closeTo(100, 0.01));
    expect(r.after, closeTo(100, 0.5));
  });

  // 이미지는 디코딩이 실패한 뒤(80dp 오류 상자)에야 높이가 정해진다 — 실제 비동기 로드를 한 번 기다린다.
  Future<void> settleImages(WidgetTester tester, _Fx fx, int idx) async {
    await fx.bring(idx, 40);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await fx.bring(idx, 40);
  }

  testWidgets('IMG fold of a card with a question image is exact', (tester) async {
    const idx = 10;
    final cards = [
      for (var i = 0; i < 25; i++)
        i == idx ? _mk(i, q: _lines('Q$i', 4), qImages: ['/nonexistent/pred_q_fold.png']) : _mk(i)
    ];
    final fx = await _mount(tester, cards: cards);
    await settleImages(tester, fx, idx);
    expect(find.descendant(of: fx.card(idx), matching: find.byIcon(Icons.broken_image)), findsOneWidget);
    final r = await fx.tap(idx, _mid(fx.inCard(idx, _questionText(cards[idx]))!, fx.vpH));
    expect(r.predicted, isNotNull);
    expect((r.predicted! - r.after).abs(), lessThanOrEqualTo(0.5),
        reason: 'predicted=${r.predicted} actual=${r.after}');
    expect(r.before - r.after, greaterThan(10), reason: 'the fold shrank the card');
  });

  testWidgets('IMG hide of an answer with 2 images is exact', (tester) async {
    const idx = 10;
    final cards = [
      for (var i = 0; i < 25; i++)
        i == idx
            ? _mk(i,
                a: _lines('A$i', 3),
                aImages: ['/nonexistent/pred_h_a.png', '/nonexistent/pred_h_b.png'])
            : _mk(i)
    ];
    final fx = await _mount(tester, cards: cards, allHidden: true, revealed: {idx + 1});
    await settleImages(tester, fx, idx);
    final imgs = find.descendant(of: fx.card(idx), matching: find.byIcon(Icons.broken_image));
    expect(imgs, findsNWidgets(2), reason: 'errorBuilder boxes are laid out');
    final y = tester.getRect(imgs.at(0)).shift(Offset(0, -fx.vpTop)).center.dy;
    final r = await fx.tap(idx, y);
    expect(r.predicted, isNotNull);
    expect((r.predicted! - r.after).abs(), lessThanOrEqualTo(0.5),
        reason: 'predicted=${r.predicted} actual=${r.after}');
    expect(r.before - r.after, greaterThan(10), reason: 'the hide shrank the card');
  });

  testWidgets('IMG reveal of an answer with images is not predicted (null = treated as growing)', (tester) async {
    const idx = 10;
    final cards = [
      for (var i = 0; i < 25; i++)
        i == idx
            ? _mk(i, a: '', aImages: ['/nonexistent/pred_r_a.png', '/nonexistent/pred_r_b.png'])
            : _mk(i)
    ];
    final fx = await _mount(tester, cards: cards, allHidden: true);
    await fx.bring(idx, 100);
    final r = await fx.tap(idx, _mid(fx.inCard(idx, _hintText())!, fx.vpH));
    expect(r.predicted, isNull);
  });

  testWidgets('NULL unfold: opening a folded card is always growing', (tester) async {
    final fx = await _mount(tester, cards: [for (var i = 0; i < 25; i++) _mk(i)], allFolded: true);
    await fx.bring(3, 60);
    final r = await fx.tap(3, _mid(fx.rect(3)!, fx.vpH));
    expect(r.predicted, isNull);
    expect(r.after, greaterThan(r.before), reason: 'the unfold grew the card');
  });

  testWidgets('NULL answer tap outside hidden mode does not change the height', (tester) async {
    final cards = [for (var i = 0; i < 25; i++) _mk(i)];
    final fx = await _mount(tester, cards: cards);
    await fx.bring(3, 60);
    final r = await fx.tap(3, _mid(fx.inCard(3, _answerText(cards[3]))!, fx.vpH));
    expect(r.predicted, isNull);
    expect(r.after, closeTo(r.before, 0.5));
  });

  testWidgets('NULL a context with no CardTile below it', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      }),
    ));
    expect(predictCardTileHeightAfterTap(ctx, CardTileTap.question), isNull);
    expect(predictCardTileHeightAfterTap(ctx, CardTileTap.answer), isNull);
  });

  // 음성 대조: 예측이 "그냥 지금 높이"나 "접힌 줄 = 마지막 줄" 같은 흉내가 아님을 못박는다.
  testWidgets('NC1 fold of a 3-line question predicts a shrink, not the current height', (tester) async {
    const idx = 3;
    final cards = [for (var i = 0; i < 25; i++) i == idx ? _mk(i, q: _lines('Q$i', 3)) : _mk(i)];
    final fx = await _mount(tester, cards: cards);
    await fx.bring(idx, 60);
    final r = await fx.tap(idx, _mid(fx.inCard(idx, _questionText(cards[idx]))!, fx.vpH));
    expect(r.predicted, isNotNull);
    expect((r.predicted! - r.before).abs(), greaterThan(10));
  });

  testWidgets('NC1 hide of a 7-line answer predicts a shrink, not the current height', (tester) async {
    const idx = 3;
    final cards = [for (var i = 0; i < 25; i++) i == idx ? _mk(i, a: _lines('A$i', 7)) : _mk(i)];
    final fx = await _mount(tester, cards: cards, allHidden: true, revealed: {idx + 1});
    await fx.bring(idx, 60);
    final r = await fx.tap(idx, _mid(fx.inCard(idx, _answerText(cards[idx]))!, fx.vpH));
    expect(r.predicted, isNotNull);
    expect((r.predicted! - r.before).abs(), greaterThan(10));
  });

  testWidgets('NC2 1-line fold at scale 1.0 predicts exactly 80 (menu button 48 + padding 24 + margin 8)', (tester) async {
    final cards = [for (var i = 0; i < 25; i++) _mk(i, q: 'Q$i')];
    final fx = await _mount(tester, cards: cards, textScale: 1.0);
    await fx.bring(3, 60);
    final r = await fx.tap(3, _mid(fx.inCard(3, _questionText(cards[3]))!, fx.vpH));
    expect(r.predicted, closeTo(80, 0.01));
  });

  testWidgets('NC2 1-line fold at scale 2.0 predicts more than 80 (the folded line follows the text scale)', (tester) async {
    final cards = [for (var i = 0; i < 25; i++) _mk(i, q: 'Q$i')];
    final fx = await _mount(tester, cards: cards, textScale: 2.0);
    await fx.bring(3, 60);
    final r = await fx.tap(3, _mid(fx.inCard(3, _questionText(cards[3]))!, fx.vpH));
    expect(r.predicted, greaterThan(80));
    expect((r.predicted! - r.after).abs(), lessThanOrEqualTo(0.5));
  });
}
