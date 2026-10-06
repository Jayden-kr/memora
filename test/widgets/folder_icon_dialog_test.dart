// 폴더 아이콘 다이얼로그(lib/widgets/folder_icon_dialog.dart) 검증 — 순수 UI라 sqlite 없이
// 다이얼로그만 띄운다(DB 저장은 호출부 몫이고 database_helper_test #20이 본다).
//
// 반환 계약이 핵심이다: "저장"=고른 값, "기본으로"=(null, null) 레코드(null이 아님!),
// "취소"/바깥 탭=null. 마지막 둘을 섞으면 취소가 기본값 초기화로 저장된다.
//
// 아이콘은 표(24개)에서 고르거나 입력칸에 이모지·글자 1~2개를 직접 넣을 수 있다 — 글자
// 형태는 't:' + 글자로 반환된다('글자 아이콘 입력' 그룹). 입력칸이 생기면서 화면에
// TextField가 둘(아이콘 입력칸 + 색 선택창의 헥스 입력)이 되므로 색 선택창의 입력은
// `_pickerHexField()`로만 찾는다. 글자는 전부 \u 이스케이프로 적는다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memora/l10n/app_localizations.dart';
import 'package:memora/l10n/app_localizations_en.dart';
import 'package:memora/l10n/app_localizations_ko.dart';
import 'package:memora/models/folder.dart';
import 'package:memora/utils/folder_icons.dart';
import 'package:memora/widgets/folder_icon_dialog.dart';

/// 다이얼로그 결과를 담는 상자. 아직 안 닫혔을 때와 null로 닫혔을 때를 구분한다.
class _ResultBox {
  static const _unset = Object();
  Object? value = _unset;
  bool get popped => value != _unset;
}

