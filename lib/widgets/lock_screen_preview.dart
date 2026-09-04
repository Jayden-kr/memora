import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/lock_screen_contrast.dart';

/// 잠금화면 카드 목업을 축소해서 그리는 라이브 미리보기.
///
/// [bgColor]/[bgTextMode]를 실제 네이티브 오버레이(LockScreenService.kt의
/// applyPalette())와 정확히 같은 방식으로 해석해야 한다 — 텍스트 명/암 판정은
/// lib/services/lock_screen_contrast.dart의 [isDarkPalette]를 그대로 쓴다(네이티브
/// BgContrast.kt와 동일 공식, 계약 테스트로 감시됨).
///
/// 색만 실제 오버레이와 맞추면 되므로, QUESTION/ANSWER 라벨은 네이티브 쪽
/// (createOverlayLayout)과 마찬가지로 하드코딩된 영문 대문자를 그대로 쓴다 —
/// 실제 잠금화면도 로케일과 무관하게 항상 "QUESTION"/"ANSWER"로 뜬다.
class LockScreenPreview extends StatelessWidget {
  const LockScreenPreview({
    super.key,
    required this.bgColor,
    required this.bgTextMode,
  });

  final int bgColor;

  /// "auto" | "light" | "dark" — LockScreenService.applyPalette()와 동일 의미.
  final String bgTextMode;

  static const _coral = Color(0xFFFF6B6B);

  bool get _isDark {
    switch (bgTextMode) {
      case 'light':
        return false;
      case 'dark':
        return true;
      default:
        return isDarkPalette(bgColor);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final dark = _isDark;
    final textColor = dark ? const Color(0xFFF5F5F5) : const Color(0xFF1A1A1A);
    final overlayFaint =
        dark ? const Color(0x33FFFFFF) : const Color(0x33000000);

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        color: Color(bgColor),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 진행바 목업
            ClipRRect(
              borderRadius: BorderRadius.circular(1),
              child: SizedBox(
                height: 2,
                child: Stack(
                  children: [
                    Container(color: overlayFaint),
                    FractionallySizedBox(
                      widthFactor: 0.4,
                      child: Container(color: _coral),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'QUESTION',
              style: TextStyle(
                color: _coral,
                fontSize: 9,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              t.lockPreviewSampleQuestion,
              style: TextStyle(color: textColor, fontSize: 13),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            Container(height: 1, color: overlayFaint),
            const SizedBox(height: 12),
            Text(
              'ANSWER',
              style: TextStyle(
                color: _coral,
                fontSize: 9,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              t.lockPreviewSampleAnswer,
              style: TextStyle(color: textColor, fontSize: 13),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
