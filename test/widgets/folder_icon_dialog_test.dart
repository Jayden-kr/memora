// 폴더 아이콘 다이얼로그(lib/widgets/folder_icon_dialog.dart) 검증 — 순수 UI라 sqlite 없이
// 다이얼로그만 띄운다(DB 저장은 호출부 몫이고 database_helper_test #20이 본다).
//
// 반환 계약이 핵심이다: "저장"=고른 값, "기본으로"=(null, null) 레코드(null이 아님!),
// "취소"/바깥 탭=null. 마지막 둘을 섞으면 취소가 기본값 초기화로 저장된다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memora/l10n/app_localizations.dart';
import 'package:memora/models/folder.dart';
import 'package:memora/utils/folder_icons.dart';
import 'package:memora/widgets/folder_icon_dialog.dart';

/// 다이얼로그 결과를 담는 상자. 아직 안 닫혔을 때와 null로 닫혔을 때를 구분한다.
class _ResultBox {
  static const _unset = Object();
  Object? value = _unset;
  bool get popped => value != _unset;
}

Future<void> _open(WidgetTester tester, _ResultBox box, Folder folder) async {
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            box.value = await showFolderIconDialog(
              context: context,
              folder: folder,
            );
          },
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.byType(ElevatedButton));
  await tester.pumpAndSettle();
}

Finder _option(String key) => find.byKey(ValueKey('folderIconOption_$key'));

bool _isSelected(WidgetTester tester, String key) =>
    tester.widget<IconButton>(_option(key)).isSelected ?? false;

