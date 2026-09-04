// 잠금화면 배경 라이브 미리보기(lib/widgets/lock_screen_preview.dart) 검증.
//
// 2라운드 대적감사(2026-09-04)에서 발견한 테스트 커버리지 공백을 메운다 —
// 색상 피커는 17개 테스트가 있는데, 그 결과를 종합해서 보여주는 이 위젯은
// 하나도 없었다. "auto/light/dark 세 모드가 실제로 텍스트 색을 바꾸는지"와
// "이미지 경로가 없으면 이미지 레이어가 아예 안 그려지는지"를 검증한다.
//
// ⚠️ 이미지가 *있을 때*의 Opacity/스크림 합성 자체는 여기서 검증하지 않는다.
// Image.file은 실제 파일 I/O+코덱 디코딩을 필요로 하는데, 이 프로젝트의
// `flutter test` 환경에서 실제 파일(유효한 최소 PNG로도)을 Image.file에
// 물리면 `tester.runAsync()`로 감싸도 디코딩이 끝나지 않고 걸렸다(실측:
// 10분 타임아웃 반복 재현, 텍스트 대비 테스트들과 "이미지 없음" 테스트는
// 문제없이 즉시 통과). 앱 버그가 아니라 이 환경의 Image.file 위젯테스트
// 인프라 문제로 판단 — 해당 경로(이미지+투명도+스크림 합성)는 이미 Stage 3
// 세션에서 실기기(SM-T970)로 스크린샷 확인됐으므로, 여기선 무리하게 파고들지
// 않고 안전하게 검증 가능한 범위만 커버한다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memora/l10n/app_localizations.dart';
import 'package:memora/widgets/lock_screen_preview.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );

  Color? textColorOf(WidgetTester tester, String text) {
    final widget = tester.widget<Text>(find.text(text));
    return widget.style?.color;
  }

  group('LockScreenPreview — 텍스트 대비 모드', () {
    // lib/services/lock_screen_contrast.dart 의 실제 임계값(0.55)과 기본
    // 배경색(0xFF1A1A2E, 휘도 ~0.03)을 그대로 재사용 — 네이티브 회귀 기준과
    // 같은 값이어야 이 테스트가 의미 있다.
    const darkDefaultBg = 0xFF1A1A2E;
    const brightBg = 0xFFFFFFFF;
    const lightText = Color(0xFFF5F5F5);
    const darkText = Color(0xFF1A1A1A);

    testWidgets('auto 모드 + 어두운 기본 배경 → 밝은(흰색) 텍스트', (tester) async {
      await tester.pumpWidget(
        wrap(
          const LockScreenPreview(bgColor: darkDefaultBg, bgTextMode: 'auto'),
        ),
      );
      expect(textColorOf(tester, 'What is the capital of France?'), lightText);
    });

    testWidgets('auto 모드 + 밝은 배경 → 어두운 텍스트로 자동 전환', (tester) async {
      await tester.pumpWidget(
        wrap(const LockScreenPreview(bgColor: brightBg, bgTextMode: 'auto')),
      );
      expect(textColorOf(tester, 'What is the capital of France?'), darkText);
    });

    testWidgets('light 강제 모드 → 배경이 어두워도 항상 어두운 텍스트', (tester) async {
      await tester.pumpWidget(
        wrap(
          const LockScreenPreview(bgColor: darkDefaultBg, bgTextMode: 'light'),
        ),
      );
      expect(textColorOf(tester, 'What is the capital of France?'), darkText);
    });

    testWidgets('dark 강제 모드 → 배경이 밝아도 항상 밝은 텍스트', (tester) async {
      await tester.pumpWidget(
        wrap(const LockScreenPreview(bgColor: brightBg, bgTextMode: 'dark')),
      );
      expect(textColorOf(tester, 'What is the capital of France?'), lightText);
    });

    testWidgets('QUESTION/ANSWER 샘플 텍스트가 로케일 문자열로 렌더된다', (tester) async {
      await tester.pumpWidget(
        wrap(
          const LockScreenPreview(bgColor: darkDefaultBg, bgTextMode: 'auto'),
        ),
      );
      expect(find.text('QUESTION'), findsOneWidget);
      expect(find.text('ANSWER'), findsOneWidget);
      expect(find.text('What is the capital of France?'), findsOneWidget);
      expect(find.text('Paris'), findsOneWidget);
    });
  });

  group('LockScreenPreview — 배경 이미지 레이어', () {
    const darkDefaultBg = 0xFF1A1A2E;

    testWidgets('이미지 경로가 비어있으면 Image 위젯이 없다(단색만)', (tester) async {
      await tester.pumpWidget(
        wrap(
          const LockScreenPreview(
            bgColor: darkDefaultBg,
            bgTextMode: 'auto',
            bgImagePath: '',
          ),
        ),
      );
      expect(find.byType(Image), findsNothing);
    });
  });
}
