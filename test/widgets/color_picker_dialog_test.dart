// 잠금화면 배경 커스텀 색상 다이얼로그(lib/widgets/color_picker_dialog.dart) 검증.
//
// 1. tryParseHexColor: #RRGGBB/#AARRGGBB, # 유무, 대소문자, 공백, 잘못된 길이/문자
// 2. 다이얼로그 위젯: hex 입력 → 미리보기 반영, SV사각형/Hue슬라이더 드래그 →
//    색 변경, 투명도 슬라이더 → 알파 반영, 잘못된 hex는 크래시 없이 무시,
//    적용/취소 반환값
// 3. 구조적 트립와이어: TextEditingController를 `showDialog(...).whenComplete()`
//    로 dispose하는 금지 패턴(push_notification_settings.dart의 _PushRuleDialog
//    문서 주석에 기록된 실제 크래시 원인)이 재발하지 않았는지 소스 텍스트로 확인.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memora/l10n/app_localizations.dart';
import 'package:memora/widgets/color_picker_dialog.dart';

/// 주석을 걷어낸 소스를 돌려준다(문자열 리터럴 안의 `//`는 건드리지 않음).
/// test/lock_screen_native_contract_test.dart 의 동일한 헬퍼와 같은 방식 —
/// 그 파일의 문서 주석대로, 이게 없으면 트립와이어가 "주석 속 예시"를 실제
/// 코드로 착각한다.
String _stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  var quote = '';
  while (i < src.length) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';
    if (quote.isNotEmpty) {
      out.write(c);
      if (c == '\\' && i + 1 < src.length) {
        out.write(next);
        i += 2;
        continue;
      }
      if (c == quote) quote = '';
      i++;
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && next == '/') {
      while (i < src.length && src.codeUnitAt(i) != 10) {
        i++;
      }
      continue;
    }
    if (c == '/' && next == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
        i++;
      }
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

