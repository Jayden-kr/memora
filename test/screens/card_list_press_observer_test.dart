import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memora/screens/card_list_screen.dart';

/// 카드 위 "누름"을 기록하는 PressObserver의 계약.
///
/// 사용자 요구: "그 단어나 주변을 누르면" 검색을 닫을 때 그 카드에 머문다 — 카드 안쪽뿐 아니라
/// 카드 바깥 여백(Card margin)·카드 사이 틈을 눌러도 기록돼야 하고, 안쪽 InkWell의 탭 처리나
/// 스크롤은 방해하지 않아야 한다. CardTile 자체는 쓰지 않고(l10n·오디오 의존) 같은 모양의
/// Card(margin 12/4) + InkWell을 자식으로 쓴다.
void main() {
  late int presses;
  late int inkTaps;

  Widget app({int count = 1}) {
    return MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            for (var i = 0; i < count; i++)
              PressObserver(
                onPress: () => presses++,
                child: Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: SizedBox(
                    height: 100,
                    child: InkWell(onTap: () => inkTaps++, child: Text('card $i')),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  setUp(() {
    presses = 0;
    inkTaps = 0;
  });

  // Card 위젯의 렌더 객체는 margin(Padding)까지 포함한다 — 여백을 뺀 카드 본체는 안쪽 Material.
  Rect cardBody(WidgetTester tester, int index) => tester.getRect(find
      .descendant(
        of: find.byType(Card).at(index),
        matching: find.byType(Material),
      )
      .first);

  testWidgets('카드 안쪽을 누르면 기록되고 안쪽 InkWell 탭도 그대로 동작한다', (tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.text('card 0'));
    await tester.pump();
    expect(presses, 1);
    expect(inkTaps, 1, reason: 'Listener가 탭을 가로채거나 제스처 아레나를 망치면 안 된다');
  });

  testWidgets('카드 바깥 여백(왼쪽·위쪽 margin)을 눌러도 기록된다', (tester) async {
    await tester.pumpWidget(app());
    final observer = tester.getRect(find.byType(PressObserver));
    final card = cardBody(tester, 0);
    // 카드와 PressObserver 사이에 margin이 실제로 있어야 이 테스트가 의미가 있다.
    expect(card.left - observer.left, 12);
    expect(card.top - observer.top, 4);

    await tester.tapAt(Offset(observer.left + 5, card.center.dy)); // 왼쪽 margin
    await tester.pump();
    expect(presses, 1);
    await tester.tapAt(Offset(card.center.dx, observer.top + 2)); // 위쪽 margin
    await tester.pump();
    expect(presses, 2);
    expect(inkTaps, 0, reason: '여백은 InkWell 밖이라 안쪽 탭은 일어나지 않는다');
  });

  testWidgets('카드 사이 틈은 맞닿은 위·아래 카드 각자의 margin으로 기록된다',
      (tester) async {
    final pressed = <int>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            for (var i = 0; i < 2; i++)
              PressObserver(
                onPress: () => pressed.add(i),
                child: Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: SizedBox(height: 100, child: Text('card $i')),
                ),
              ),
          ],
        ),
      ),
    ));
    final first = cardBody(tester, 0);
    final second = cardBody(tester, 1);
    final gapY = (first.bottom + second.top) / 2; // 두 카드 사이 8px 틈의 한가운데
    expect(second.top - first.bottom, 8);
    await tester.tapAt(Offset(first.center.dx, gapY - 2)); // 위 카드의 아래 margin
    await tester.pump();
    await tester.tapAt(Offset(first.center.dx, gapY + 2)); // 아래 카드의 위 margin
    await tester.pump();
    expect(pressed, [0, 1]);
  });

  testWidgets('PressObserver 밖(목록 빈 영역)을 누르면 기록되지 않는다', (tester) async {
    await tester.pumpWidget(app());
    final observer = tester.getRect(find.byType(PressObserver));
    await tester.tapAt(Offset(observer.center.dx, observer.bottom + 40));
    await tester.pump();
    expect(presses, 0);
  });

  testWidgets('touch slop을 넘겨 끌면(스크롤) 기록되지 않고 목록은 스크롤된다', (tester) async {
    await tester.pumpWidget(app(count: 20));
    final scrollable = find.byType(Scrollable);
    final before = tester.state<ScrollableState>(scrollable).position.pixels;
    await tester.drag(find.text('card 2'), const Offset(0, -120));
    await tester.pump();
    expect(tester.state<ScrollableState>(scrollable).position.pixels,
        greaterThan(before));
    expect(presses, 0);
  });

  testWidgets('touch slop 안에서 살짝 움직인 누름은 기록된다', (tester) async {
    await tester.pumpWidget(app());
    final g = await tester.startGesture(tester.getCenter(find.text('card 0')));
    await g.moveBy(const Offset(0, 5));
    await g.up();
    await tester.pump();
    expect(presses, 1);
  });
}
