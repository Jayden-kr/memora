// FolderTile(lib/widgets/folder_tile.dart)의 폴더 아이콘/색 그리기 검증 — 순수 UI라
// sqlite 없이 위젯만 올린다.
//
// 1. 고른 색이 그대로 그려진다(예전 표의 키 'star'·'heart'는 기본 아이콘 — 24개 표는 없앴다).
// 2. 아이콘이 없으면 예전과 같은 기본(폴더/묶음
// 폴더 + 테마 primary). 3. 모르는 키는 기본으로 폴백. 4. 기본 색은 테마를 따라가고
// 고른 색은 테마와 무관. 5. 드래그 핸들(reorderIndex)·선택 체크박스(isSelecting) 동작은
// 아이콘 변경과 무관하게 그대로. 6. 글자 아이콘('t:…')은 FolderIconView가 글자로 그린다
// (글자 글리프는 \u 이스케이프로 적는다).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memora/l10n/app_localizations.dart';
import 'package:memora/models/folder.dart';
import 'package:memora/widgets/folder_tile.dart';

Widget _app(Widget tile, {ThemeData? theme}) => MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: theme,
      home: Scaffold(body: tile),
    );

Icon _leadingIcon(WidgetTester tester, IconData data) =>
    tester.widget<Icon>(find.byIcon(data));

