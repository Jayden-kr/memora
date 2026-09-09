// FolderNameDialog(lib/widgets/folder_name_dialog.dart) 검증.
//
// 핵심: _submit()의 validate 콜백이 예외를 던져도(DB 에러 등) _checking이 true로
// 영구히 남아 확인 버튼이 잠기지 않는지 — 그 외 정상 경로(초기값 채움/빈 입력은
// validate 생략/에러 표시 후 재시도 가능/trim)도 함께 고정한다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memora/l10n/app_localizations.dart';
import 'package:memora/widgets/folder_name_dialog.dart';

/// showDialog가 반환할 Future의 결과를 담는 상자. 다이얼로그가 아직 pop되지
/// 않았을 때와 null로 pop됐을 때를 구분하기 위해 sentinel을 초깃값으로 둔다.
class _ResultBox {
  static const _unset = Object();
  Object? value = _unset;
  bool get popped => value != _unset;
}

void main() {
  group('FolderNameDialog', () {
    Future<void> openDialog(
      WidgetTester tester,
      _ResultBox box, {
      String? initialName,
      Future<String?> Function(String name)? validate,
    }) async {
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                box.value = await showDialog<String>(
                  context: context,
                  builder: (_) => FolderNameDialog(
                    title: 'Title',
                    hint: 'Hint',
                    confirmLabel: 'Confirm',
                    initialName: initialName,
                    validate: validate,
                  ),
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

    bool confirmEnabled(WidgetTester tester) => tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Confirm'))
            .onPressed !=
        null;

    testWidgets('(a) initialName이 TextField에 미리 채워진다', (tester) async {
      final box = _ResultBox();
      await openDialog(tester, box, initialName: 'My Folder');

      expect(find.text('My Folder'), findsOneWidget);
    });

    testWidgets('(b) 빈 입력 — confirm은 validate를 부르지 않고 빈 문자열을 pop한다',
        (tester) async {
      final box = _ResultBox();
      var validateCalls = 0;
      await openDialog(tester, box, validate: (name) async {
        validateCalls++;
        return null;
      });

      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect(box.value, '');
      expect(validateCalls, 0);
    });

    testWidgets(
        '(c) validate가 에러 문자열을 돌려주면 에러가 표시되고 다이얼로그가 유지되며 '
        '확인 버튼이 다시 활성화된다', (tester) async {
      final box = _ResultBox();
      await openDialog(tester, box,
          validate: (name) async => 'duplicate name');

      await tester.enterText(find.byType(TextField), 'Dup');
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect(find.text('duplicate name'), findsOneWidget);
      expect(find.byType(FolderNameDialog), findsOneWidget,
          reason: '다이얼로그가 닫히지 않고 유지돼야 한다');
      expect(box.popped, isFalse, reason: 'validate가 에러를 돌려주면 pop되지 않는다');
      expect(confirmEnabled(tester), isTrue,
          reason: '_checking이 false로 리셋되어 확인 버튼이 다시 눌려야 한다');
    });

    testWidgets(
        '(d) validate가 throw하면 트림된 이름으로 pop되고 예외가 새지 않는다 '
        '(검사 실패로 버튼이 영구히 잠기는 회귀 방지)', (tester) async {
      final box = _ResultBox();
      await openDialog(tester, box,
          validate: (name) async => throw StateError('db error'));

      await tester.enterText(find.byType(TextField), '  New Folder  ');
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect(box.value, 'New Folder');
      expect(tester.takeException(), isNull);
    });

    testWidgets('(e) 공백 패딩 입력은 trim되어 pop된다', (tester) async {
      final box = _ResultBox();
      await openDialog(tester, box);

      await tester.enterText(find.byType(TextField), '  Padded Name  ');
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect(box.value, 'Padded Name');
    });
  });
}
