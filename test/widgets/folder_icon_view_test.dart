// FolderIconView(lib/widgets/folder_icon_view.dart) 검증 — 순수 UI라 sqlite 없이 위젯만
// 올린다.
//
// 1. 키(또는 null)면 머티리얼 아이콘 + 고른 색/기본색, 묶음 여부에 맞는 기본 아이콘.
// 2. 't:' + 글자면 그 글자를 고른 색으로 그리고 Icon은 없다.
// 3. 글자가 어떤 모양이든(길이·문자 체계·이모지) 아이콘 칸(24×24) 안에 들어온다.
// 4. 규칙을 어긴 글자 값은 기본 아이콘 — 던지지 않는다.
// 5. 비활성(enabled: false)은 아이콘과 같은 onSurface 38% — 글자는 필터로 한 번만.
// 6. 글자 크기 설정(textScale)이 칸을 못 키운다. 7. 글자는 스크린리더에 안 읽힌다.
//
// 글자는 전부 \u 이스케이프로 적는다(소스 인코딩에 따라 이모지가 바뀌는 일을 막는다).
// 위젯 테스트의 기본 글꼴(Ahem)은 모든 글자를 1em 정사각형으로 그리므로 "칸 안에 들어감"은
// 실제 글꼴 모양이 아니라 FittedBox 축소 규칙을 확인한다(실제 모양은 기기에서 눈으로).
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memora/l10n/app_localizations.dart';
import 'package:memora/widgets/folder_icon_view.dart';

const _blue = 0xFF2196F3;
final _glyph = find.byKey(const ValueKey('folderIconGlyph'));

Widget _app(Widget child, {ThemeData? theme, double textScale = 1.0}) =>
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: theme,
      builder: textScale == 1.0
          ? null
          : (context, c) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(textScale)),
                child: c!,
              ),
      home: Scaffold(body: Center(child: child)),
    );

Future<void> _pump(
  WidgetTester tester, {
  required String? icon,
  int? iconColor,
  bool isBundle = false,
  bool enabled = true,
  double? size,
  ThemeData? theme,
  double textScale = 1.0,
}) =>
    tester.pumpWidget(_app(
      FolderIconView(
        icon: icon,
        iconColor: iconColor,
        isBundle: isBundle,
        enabled: enabled,
        size: size,
      ),
      theme: theme,
      textScale: textScale,
    ));

ColorScheme _scheme(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(FolderIconView))).colorScheme;

RenderParagraph _paragraph(WidgetTester tester) => tester.renderObject<RenderParagraph>(
    find.descendant(of: _glyph, matching: find.byType(RichText)));