void main() {
  const blue = 0xFF2196F3;

  group('showFolderIconDialog 반환값', () {
    testWidgets('아이콘을 고르고 저장하면 (고른 키, 기존 색)을 돌려준다', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A', iconColor: blue));

      await tester.tap(_option('heart'));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(box.popped, isTrue);
      expect(box.value, (icon: 'heart', iconColor: blue));
    });

    testWidgets('아무것도 안 건드리고 저장하면 원래 값을 그대로 돌려준다', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A', icon: 'star', iconColor: blue));

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(box.value, (icon: 'star', iconColor: blue));
    });

    testWidgets('"Reset to default"는 null이 아니라 (null, null) 레코드를 돌려준다',
        (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A', icon: 'star', iconColor: blue));

      await tester.tap(find.text('Reset to default'));
      await tester.pumpAndSettle();

      expect(box.popped, isTrue);
      // 취소(null)와 구별돼야 한다 — 호출부가 null이면 아무것도 안 저장하기 때문.
      expect(box.value, isNotNull);
      expect(box.value, (icon: null, iconColor: null));
    });

    testWidgets('"Cancel"은 null을 돌려준다(고른 게 있어도)', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A', icon: 'star', iconColor: blue));

      await tester.tap(_option('heart'));
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(box.popped, isTrue);
      expect(box.value, isNull);
    });

    testWidgets('바깥(배리어)을 탭해 닫아도 null', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A', icon: 'star', iconColor: blue));

      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();

      expect(box.popped, isTrue);
      expect(box.value, isNull);
    });
  });

  group('선택 상태', () {
    testWidgets('저장돼 있던 아이콘이 선택돼 있고 다른 건 아니다', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A', icon: 'star', iconColor: blue));

      expect(_isSelected(tester, 'star'), isTrue);
      expect(_isSelected(tester, 'heart'), isFalse);
      expect(_isSelected(tester, 'home'), isFalse);
    });

    testWidgets('다른 아이콘을 누르면 선택이 옮겨간다', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A', icon: 'star'));

      await tester.tap(_option('home'));
      await tester.pump();

      expect(_isSelected(tester, 'home'), isTrue);
      expect(_isSelected(tester, 'star'), isFalse);
    });

    testWidgets('아이콘이 없던 폴더는 아무것도 선택돼 있지 않다', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A'));

      expect(_isSelected(tester, 'star'), isFalse);
      expect(_isSelected(tester, 'book'), isFalse);
    });

    testWidgets('이 앱이 모르는 키는 색만 바꿔 저장해도 지워지지 않는다', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A', icon: 'from_a_newer_app'));

      // 표에 없는 키라 선택된 칸은 없다.
      expect(_isSelected(tester, 'star'), isFalse);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(box.value, (icon: 'from_a_newer_app', iconColor: null));
    });
  });

  group('색 고르기', () {
    testWidgets('색 행을 누르면 투명도 슬라이더 없는 색 선택창이 열리고, 적용한 색이 불투명으로 저장된다',
        (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A', icon: 'star'));

      await tester.tap(find.byKey(const ValueKey('folderIconColorRow')));
      await tester.pumpAndSettle();

      // 색 선택창이 위에 떴다(제목 "Custom color")이고 투명도 조절은 없다.
      expect(find.text('Custom color'), findsOneWidget);
      expect(find.byType(Slider), findsNothing);
      expect(find.text('Opacity'), findsNothing);

      // 알파가 섞인 8자리를 넣어도 결과는 불투명.
      await tester.enterText(find.byType(TextField), '#80112233');
      await tester.pump();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      // 색 선택창은 닫히고 우리 다이얼로그는 그대로 열려 있다.
      expect(find.text('Custom color'), findsNothing);
      expect(box.popped, isFalse);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(box.value, (icon: 'star', iconColor: 0xFF112233));
    });

    testWidgets('색 선택창을 취소하면 색이 그대로다', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A', icon: 'star', iconColor: blue));

      await tester.tap(find.byKey(const ValueKey('folderIconColorRow')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '#112233');
      await tester.pump();
      // 취소 버튼이 두 다이얼로그에 하나씩 있으니 위에 뜬 것(마지막)을 누른다.
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(box.value, (icon: 'star', iconColor: blue));
    });
  });

  group('레이아웃 규칙', () {
    testWidgets('아이콘은 Wrap으로 깔고 GridView/LayoutBuilder는 안 쓴다', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A'));

      // AlertDialog는 content를 IntrinsicWidth로 감싸 크기를 잰다 — 고정 크기가 없는
      // GridView/LayoutBuilder는 그 경로에서 intrinsic 치수 예외를 낸다. 아이콘 24개가
      // 전부 하나의 Wrap 안에 있어야 한다.
      final dialog = find.byType(AlertDialog);
      expect(find.descendant(of: dialog, matching: find.byType(Wrap)),
          findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.byType(GridView)),
          findsNothing);
      expect(find.descendant(of: dialog, matching: find.byType(LayoutBuilder)),
          findsNothing);
      expect(
        find.descendant(
          of: find.descendant(of: dialog, matching: find.byType(Wrap)),
          matching: find.byType(IconButton),
        ),
        findsNWidgets(folderIcons.length),
      );
    });
  });

  group('좁은 화면', () {
    Future<void> setView(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    testWidgets('360×640 세로에서 예외 없이 열리고 저장 버튼까지 누를 수 있다', (tester) async {
      await setView(tester, const Size(360, 640));
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A', icon: 'star', iconColor: blue));

      expect(tester.takeException(), isNull);
      // 마지막 아이콘까지 그려져 있다(잘리지 않고 스크롤/줄바꿈으로 수용).
      expect(_option('home'), findsOneWidget);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(box.value, (icon: 'star', iconColor: blue));
      expect(tester.takeException(), isNull);
    });

    testWidgets('320×480처럼 더 좁아도 예외가 없다', (tester) async {
      await setView(tester, const Size(320, 480));
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A'));

      expect(tester.takeException(), isNull);
    });

    testWidgets('640×360 가로(높이 부족)에서도 예외 없이 열리고 스크롤로 끝 아이콘에 닿는다',
        (tester) async {
      await setView(tester, const Size(640, 360));
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A'));

      expect(tester.takeException(), isNull);

      await tester.ensureVisible(_option('home'));
      await tester.pump();
      await tester.tap(_option('home'));
      await tester.pump();
      expect(_isSelected(tester, 'home'), isTrue);
      expect(tester.takeException(), isNull);
    });
  });
}
