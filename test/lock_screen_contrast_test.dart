import 'package:flutter_test/flutter_test.dart';
import 'package:memora/services/lock_screen_contrast.dart';

void main() {
  group('lock_screen_contrast', () {
    // ─────────────────────────────────────────────────────────
    // 회귀 기준: 오늘의 하드코딩 팔레트를 무너뜨리지 않는지
    // ─────────────────────────────────────────────────────────

    test('기본 배경색(0xFF1A1A2E)은 다크 팔레트여야 한다', () {
      expect(isDarkPalette(0xFF1A1A2E), isTrue, reason: '''
기본 배경색이 다크 팔레트로 판정되지 않는다. 이 판정이 뒤집히면 라이브
미리보기가 기존 사용자들이 보던 것과 다른 텍스트 색을 보여준다.
''');
    });

    test('6개 내장 프리셋 전부 다크 팔레트여야 한다', () {
      const presets = [
        0xFF1A1A2E,
        0xFF16213E,
        0xFF0F3460,
        0xFF1A1A1A,
        0xFF2D132C,
        0xFF1B1B2F,
      ];
      for (final preset in presets) {
        expect(isDarkPalette(preset), isTrue,
            reason: 'preset=0x${preset.toRadixString(16)}');
      }
    });

    // ─────────────────────────────────────────────────────────
    // 극단값
    // ─────────────────────────────────────────────────────────

    test('완전 검정은 다크 팔레트, 상대휘도는 0', () {
      expect(isDarkPalette(0xFF000000), isTrue);
      expect(lockScreenRelativeLuminance(0xFF000000), closeTo(0.0, 1e-9));
    });

    test('완전 흰색은 다크 팔레트가 아니고, 상대휘도는 1', () {
      expect(isDarkPalette(0xFFFFFFFF), isFalse);
      expect(lockScreenRelativeLuminance(0xFFFFFFFF), closeTo(1.0, 1e-9));
    });

    // ─────────────────────────────────────────────────────────
    // 실사용 예시 — 밝은 커스텀 배경
    // ─────────────────────────────────────────────────────────

    test('밝은 커스텀 배경(0xFFF5F5F0)은 다크 팔레트가 아니어야 한다', () {
      expect(isDarkPalette(0xFFF5F5F0), isFalse);
    });

    // ─────────────────────────────────────────────────────────
    // 경계값 — threshold(0.55) 바로 위/아래의 무채색
    // ─────────────────────────────────────────────────────────

    test('임계값 바로 아래(회색 140) 는 다크 팔레트', () {
      const gray140 = 0xFF000000 | (140 << 16) | (140 << 8) | 140;
      expect(lockScreenRelativeLuminance(gray140),
          lessThan(kLockScreenLuminanceThreshold));
      expect(isDarkPalette(gray140), isTrue);
    });

    test('임계값 바로 위(회색 141) 는 다크 팔레트가 아님', () {
      const gray141 = 0xFF000000 | (141 << 16) | (141 << 8) | 141;
      expect(lockScreenRelativeLuminance(gray141),
          greaterThanOrEqualTo(kLockScreenLuminanceThreshold));
      expect(isDarkPalette(gray141), isFalse);
    });

    // ─────────────────────────────────────────────────────────
    // 알파 채널은 판정에 영향을 주지 않는다(RGB만 본다)
    // ─────────────────────────────────────────────────────────

    test('알파 채널은 무시된다', () {
      const opaque = 0xFF1A1A2E;
      const translucent = 0x331A1A2E;
      expect(
        lockScreenRelativeLuminance(opaque),
        closeTo(lockScreenRelativeLuminance(translucent), 1e-9),
      );
    });
  });
}