void main() {
  const blue = 0xFF2196F3;

  group('FolderTile 아이콘', () {
    testWidgets('예전 표의 키("star")가 저장된 폴더는 기본 폴더 아이콘 + 고른 색으로 그려진다', (tester) async {
      await tester.pumpWidget(_app(FolderTile(
        folder: Folder(name: 'A', icon: 'star', iconColor: blue),
        onTap: () {},
      )));

      expect(find.byIcon(Icons.folder), findsOneWidget);
      expect(_leadingIcon(tester, Icons.folder).color, const Color(blue));
      expect(find.byIcon(Icons.star), findsNothing);
    });

    testWidgets('아이콘/색이 없는 일반 폴더는 기본 folder + 테마 primary', (tester) async {
      await tester.pumpWidget(_app(FolderTile(
        folder: Folder(name: 'A'),
        onTap: () {},
      )));

      final scheme = Theme.of(tester.element(find.byType(FolderTile))).colorScheme;
      expect(find.byIcon(Icons.folder), findsOneWidget);
      expect(_leadingIcon(tester, Icons.folder).color, scheme.primary);
    });

    testWidgets('아이콘이 없는 묶음 폴더는 기본 folder_special', (tester) async {
      await tester.pumpWidget(_app(FolderTile(
        folder: Folder(name: 'B', isBundle: true),
        onTap: () {},
      )));

      final scheme = Theme.of(tester.element(find.byType(FolderTile))).colorScheme;
      expect(find.byIcon(Icons.folder_special), findsOneWidget);
      expect(find.byIcon(Icons.folder), findsNothing);
      expect(_leadingIcon(tester, Icons.folder_special).color, scheme.primary);
    });

    testWidgets('묶음 폴더도 고른 색이 적용된다(예전 키("heart")는 기본 folder_special)', (tester) async {
      await tester.pumpWidget(_app(FolderTile(
        folder: Folder(name: 'B', isBundle: true, icon: 'heart', iconColor: blue),
        onTap: () {},
      )));

      expect(find.byIcon(Icons.folder_special), findsOneWidget);
      expect(find.byIcon(Icons.favorite), findsNothing);
      expect(_leadingIcon(tester, Icons.folder_special).color, const Color(blue));
      // 묶음 폴더 부제목은 아이콘과 무관하게 그대로.
      expect(find.text('Bundle folder'), findsOneWidget);
    });

    testWidgets('모르는 키는 기본 아이콘으로 폴백하되 색은 고른 대로', (tester) async {
      await tester.pumpWidget(_app(FolderTile(
        folder: Folder(name: 'A', icon: 'from_a_newer_app', iconColor: blue),
        onTap: () {},
      )));

      expect(find.byIcon(Icons.folder), findsOneWidget);
      expect(_leadingIcon(tester, Icons.folder).color, const Color(blue));
    });

    testWidgets('글자 아이콘("t:…")은 그 글자를 고른 색으로 그리고 기본 폴더 아이콘은 안 그린다',
        (tester) async {
      await tester.pumpWidget(_app(FolderTile(
        folder: Folder(name: 'A', icon: 't:\u05D0', iconColor: blue),
        onTap: () {},
      )));

      expect(find.text('\u05D0'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('folderIconGlyph'))).style?.color,
          const Color(blue));
      expect(find.byIcon(Icons.folder), findsNothing);
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('묶음 폴더의 글자 아이콘도 글자로 그려지고 부제목은 그대로', (tester) async {
      await tester.pumpWidget(_app(FolderTile(
        folder: Folder(name: 'B', isBundle: true, icon: 't:\u{1F1EE}\u{1F1F1}'),
        onTap: () {},
      )));

      expect(find.byKey(const ValueKey('folderIconGlyph')), findsOneWidget);
      expect(find.text('\u{1F1EE}\u{1F1F1}'), findsOneWidget);
      expect(find.byIcon(Icons.folder_special), findsNothing);
      expect(find.byType(Icon), findsNothing);
      expect(find.text('Bundle folder'), findsOneWidget);
    });

    testWidgets('기본 색은 테마를 따라가고 고른 색은 테마가 바뀌어도 고정', (tester) async {
      final light = ThemeData(
          colorSchemeSeed: const Color(0xFFFF6B6B), brightness: Brightness.light);
      final dark = ThemeData(
          colorSchemeSeed: const Color(0xFFFF6B6B), brightness: Brightness.dark);
      expect(light.colorScheme.primary, isNot(dark.colorScheme.primary),
          reason: '이 테스트의 전제: 두 테마의 primary가 달라야 한다');

      Widget tiles() => Column(children: [
            FolderTile(folder: Folder(name: 'default'), onTap: () {}),
            // 고른 색 폴더는 묶음으로 둔다 — 기본 아이콘이 folder_special이라 두 타일이 구별된다.
            FolderTile(
                folder: Folder(name: 'custom', isBundle: true, iconColor: blue),
                onTap: () {}),
          ]);

      await tester.pumpWidget(_app(tiles(), theme: light));
      expect(_leadingIcon(tester, Icons.folder).color, light.colorScheme.primary);
      expect(_leadingIcon(tester, Icons.folder_special).color, const Color(blue));

      await tester.pumpWidget(_app(tiles(), theme: dark));
      await tester.pumpAndSettle();
      expect(_leadingIcon(tester, Icons.folder).color, dark.colorScheme.primary);
      expect(_leadingIcon(tester, Icons.folder_special).color, const Color(blue));
    });
  });

  group('FolderTile 앞자리(드래그 핸들/체크박스)는 아이콘과 무관하게 그대로', () {
    testWidgets('reorderIndex가 있으면 기본 폴더 아이콘이 드래그 핸들 안에 있다', (tester) async {
      await tester.pumpWidget(_app(FolderTile(
        folder: Folder(name: 'A', iconColor: blue),
        onTap: () {},
        reorderIndex: 0,
      )));

      expect(
        find.descendant(
          of: find.byType(ReorderableDragStartListener),
          matching: find.byIcon(Icons.folder),
        ),
        findsOneWidget,
      );
    });

    testWidgets('reorderIndex가 있으면 글자 아이콘도 드래그 핸들 안에 있다', (tester) async {
      await tester.pumpWidget(_app(FolderTile(
        folder: Folder(name: 'A', icon: 't:EN', iconColor: blue),
        onTap: () {},
        reorderIndex: 0,
      )));

      expect(
        find.descendant(
          of: find.byType(ReorderableDragStartListener),
          matching: find.byKey(const ValueKey('folderIconGlyph')),
        ),
        findsOneWidget,
      );
    });

    testWidgets('reorderIndex가 없으면 드래그 핸들이 없다', (tester) async {
      await tester.pumpWidget(_app(FolderTile(
        folder: Folder(name: 'A', iconColor: blue),
        onTap: () {},
      )));

      expect(find.byType(ReorderableDragStartListener), findsNothing);
      expect(find.byIcon(Icons.folder), findsOneWidget);
    });

    testWidgets('isSelecting이면 체크박스가 아이콘 자리를 차지한다', (tester) async {
      await tester.pumpWidget(_app(FolderTile(
        folder: Folder(name: 'A', iconColor: blue),
        onTap: () {},
        isSelecting: true,
        isSelected: true,
      )));

      expect(find.byType(Checkbox), findsOneWidget);
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
      expect(find.byIcon(Icons.folder), findsNothing);
    });

    testWidgets('isSelecting이면 글자 아이콘도 체크박스에 자리를 내준다', (tester) async {
      await tester.pumpWidget(_app(FolderTile(
        folder: Folder(name: 'A', icon: 't:\u05D0', iconColor: blue),
        onTap: () {},
        isSelecting: true,
      )));

      expect(find.byType(Checkbox), findsOneWidget);
      expect(find.byKey(const ValueKey('folderIconGlyph')), findsNothing);
    });
  });
}