void main() {
  group('키 아이콘(예전과 같은 그림)', () {
    testWidgets('고른 키와 색이 그대로 그려지고 글자는 없다', (tester) async {
      await _pump(tester, icon: 'star', iconColor: _blue);

      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.icon, Icons.star);
      expect(icon.color, const Color(_blue));
      expect(_glyph, findsNothing);
    });

    testWidgets('null은 기본 folder + 테마 primary, 묶음이면 folder_special', (tester) async {
      await _pump(tester, icon: null);
      expect(tester.widget<Icon>(find.byType(Icon)).icon, Icons.folder);
      expect(tester.widget<Icon>(find.byType(Icon)).color, _scheme(tester).primary);

      await _pump(tester, icon: null, isBundle: true);
      expect(tester.widget<Icon>(find.byType(Icon)).icon, Icons.folder_special);
      expect(tester.widget<Icon>(find.byType(Icon)).color, _scheme(tester).primary);
    });

    testWidgets('모르는 키는 기본 아이콘, 색은 고른 대로', (tester) async {
      await _pump(tester, icon: 'from_a_newer_app', iconColor: _blue);
      expect(tester.widget<Icon>(find.byType(Icon)).icon, Icons.folder);
      expect(tester.widget<Icon>(find.byType(Icon)).color, const Color(_blue));
    });

    testWidgets('size를 주면 Icon 크기가 된다', (tester) async {
      await _pump(tester, icon: 'star', size: 32);
      expect(tester.widget<Icon>(find.byType(Icon)).size, 32);
    });
  });

  group('글자 아이콘', () {
    testWidgets('글자가 고른 색으로 그려지고 Icon은 없다', (tester) async {
      await _pump(tester, icon: 't:\u05D0', iconColor: _blue);

      expect(find.text('\u05D0'), findsOneWidget);
      expect(tester.widget<Text>(_glyph).style?.color, const Color(_blue));
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('색이 없으면 테마 primary, 알파가 0이어도 불투명하게', (tester) async {
      await _pump(tester, icon: 't:EN');
      expect(tester.widget<Text>(_glyph).style?.color, _scheme(tester).primary);

      await _pump(tester, icon: 't:EN', iconColor: 0x00112233);
      expect(tester.widget<Text>(_glyph).style?.color, const Color(0xFF112233));
    });

    testWidgets('묶음 여부는 글자 아이콘에 영향이 없다(글자가 기본 아이콘 자리를 대신한다)',
        (tester) async {
      await _pump(tester, icon: 't:\u{1F1EE}\u{1F1F1}', isBundle: true);
      expect(_glyph, findsOneWidget);
      expect(find.byType(Icon), findsNothing);
    });

    // 칸 안에 들어오는지: 글자 모양(길이·문자 체계·이모지)과 무관해야 한다.
    final fitCases = <String, String>{
      'EN': 'EN',
      'en': 'en',
      '국기(지역 표시 문자 2개)': '\u{1F1EE}\u{1F1F1}',
      '히브리어 2글자': '\u05D0\u05D1',
      '히라가나 2글자': '\u3042\u3044',
      '한자 2글자': '\u65E5\u672C',
      '넓은 글자 W': 'W',
      '가족 이모지 2개':
          '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}\u200D\u{1F466}'
              '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}\u200D\u{1F466}',
    };
    fitCases.forEach((label, glyph) {
      testWidgets('칸(24×24) 안에 들어오고 잘리지 않는다: $label', (tester) async {
        await _pump(tester, icon: 't:$glyph', iconColor: _blue);

        expect(tester.takeException(), isNull);
        final view = tester.getRect(find.byType(FolderIconView));
        expect(view.size, const Size(24, 24));

        final rect = tester.getRect(_glyph);
        const eps = 0.01;
        expect(rect.left, greaterThanOrEqualTo(view.left - eps));
        expect(rect.top, greaterThanOrEqualTo(view.top - eps));
        expect(rect.right, lessThanOrEqualTo(view.right + eps));
        expect(rect.bottom, lessThanOrEqualTo(view.bottom + eps));

        // 글자를 잘라서 칸에 맞춘 게 아니라(문단 폭이 칸에 눌려 넘치는 채 그려지는 게
        // 아니라) 문단은 제 폭 그대로 그리고 통째로 줄여서 맞춘다.
        final paragraph = _paragraph(tester);
        expect(paragraph.size.width,
            greaterThanOrEqualTo(paragraph.getMaxIntrinsicWidth(double.infinity) - 0.01));
      });
    });

    testWidgets('size를 주면 그 크기의 칸 안에 들어온다(미리보기 32)', (tester) async {
      await _pump(tester, icon: 't:EN', size: 32);
      final view = tester.getRect(find.byType(FolderIconView));
      expect(view.size, const Size(32, 32));
      final rect = tester.getRect(_glyph);
      expect(rect.left, greaterThanOrEqualTo(view.left - 0.01));
      expect(rect.right, lessThanOrEqualTo(view.right + 0.01));
      final paragraph = _paragraph(tester);
      expect(paragraph.size.width,
          greaterThanOrEqualTo(paragraph.getMaxIntrinsicWidth(double.infinity) - 0.01));
    });

    testWidgets('size가 없으면 주변 IconTheme 크기를 따른다', (tester) async {
      await tester.pumpWidget(_app(const IconTheme(
        data: IconThemeData(size: 40),
        child: FolderIconView(icon: 't:EN', iconColor: null, isBundle: false),
      )));
      expect(tester.getRect(find.byType(FolderIconView)).size, const Size(40, 40));
    });
  });

  group('쓸 수 없는 글자 값은 기본 아이콘', () {
    final invalid = <String, String>{
      '3글자': 't:ABC',
      '앞 공백(정규형 아님)': 't: A',
      '접두사만': 't:',
      '결합문자 도배': 't:a${'\u0301' * 40}',
      '제어문자': 't:A\u0007',
    };
    invalid.forEach((label, value) {
      testWidgets('$label → 폴더 기본 아이콘, 글자 없음, 던지지 않음', (tester) async {
        await _pump(tester, icon: value, iconColor: _blue);

        expect(tester.takeException(), isNull);
        expect(tester.widget<Icon>(find.byType(Icon)).icon, Icons.folder);
        expect(tester.widget<Icon>(find.byType(Icon)).color, const Color(_blue));
        expect(_glyph, findsNothing);
      });
    });

    testWidgets('묶음 폴더의 잘못된 글자 값은 folder_special', (tester) async {
      await _pump(tester, icon: 't:ABC', isBundle: true);
      expect(tester.widget<Icon>(find.byType(Icon)).icon, Icons.folder_special);
    });
  });

  group('비활성(enabled: false) — 아이콘과 같은 onSurface 38%', () {
    testWidgets('키 아이콘: Icon 색이 onSurface 38%, 필터는 없다', (tester) async {
      await _pump(tester, icon: 'star', iconColor: _blue, enabled: false);

      final onSurface38 = _scheme(tester).onSurface.withValues(alpha: 0.38);
      expect(tester.widget<Icon>(find.byType(Icon)).color, onSurface38);
      expect(find.byType(ColorFiltered), findsNothing);
    });

    testWidgets('글자 아이콘: srcIn 필터가 onSurface 38%를 한 번만 입히고 안쪽 글자는 불투명 onSurface',
        (tester) async {
      await _pump(tester, icon: 't:\u{1F1EE}\u{1F1F1}', iconColor: _blue, enabled: false);

      final scheme = _scheme(tester);
      final filtered = tester.widget<ColorFiltered>(find.descendant(
          of: find.byType(FolderIconView), matching: find.byType(ColorFiltered)));
      expect(filtered.colorFilter,
          ColorFilter.mode(scheme.onSurface.withValues(alpha: 0.38), BlendMode.srcIn));

      // 이중 감쇠 금지: 안쪽 글자는 이미 흐린 색이 아니라 불투명 onSurface여야 한다.
      final inner = tester.widget<Text>(find.descendant(
          of: find.byType(ColorFiltered), matching: _glyph));
      expect(inner.style?.color, scheme.onSurface);
      expect(inner.style!.color!.a, 1.0);
      // 고른 색은 비활성에서 쓰이지 않는다.
      expect(inner.style?.color, isNot(const Color(_blue)));
    });

    testWidgets('활성이면 글자 아이콘에 필터가 없다', (tester) async {
      await _pump(tester, icon: 't:\u05D0', iconColor: _blue);
      expect(find.byType(ColorFiltered), findsNothing);
      expect(tester.widget<Text>(_glyph).style?.color, const Color(_blue));
    });

    testWidgets('어두운 테마에서도 같은 규칙(onSurface는 테마를 따라간다)', (tester) async {
      final dark = ThemeData(
          colorSchemeSeed: const Color(0xFFFF6B6B), brightness: Brightness.dark);
      await _pump(tester, icon: 't:EN', enabled: false, theme: dark);
      final inner = tester.widget<Text>(_glyph);
      expect(inner.style?.color, dark.colorScheme.onSurface);
    });
  });

  group('글자 크기 설정과 무관(칸 고정)', () {
    testWidgets('textScale 2.0에서도 글자 크기·칸이 그대로다', (tester) async {
      await _pump(tester, icon: 't:EN', iconColor: _blue);
      final normalParagraph = _paragraph(tester).size;

      await _pump(tester, icon: 't:EN', iconColor: _blue, textScale: 2.0);

      expect(tester.widget<Text>(_glyph).textScaler, TextScaler.noScaling);
      expect(_paragraph(tester).size, normalParagraph,
          reason: '글자 크기 설정이 아이콘 글자의 문단 크기를 키웠다');
      expect(tester.getRect(find.byType(FolderIconView)).size, const Size(24, 24));
      expect(tester.takeException(), isNull);
    });
  });

  group('접근성', () {
    testWidgets('글자는 장식이다: 스크린리더가 글자를 읽지 않고 제목(폴더 이름)만 읽는다', (tester) async {
      // 핸들은 테스트 본문 안에서 닫는다(addTearDown은 "끝날 때 열려 있음" 검사보다 늦다).
      final handle = tester.ensureSemantics();
      try {
        await tester.pumpWidget(_app(const ListTile(
          leading: FolderIconView(icon: 't:\u05D0', iconColor: _blue, isBundle: false),
          title: Text('Hebrew'),
        )));

        expect(find.bySemanticsLabel(RegExp('\u05D0')), findsNothing,
            reason: '글자 아이콘이 시맨틱 라벨로 노출된다');
        expect(find.bySemanticsLabel(RegExp('Hebrew')), findsOneWidget);
      } finally {
        handle.dispose();
      }
    });
  });
}