void main() {
  group('tryParseHexColor', () {
    test('6자리 RGB, # 있음/없음 모두 완전 불투명으로 파싱', () {
      expect(tryParseHexColor('#1A2B3C'), const Color(0xFF1A2B3C));
      expect(tryParseHexColor('1A2B3C'), const Color(0xFF1A2B3C));
    });

    test('8자리 ARGB는 알파를 그대로 반영', () {
      expect(tryParseHexColor('#80112233'), const Color(0x80112233));
      expect(tryParseHexColor('80112233'), const Color(0x80112233));
    });

    test('대소문자 무관', () {
      expect(tryParseHexColor('ff00aa'), const Color(0xFFFF00AA));
      expect(tryParseHexColor('FF00AA'), const Color(0xFFFF00AA));
    });

    test('앞뒤 공백은 무시', () {
      expect(tryParseHexColor('  #1A2B3C  '), const Color(0xFF1A2B3C));
    });

    test('잘못된 길이는 null', () {
      expect(tryParseHexColor('#1A2B3'), isNull); // 5자리
      expect(tryParseHexColor('#1A2B3C4'), isNull); // 7자리
      expect(tryParseHexColor(''), isNull);
      expect(tryParseHexColor('#'), isNull);
    });

    test('16진수가 아닌 문자는 null', () {
      expect(tryParseHexColor('GGHHII'), isNull);
      expect(tryParseHexColor('zzz'), isNull);
      expect(tryParseHexColor('#ZZZZZZ'), isNull);
    });
  });

  group('color picker dialog', () {
    const initialColor = 0xFF1A1A2E;

    Future<int?> pumpAndOpenDialog(WidgetTester tester) async {
      int? result;
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showColorPickerDialog(
                  context: context,
                  initialColor: initialColor,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.byType(ElevatedButton));
      await tester.pumpAndSettle();
      return result; // 이 시점엔 아직 null(다이얼로그가 열려 있는 동안)
    }

    testWidgets('초기값이 hex 필드와 미리보기 스와치에 정확히 반영된다', (tester) async {
      await pumpAndOpenDialog(tester);

      expect(find.text('#1A1A2E'), findsOneWidget);
      final preview = tester
          .widgetList<ColorSwatchPreview>(find.byType(ColorSwatchPreview))
          .first;
      expect(preview.color, const Color(initialColor));
    });

    testWidgets('hex 필드에 유효한 값을 입력하면 실시간으로 미리보기에 반영된다',
        (tester) async {
      await pumpAndOpenDialog(tester);

      await tester.enterText(find.byType(TextField), '#FF00AA');
      await tester.pump();

      final preview = tester
          .widgetList<ColorSwatchPreview>(find.byType(ColorSwatchPreview))
          .first;
      // 6자리 입력이므로 완전 불투명 + 지정한 RGB.
      expect(preview.color, const Color(0xFFFF00AA));
    });

    testWidgets('8자리 hex는 알파까지 반영해 투명도 슬라이더가 따라간다',
        (tester) async {
      await pumpAndOpenDialog(tester);

      await tester.enterText(find.byType(TextField), '#80112233');
      await tester.pump();

      final preview = tester
          .widgetList<ColorSwatchPreview>(find.byType(ColorSwatchPreview))
          .first;
      expect(preview.color, const Color(0x80112233));
      // 0x80/0xFF ≈ 50%
      expect(find.textContaining('50%'), findsOneWidget);
    });

    testWidgets('잘못된 hex 입력은 크래시 없이 조용히 무시된다', (tester) async {
      await pumpAndOpenDialog(tester);

      final before = tester
          .widgetList<ColorSwatchPreview>(find.byType(ColorSwatchPreview))
          .first
          .color;

      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pump();
      expect(tester.takeException(), isNull);

      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      expect(tester.takeException(), isNull);

      final after = tester
          .widgetList<ColorSwatchPreview>(find.byType(ColorSwatchPreview))
          .first
          .color;
      expect(after, before, reason: '무효 입력은 색을 바꾸지 않아야 한다');
    });

    testWidgets('SV 사각형을 드래그하면 색이 바뀐다', (tester) async {
      await pumpAndOpenDialog(tester);

      // SV사각형/Hue슬라이더는 각각 CustomPaint를 직접 자식으로 두는 GestureDetector로
      // 만들어져 있다 — 프레임워크 내부(InkWell 등)가 쓰는 GestureDetector와
      // 구분하기 위해 이 모양으로 찾는다(byType만 쓰면 오탐 위험이 있다).
      final gestureDetectors = find.byWidgetPredicate(
          (w) => w is GestureDetector && w.child is CustomPaint);
      // 다이얼로그 안 2개: [0]=SV사각형, [1]=Hue슬라이더(빌드 순서 그대로).
      expect(gestureDetectors, findsNWidgets(2));

      final svRect = tester.getRect(gestureDetectors.at(0));
      final before = tester
          .widgetList<ColorSwatchPreview>(find.byType(ColorSwatchPreview))
          .first
          .color;

      final gesture = await tester.startGesture(svRect.topLeft + const Offset(5, 5));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      final after = tester
          .widgetList<ColorSwatchPreview>(find.byType(ColorSwatchPreview))
          .first
          .color;
      expect(after, isNot(before));
    });

    testWidgets('Hue 슬라이더를 드래그하면 색상(hue)이 바뀐다', (tester) async {
      await pumpAndOpenDialog(tester);

      final gestureDetectors = find.byWidgetPredicate(
          (w) => w is GestureDetector && w.child is CustomPaint);
      final hueRect = tester.getRect(gestureDetectors.at(1));
      final before = tester
          .widgetList<ColorSwatchPreview>(find.byType(ColorSwatchPreview))
          .first
          .color;

      // 채도가 있는 상태여야 hue 변화가 RGB에 드러난다 — 먼저 hex로 채도 있는
      // 색을 만들어둔다.
      await tester.enterText(find.byType(TextField), '#FF0000');
      await tester.pump();

      final gesture = await tester.startGesture(
        Offset(hueRect.left + hueRect.width * 0.5, hueRect.center.dy),
      );
      await tester.pump();
      await gesture.up();
      await tester.pump();

      final after = tester
          .widgetList<ColorSwatchPreview>(find.byType(ColorSwatchPreview))
          .first
          .color;
      expect(after, isNot(before));
      expect(after, isNot(const Color(0xFFFF0000)));
    });

    testWidgets('투명도 슬라이더를 낮추면 미리보기 알파가 낮아진다', (tester) async {
      await pumpAndOpenDialog(tester);

      final sliderRect = tester.getRect(find.byType(Slider));
      // 슬라이더 왼쪽 끝 근처를 탭해 값을 0에 가깝게 낮춘다.
      await tester.tapAt(Offset(sliderRect.left + 2, sliderRect.center.dy));
      await tester.pump();

      final preview = tester
          .widgetList<ColorSwatchPreview>(find.byType(ColorSwatchPreview))
          .first;
      expect(preview.color.a, lessThan(0.2));
    });

    testWidgets('취소를 누르면 null을 반환한다', (tester) async {
      int? result = -1; // sentinel: 아직 안 옴
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showColorPickerDialog(
                  context: context,
                  initialColor: initialColor,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.byType(ElevatedButton));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(result, isNull);
    });

    testWidgets('적용을 누르면 현재 선택된 색(알파 포함)을 반환한다', (tester) async {
      int? result;
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showColorPickerDialog(
                  context: context,
                  initialColor: initialColor,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.byType(ElevatedButton));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '#00FF00');
      await tester.pump();

      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      expect(result, const Color(0xFF00FF00).toARGB32());
    });

    testWidgets('다이얼로그를 닫아도 크래시가 나지 않는다(컨트롤러 dispose 타이밍)',
        (tester) async {
      await pumpAndOpenDialog(tester);
      await tester.enterText(find.byType(TextField), '#123456');
      await tester.pump();

      await tester.tap(find.text('Apply'));
      // 퇴장 애니메이션이 진행되는 동안에도 예외가 없어야 한다.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('구조적 트립와이어: controller dispose 타이밍', () {
    test(
        'color_picker_dialog.dart 는 TextEditingController를 '
        'showDialog(...).whenComplete() 로 dispose하지 않는다', () {
      final source =
          File('lib/widgets/color_picker_dialog.dart').readAsStringSync();
      // 주석을 걷어낸 뒤 검사한다 — 이 안전 패턴을 설명하는 문서 주석 자체가
      // "whenComplete"라는 단어를 예시로 인용하고 있어서, 주석을 안 걷으면
      // 트립와이어가 자기 설명글에 오탐한다(lock_screen_native_contract_test.dart의
      // 동일한 이유로 도입된 관례를 그대로 따른다).
      final code = _stripComments(source);

      expect(code.contains('whenComplete'), isFalse, reason: '''
whenComplete()가 다시 등장했다.

push_notification_settings.dart 의 _PushRuleDialog 문서 주석에 기록된 실제
크래시('_dependents.isEmpty': is not true)의 원인이 정확히
`showDialog(...).whenComplete(() => controller.dispose())` 패턴이었다.
Navigator.pop()이 반환하는 popped Future는 다이얼로그의 퇴장(reverse)
애니메이션이 끝나기 전에 먼저 complete되므로, 그 콜백에서 dispose하면 아직
화면에 남아 리빌드 중인 TextField가 이미 dispose된 controller를 참조하는
경합이 생긴다. TextEditingController는 반드시 StatefulWidget의
State.dispose()에서만 정리할 것.
''');

      expect(source.contains('void dispose() {'), isTrue,
          reason: 'State.dispose() 오버라이드가 사라졌다 — 컨트롤러를 정리할 곳이 없다.');
      expect(source.contains('_hexController.dispose();'), isTrue,
          reason: '_hexController가 dispose()에서 정리되지 않는다.');
    });
  });
}