Future<void> _open(
  WidgetTester tester,
  _ResultBox box,
  Folder folder, {
  double textScale = 1.0,
}) async {
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    // 글자 크기 키우기(접근성) 시뮬레이션 — 다이얼로그 라우트는 이 builder 아래에 뜬다.
    builder: textScale == 1.0
        ? null
        : (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
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

/// 색 선택창("Custom color")의 헥스 입력칸. 아이콘 입력칸과 겹치지 않게 그 선택창 안에서만 찾는다.
Finder _pickerHexField() => find.descendant(
      of: find.widgetWithText(AlertDialog, 'Custom color'),
      matching: find.byType(TextField),
    );

/// 아이콘 직접 입력칸 / 미리보기 / 미리보기 안의 글자.
final Finder _textField = find.byKey(const ValueKey('folderIconTextField'));
final Finder _preview = find.byKey(const ValueKey('folderIconPreview'));
final Finder _previewGlyph = find.descendant(
    of: _preview, matching: find.byKey(const ValueKey('folderIconGlyph')));

final Finder _saveButton = find.widgetWithText(TextButton, 'Save');
bool _saveEnabled(WidgetTester tester) =>
    tester.widget<TextButton>(_saveButton).onPressed != null;

String _fieldText(WidgetTester tester) =>
    tester.widget<TextField>(_textField).controller!.text;

/// 목록에서 선택된 아이콘 키들(입력이 있으면 비어 있어야 한다).
List<String> _selectedKeys(WidgetTester tester) =>
    [for (final k in folderIcons.keys) if (_isSelected(tester, k)) k];

const _invalidText = 'Use 1–2 emoji or characters.';

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

    testWidgets('"Default"는 null이 아니라 (null, null) 레코드를 돌려준다',
        (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A', icon: 'star', iconColor: blue));

      await tester.tap(find.text('Default'));
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

    testWidgets('이 앱이 모르는 키는 아무것도 안 건드리고 저장해도 지워지지 않는다', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A', icon: 'from_a_newer_app'));

      // 표에 없는 키라 선택된 칸은 없다.
      expect(_isSelected(tester, 'star'), isFalse);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(box.value, (icon: 'from_a_newer_app', iconColor: null));
    });

    testWidgets('이 앱이 모르는 키는 색 선택창으로 색만 바꿔 저장해도 지워지지 않는다', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A', icon: 'from_a_newer_app'));

      // 색 행 → 색 선택창 → 헥스 입력 → 적용 → 저장. 이 경로가 아이콘 키를 건드리면
      // (예: 색을 고를 때 모르는 키를 null로 정리) 다른 버전이 만든 키가 조용히 사라진다.
      await tester.tap(find.byKey(const ValueKey('folderIconColorRow')));
      await tester.pumpAndSettle();
      expect(find.text('Custom color'), findsOneWidget); // 색 선택창이 실제로 열렸다
      await tester.enterText(_pickerHexField(), '#112233');
      await tester.pump();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(find.text('Custom color'), findsNothing);
      expect(box.popped, isFalse);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(box.value, (icon: 'from_a_newer_app', iconColor: 0xFF112233));
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
      await tester.enterText(_pickerHexField(), '#80112233');
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
      await tester.enterText(_pickerHexField(), '#112233');
      await tester.pump();
      // 취소 버튼이 두 다이얼로그에 하나씩 있으니 위에 뜬 것(마지막)을 누른다.
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(box.value, (icon: 'star', iconColor: blue));
    });
  });

  // 직접 입력: 이모지·글자 1~2개(그래핌)를 't:' + 글자로 돌려준다. 입력이 있으면 입력이 목록
  // 선택보다 우선하고(하이라이트 = 저장될 값), 쓸 수 없는 입력이면 저장 버튼이 꺼진다.
  group('글자 아이콘 입력', () {
    const aleph = '\u05D0';
    const flag = '\u{1F1EE}\u{1F1F1}';

    Future<void> setView(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    testWidgets('글자를 넣고 저장하면 목록 선택 없이 미리보기에 글자가 보이고 (t:글자, 색)을 돌려준다',
        (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A', iconColor: blue));

      await tester.enterText(_textField, aleph);
      await tester.pump();

      expect(_selectedKeys(tester), isEmpty);
      expect(find.descendant(of: _preview, matching: find.text(aleph)),
          findsOneWidget);
      expect(tester.widget<Text>(_previewGlyph).style?.color, const Color(blue));

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(box.value, (icon: 't:$aleph', iconColor: blue));
    });

    testWidgets('영문 소문자 "en"은 접두사가 붙어 저장된다(키로 읽히지 않게)', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A'));

      await tester.enterText(_textField, 'en');
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(box.value, (icon: 't:en', iconColor: null));
    });

    testWidgets('글자 아이콘이 저장된 폴더는 입력칸에 글자가 채워져 열리고 목록 선택은 없다 — 그대로 저장하면 같은 값',
        (tester) async {
      final box = _ResultBox();
      await _open(
          tester, box, Folder(name: 'A', icon: 't:$flag', iconColor: blue));

      expect(_fieldText(tester), flag);
      expect(_selectedKeys(tester), isEmpty);
      expect(find.descendant(of: _preview, matching: find.text(flag)),
          findsOneWidget);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(box.value, (icon: 't:$flag', iconColor: blue));
    });

    testWidgets('글자를 넣은 뒤 목록에서 아이콘을 고르면 입력이 비워지고 그 아이콘이 저장된다', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A', iconColor: blue));

      await tester.enterText(_textField, aleph);
      await tester.pump();
      await tester.tap(_option('heart'));
      await tester.pump();

      expect(_fieldText(tester), isEmpty);
      expect(_isSelected(tester, 'heart'), isTrue);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(box.value, (icon: 'heart', iconColor: blue));
    });

    testWidgets('입력이 있는 동안 목록 선택은 해제되고, 입력을 지우면 원래 고르던 아이콘이 돌아온다',
        (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A', icon: 'star', iconColor: blue));
      expect(_isSelected(tester, 'star'), isTrue);

      await tester.enterText(_textField, aleph);
      await tester.pump();
      expect(_isSelected(tester, 'star'), isFalse);

      await tester.enterText(_textField, '');
      await tester.pump();
      expect(_isSelected(tester, 'star'), isTrue);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(box.value, (icon: 'star', iconColor: blue));
    });

    testWidgets('3글자를 넣으면 2글자로 잘린다(그래핌 기준)', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A'));

      await tester.enterText(_textField, 'ABC');
      await tester.pump();
      expect(_fieldText(tester), 'AB');

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(box.value, (icon: 't:AB', iconColor: null));
    });

    testWidgets('글자 수는 그래핌: 국기 2개·이모지+피부색은 각각 1글자로 센다', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A'));

      const thumbs = '\u{1F44D}\u{1F3FD}'; // 엄지 + 피부색 = 1글자
      await tester.enterText(_textField, '$flag$thumbs');
      await tester.pump();
      expect(_fieldText(tester), '$flag$thumbs');
      expect(_saveEnabled(tester), isTrue);
    });

    testWidgets('글자 수 한도는 맞는데 코드 단위가 너무 긴 입력(결합문자 도배)은 오류를 보이고 저장이 꺼진다',
        (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A', icon: 'star', iconColor: blue));

      // 'a' + 결합 악센트 40개 = 1그래핌이지만 41 코드 단위(> 32).
      await tester.enterText(_textField, 'a${'\u0301' * 40}');
      await tester.pump();

      expect(find.text(_invalidText), findsOneWidget);
      expect(_saveEnabled(tester), isFalse);
      expect(_previewGlyph, findsNothing);

      // 꺼진 저장 버튼을 눌러도 닫히지 않는다.
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(box.popped, isFalse);
    });

    testWidgets('안 보이는 글자(한글 채움)만 넣으면 오류를 보이고 저장이 꺼진다', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A'));

      await tester.enterText(_textField, '\u3164');
      await tester.pump();

      expect(find.text(_invalidText), findsOneWidget);
      expect(_saveEnabled(tester), isFalse);
    });

    testWidgets('쓸 수 있는 입력으로 고치면 오류가 사라지고 저장이 켜진다', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A'));

      await tester.enterText(_textField, '\u3164');
      await tester.pump();
      expect(_saveEnabled(tester), isFalse);

      await tester.enterText(_textField, aleph);
      await tester.pump();
      expect(find.text(_invalidText), findsNothing);
      expect(_saveEnabled(tester), isTrue);
    });

    testWidgets('제어문자(BEL)는 입력 단계에서 걸러진다', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A'));

      await tester.enterText(_textField, 'A\u0007');
      await tester.pump();
      expect(_fieldText(tester), 'A');

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(box.value, (icon: 't:A', iconColor: null));
    });

    testWidgets('줄/문단 구분자(U+2028·U+2029)도 입력 단계에서 걸러진다', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A'));

      // 이 두 글자는 trim()이 저장 때 벗겨 버리므로, 입력칸 글자(필터 결과)를 직접 본다.
      final separators =
          String.fromCharCodes(const [0x2028, 0x2029]); // 소스에 리터럴로 안 적는다
      await tester.enterText(_textField, 'A$separators');
      await tester.pump();

      expect(_fieldText(tester), 'A');
    });

    testWidgets('공백만 넣으면 입력 안 한 것: 오류 없이 목록 선택이 그대로 저장된다', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A', icon: 'star', iconColor: blue));

      await tester.enterText(_textField, '  ');
      await tester.pump();

      expect(find.text(_invalidText), findsNothing);
      expect(_isSelected(tester, 'star'), isTrue);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(box.value, (icon: 'star', iconColor: blue));
    });

    testWidgets('앞뒤 공백은 벗겨서 저장한다', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A'));

      await tester.enterText(_textField, ' $aleph ');
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(box.value, (icon: 't:$aleph', iconColor: null));
    });

    testWidgets('글자를 넣은 뒤에도 "Default"는 (null, null), "Cancel"은 null', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A', icon: 'star', iconColor: blue));
      await tester.enterText(_textField, aleph);
      await tester.pump();
      await tester.tap(find.text('Default'));
      await tester.pumpAndSettle();
      expect(box.value, isNotNull);
      expect(box.value, (icon: null, iconColor: null));

      final box2 = _ResultBox();
      await _open(tester, box2, Folder(name: 'A', icon: 'star', iconColor: blue));
      await tester.enterText(_textField, aleph);
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(box2.popped, isTrue);
      expect(box2.value, isNull);
    });

    testWidgets('글자 + 색 선택창의 색: 미리보기 글자와 저장값에 같이 반영된다', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A'));

      await tester.enterText(_textField, aleph);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('folderIconColorRow')));
      await tester.pumpAndSettle();
      await tester.enterText(_pickerHexField(), '#112233');
      await tester.pump();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      expect(tester.widget<Text>(_previewGlyph).style?.color,
          const Color(0xFF112233));

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(box.value, (icon: 't:$aleph', iconColor: 0xFF112233));
    });

    testWidgets('키보드가 300dp 올라온 360×640에서도 입력칸과 저장 버튼이 키보드 위에 있다',
        (tester) async {
      await setView(tester, const Size(360, 640));
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A'));

      await tester.ensureVisible(_textField);
      await tester.pumpAndSettle();
      await tester.enterText(_textField, aleph);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      const keyboardTop = 640.0 - 300.0;
      expect(tester.getRect(_textField).bottom, lessThanOrEqualTo(keyboardTop));
      expect(tester.getRect(find.text('Save')).bottom,
          lessThanOrEqualTo(keyboardTop));

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(box.value, (icon: 't:$aleph', iconColor: null));
    });

    testWidgets('320×480 + 글자 크기 2.0에서도 입력칸에 닿아 넣고 저장할 수 있다', (tester) async {
      await setView(tester, const Size(320, 480));
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A'), textScale: 2.0);

      await tester.ensureVisible(_textField);
      await tester.pump();
      await tester.enterText(_textField, 'EN');
      await tester.pump();
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(box.value, (icon: 't:EN', iconColor: null));
    });

    testWidgets('IME 조합 중(にほん)에는 오류 없이 저장만 꺼지고, 확정(日本)되면 저장된다', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A'));

      await tester.showKeyboard(_textField);
      // 조합 중: 3글자(にほん)가 아직 확정 전이라 한도로 잘리면 안 된다.
      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: '\u306B\u307B\u3093',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 0, end: 3),
      ));
      await tester.pump();

      expect(_fieldText(tester), '\u306B\u307B\u3093');
      expect(find.text(_invalidText), findsNothing);
      expect(_saveEnabled(tester), isFalse);

      // 변환 확정 → 2글자.
      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: '\u65E5\u672C',
        selection: TextSelection.collapsed(offset: 2),
      ));
      await tester.pump();
      expect(_fieldText(tester), '\u65E5\u672C');
      expect(_saveEnabled(tester), isTrue);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(box.value, (icon: 't:\u65E5\u672C', iconColor: null));
    });

    // ── L2: 조합이 확정 없이 끝나는 길(포커스를 잃음·"완료")도 2글자로 자른다 ──
    // 이 길은 입력 포매터를 안 거치고 컨트롤러가 조합 표시만 지운다 → State 리스너가 자른다.
    const nihon = '\u306B\u307B\u3093'; // にほん
    const niho = '\u306B\u307B'; // にほ

    Future<void> composeRaw(WidgetTester tester, String text) async {
      await tester.showKeyboard(_textField);
      tester.testTextInput.updateEditingValue(TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
        composing: TextRange(start: 0, end: text.length),
      ));
      await tester.pump();
    }

    testWidgets('조합 중 3글자(にほん)가 확정 없이 포커스를 잃으면 앞 2글자(にほ)로 잘린다', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A'));

      await composeRaw(tester, nihon);
      expect(_fieldText(tester), nihon);
      expect(_saveEnabled(tester), isFalse);

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      expect(_fieldText(tester), niho);
      expect(_saveEnabled(tester), isTrue);
      expect(find.text(_invalidText), findsNothing);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(box.value, (icon: 't:$niho', iconColor: null));
    });

    testWidgets('조합 표시만 지워져도(clearComposing) 같은 규칙으로 잘린다', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A'));

      await composeRaw(tester, nihon);
      // 포커스 상실·완료가 하는 일 그대로: 값은 두고 조합 범위만 비운다.
      tester.widget<TextField>(_textField).controller!.clearComposing();
      await tester.pump();

      expect(_fieldText(tester), niho);
      expect(_saveEnabled(tester), isTrue);
    });

    testWidgets('영어 키보드가 "ENG"를 조합 중에 "완료"를 누르면 "EN"으로 잘려 저장된다', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A'));

      await composeRaw(tester, 'ENG');
      expect(_fieldText(tester), 'ENG');
      expect(_saveEnabled(tester), isFalse);

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(_fieldText(tester), 'EN');
      expect(_saveEnabled(tester), isTrue);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(box.value, (icon: 't:EN', iconColor: null));
    });

    // ── L3: 쓸 수 없는 입력 중에도 미리보기는 기본 폴더로 깜빡이지 않는다 ──
    testWidgets('글자 "א"를 넣은 뒤 너무 긴 값을 조합하면 미리보기는 "א" 그대로(오류는 저장 버튼뿐)',
        (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A', iconColor: blue));

      await tester.enterText(_textField, aleph);
      await tester.pump();
      expect(find.descendant(of: _preview, matching: find.text(aleph)),
          findsOneWidget);

      await composeRaw(tester, nihon);

      expect(_saveEnabled(tester), isFalse); // 조합 중 초과: 저장은 막힌다
      expect(find.text(_invalidText), findsNothing); // 조합 중이라 오류 문구는 없다
      expect(find.descendant(of: _preview, matching: find.text(aleph)),
          findsOneWidget,
          reason: '미리보기가 마지막으로 쓸 수 있던 값(א)을 유지해야 한다');
      expect(find.descendant(of: _preview, matching: find.byType(Icon)),
          findsNothing);

      // 쓸 수 있는 값으로 확정되면 미리보기가 따라간다.
      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: '\u65E5\u672C',
        selection: TextSelection.collapsed(offset: 2),
      ));
      await tester.pump();
      expect(find.descendant(of: _preview, matching: find.text('\u65E5\u672C')),
          findsOneWidget);
    });

    testWidgets('쓸 수 없는 입력(결합문자 도배·한글 채움)이어도 미리보기는 직전 값을 유지한다',
        (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A', icon: 'heart', iconColor: blue));
      Icon previewIcon() => tester.widget<Icon>(
          find.descendant(of: _preview, matching: find.byType(Icon)));
      expect(previewIcon().icon, Icons.favorite);

      // 목록에서 고른 값(하트)이 마지막으로 쓸 수 있던 값이다.
      await tester.enterText(_textField, '\u3164');
      await tester.pump();
      expect(find.text(_invalidText), findsOneWidget);
      expect(previewIcon().icon, Icons.favorite);

      // 글자로 한 번 확정하면 그 글자가 마지막 값이 된다.
      await tester.enterText(_textField, aleph);
      await tester.pump();
      await tester.enterText(_textField, 'a${'\u0301' * 40}');
      await tester.pump();
      expect(find.text(_invalidText), findsOneWidget);
      expect(find.descendant(of: _preview, matching: find.text(aleph)),
          findsOneWidget);
      expect(find.descendant(of: _preview, matching: find.byType(Icon)),
          findsNothing);
    });

    // ── L4: 입력칸에는 공백이 남지 않는다(저장은 앞뒤 공백을 벗기므로) ──
    testWidgets('" EN"을 붙여넣으면 "EN"이 되어 "t:EN"으로 저장된다(앞 공백이 한도를 먹지 않는다)',
        (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A'));

      await tester.enterText(_textField, ' EN');
      await tester.pump();

      expect(_fieldText(tester), 'EN');
      expect(find.text('2/2'), findsOneWidget); // 카운터 = 저장될 글자 수
      expect(tester.widget<TextField>(_textField).controller!.selection.baseOffset, 2);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(box.value, (icon: 't:EN', iconColor: null));
    });

    testWidgets('"A " 뒤에 "B"를 치면 "AB" — 뒤 공백이 2번째 글자를 막지 않는다', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A'));

      await tester.enterText(_textField, 'A ');
      await tester.pump();
      expect(_fieldText(tester), 'A');
      expect(find.text('1/2'), findsOneWidget);

      // 키보드 입력: 칸에 있는 글자 뒤에 B가 붙는다.
      await tester.enterText(_textField, '${_fieldText(tester)}B');
      await tester.pump();
      expect(_fieldText(tester), 'AB');
      expect(find.text('2/2'), findsOneWidget);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(box.value, (icon: 't:AB', iconColor: null));
    });

    testWidgets('전각 공백·가운데 공백·여러 공백도 입력칸에서 빠진다', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A'));

      await tester.enterText(_textField, '\u3000A \u00A0B  ');
      await tester.pump();
      expect(_fieldText(tester), 'AB');
    });

    testWidgets('공백이 끼어 3글자를 넘는 붙여넣기("A B C")는 공백을 뺀 뒤 앞 2글자("AB")', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A'));

      await tester.enterText(_textField, 'A B C');
      await tester.pump();
      expect(_fieldText(tester), 'AB');
    });

    testWidgets('글자 아이콘이 저장된 폴더도 열릴 때 입력칸 글자는 그대로다(포매터가 건드리지 않는다)',
        (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A', icon: 't:EN'));
      expect(_fieldText(tester), 'EN');
      expect(find.text('2/2'), findsOneWidget);
    });

    // ── L6: 미리보기는 고른 목록 아이콘과 묶음 기본 아이콘도 보여준다 ──
    Icon previewIconOf(WidgetTester tester) => tester.widget<Icon>(
        find.descendant(of: _preview, matching: find.byType(Icon)));

    testWidgets('하트를 고르면 미리보기가 고른 색의 favorite 아이콘이다', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A', iconColor: blue));

      await tester.tap(_option('heart'));
      await tester.pump();

      expect(previewIconOf(tester).icon, Icons.favorite);
      expect(previewIconOf(tester).color, const Color(blue));
      expect(_previewGlyph, findsNothing);
    });

    testWidgets('아이콘이 없는 묶음 폴더의 미리보기는 folder_special', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'B', isBundle: true));
      expect(previewIconOf(tester).icon, Icons.folder_special);
    });

    testWidgets('아이콘이 없는 일반 폴더의 미리보기는 folder', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A'));
      expect(previewIconOf(tester).icon, Icons.folder);
    });

    testWidgets('묶음 폴더에서 하트를 고르면 favorite(기본 아이콘이 아니라 고른 값)', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'B', isBundle: true, iconColor: blue));

      await tester.tap(_option('heart'));
      await tester.pump();
      expect(previewIconOf(tester).icon, Icons.favorite);

      await tester.enterText(_textField, aleph);
      await tester.pump();
      expect(_previewGlyph, findsOneWidget);
      expect(find.descendant(of: _preview, matching: find.byType(Icon)), findsNothing);
    });

    testWidgets('글자를 넣은 뒤 지우면 미리보기가 원래 고르던 목록 아이콘으로 돌아온다', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A', icon: 'star', iconColor: blue));

      await tester.enterText(_textField, aleph);
      await tester.pump();
      await tester.enterText(_textField, '');
      await tester.pump();

      expect(previewIconOf(tester).icon, Icons.star);
    });

    testWidgets('글자를 넣고 저장해 닫아도 퇴장 애니메이션 중 예외가 없다(컨트롤러 dispose 타이밍)',
        (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A'));
      await tester.enterText(_textField, aleph);
      await tester.pump();

      await tester.tap(find.text('Save'));
      // 퇴장 애니메이션이 진행되는 동안에도 예외가 없어야 한다.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(box.popped, isTrue);
    });

    testWidgets('영어 UI에는 "Emoji or text" 라벨이 있다', (tester) async {
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A'));
      expect(find.text('Emoji or text'), findsOneWidget);
    });

    test('입력칸 문구 세 개에 ko 번역이 있고 en과 다르다', () {
      final en = AppLocalizationsEn();
      final ko = AppLocalizationsKo();
      final pairs = <String, (String, String)>{
        'folderIconTextLabel': (ko.folderIconTextLabel, en.folderIconTextLabel),
        'folderIconTextHint': (ko.folderIconTextHint, en.folderIconTextHint),
        'folderIconTextInvalid':
            (ko.folderIconTextInvalid, en.folderIconTextInvalid),
      };
      pairs.forEach((name, p) {
        expect(p.$1.trim(), isNotEmpty, reason: 'ko $name 이 비었다');
        expect(p.$2.trim(), isNotEmpty, reason: 'en $name 이 비었다');
        expect(p.$1, isNot(p.$2), reason: '$name 의 ko/en 이 같다 — 번역이 빠졌다');
      });
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

  // 아이콘만 있는 버튼 24개 — 이름이 없으면 스크린리더가 전부 "버튼"으로만 읽는다.
  group('접근성: 아이콘 버튼 이름', () {
    testWidgets('모든 아이콘 버튼(24개)이 비어 있지 않은 tooltip과 시맨틱 이름을 가지고 서로 다르다',
        (tester) async {
      // 핸들은 테스트 본문 안에서 닫는다(addTearDown은 "끝날 때 열려 있음" 검사보다 늦다).
      final handle = tester.ensureSemantics();
      try {
        final box = _ResultBox();
        await _open(tester, box, Folder(name: 'A'));

        final seen = <String>{};
        for (final key in folderIcons.keys) {
          final button = tester.widget<IconButton>(_option(key));
          expect(button.tooltip, isNotNull, reason: '"$key" 버튼에 tooltip이 없다');
          expect(button.tooltip, isNotEmpty, reason: '"$key" 버튼의 tooltip이 비었다');

          // 스크린리더가 읽는 값: 시맨틱 노드의 라벨(또는 tooltip)에 이름이 들어 있어야 한다.
          final data = tester.getSemantics(_option(key)).getSemanticsData();
          final spoken = '${data.label} ${data.tooltip}';
          expect(spoken, contains(button.tooltip!),
              reason: '"$key" 버튼의 시맨틱 노드에 이름이 안 읽힌다: $spoken');

          expect(seen.add(button.tooltip!), isTrue,
              reason: '이름 "${button.tooltip}"이 다른 아이콘과 겹친다');
        }
        expect(seen.length, folderIcons.length);

        // 실제 영어 이름 몇 개를 고정(번역 키가 엉뚱한 아이콘에 붙는 실수를 잡는다).
        expect(tester.widget<IconButton>(_option('star')).tooltip, 'Star');
        expect(tester.widget<IconButton>(_option('home')).tooltip, 'Home');
        expect(tester.widget<IconButton>(_option('math')).tooltip, 'Math');
      } finally {
        handle.dispose();
      }
    });

    test('folderIcons의 모든 키에 ko/en 이름이 있다(아이콘을 추가하면 이름도 추가해야 한다)', () {
      final locales = <String, AppLocalizations>{
        'en': AppLocalizationsEn(),
        'ko': AppLocalizationsKo(),
      };
      for (final MapEntry(key: lang, value: t) in locales.entries) {
        final names = <String>{};
        for (final key in folderIcons.keys) {
          final name = folderIconName(t, key);
          expect(name, isNotNull,
              reason: '[$lang] 아이콘 키 "$key"에 이름이 없다 — folderIconName()의 switch와 '
                  'app_ko/app_en.arb의 folderIconName* 를 추가할 것');
          expect(name!.trim(), isNotEmpty, reason: '[$lang] "$key"의 이름이 비었다');
          expect(names.add(name), isTrue, reason: '[$lang] 이름 "$name"이 겹친다');
        }
      }
    });

    test('모르는 키는 이름이 없다(라벨을 지어내지 않는다)', () {
      expect(folderIconName(AppLocalizationsEn(), 'from_a_newer_app'), isNull);
      expect(folderIconName(AppLocalizationsEn(), ''), isNull);
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

    // 접근성 글자 크기(2.0)를 켠 작은 화면. 예외가 없는 것만으로는 "내용이 0 높이로 찌그러져
    // 안 보이는" 경우(RenderFlex는 크기가 비면 오버플로를 보고하지 않는다)를 못 잡으니,
    // 세 동작이 화면 안에 있고 끝 아이콘까지 스크롤해 누를 수 있는지도 본다.
    Future<void> expectUsableAtLargeText(WidgetTester tester, Size size) async {
      await setView(tester, size);
      final box = _ResultBox();
      await _open(tester, box, Folder(name: 'A', icon: 'star', iconColor: blue),
          textScale: 2.0);

      expect(tester.takeException(), isNull);

      // 세 동작이 전부 찾아지고 화면 안에 있다(오른쪽/아래로 잘려 못 누르는 일이 없다).
      final screen = Offset.zero & size;
      for (final label in ['Default', 'Cancel', 'Save']) {
        final f = find.text(label);
        expect(f, findsOneWidget, reason: '"$label" 버튼이 없다');
        final r = tester.getRect(f);
        expect(
          r.left >= screen.left &&
              r.top >= screen.top &&
              r.right <= screen.right &&
              r.bottom <= screen.bottom,
          isTrue,
          reason: '"$label" 버튼($r)이 화면 $screen 밖으로 나갔다',
        );
      }

      // 끝 아이콘까지 스크롤해 누를 수 있다(내용이 눌려 사라지지 않았다).
      await tester.ensureVisible(_option('home'));
      await tester.pump();
      await tester.tap(_option('home'));
      await tester.pump();
      expect(_isSelected(tester, 'home'), isTrue);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(box.value, (icon: 'home', iconColor: blue));
      expect(tester.takeException(), isNull);
    }

    testWidgets('320×480 + 글자 크기 2.0 + 영어에서도 오버플로 없이 열리고 세 버튼을 누를 수 있다',
        (tester) => expectUsableAtLargeText(tester, const Size(320, 480)));

    // 480×320 가로 + 2.0은 제목·액션만으로 높이를 다 먹는 경우라, 제목까지 스크롤 영역에 넣는
    // `scrollable: true`가 없으면(content 안의 스크롤만 있으면) 오버플로가 난다.
    testWidgets('480×320 가로 + 글자 크기 2.0 + 영어에서도 오버플로 없이 열리고 세 버튼을 누를 수 있다',
        (tester) => expectUsableAtLargeText(tester, const Size(480, 320)));

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
