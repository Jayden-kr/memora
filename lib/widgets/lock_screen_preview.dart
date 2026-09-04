import 'dart:io';

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
///
/// Stage 3: [bgImagePath]가 비어있지 않으면 이미지를 배경에 얹고 그 위에 반투명
/// 검정 스크림을 덮어 네이티브(LayerDrawable: 색 + 이미지 + 스크림)를 근사한다.
/// 픽셀 단위로 똑같을 필요는 없다 — 방향성(이미지가 있다/투명도가 이렇다/스크림이
/// 이렇다)만 맞으면 된다.
class LockScreenPreview extends StatelessWidget {
  const LockScreenPreview({
    super.key,
    required this.bgColor,
    required this.bgTextMode,
    this.bgImagePath = '',
    this.bgImageAlpha = 255,
    this.bgScrimAlpha = 102,
  });

  final int bgColor;

  /// "auto" | "light" | "dark" — LockScreenService.applyPalette()와 동일 의미.
  final String bgTextMode;

  /// 절대경로. 빈 문자열 = 이미지 없음(단색 배경만).
  final String bgImagePath;

  /// 이미지 자체 불투명도 0-255.
  final int bgImageAlpha;

  /// 이미지 위에 까는 검정 스크림 불투명도 0-255.
  final int bgScrimAlpha;

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
    final overlayFaint = dark
        ? const Color(0x33FFFFFF)
        : const Color(0x33000000);

    final hasImage = bgImagePath.isNotEmpty;

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        children: [
          // 배경 레이어: 단색 → (있으면) 이미지 → (있으면) 스크림. 네이티브
          // LayerDrawable(ColorDrawable + BitmapDrawable + ColorDrawable)을 근사.
          Positioned.fill(child: Container(color: Color(bgColor))),
          if (hasImage)
            Positioned.fill(
              child: Opacity(
                opacity: (bgImageAlpha.clamp(0, 255)) / 255,
                child: Image.file(
                  File(bgImagePath),
                  fit: BoxFit.cover,
                  // 미리보기 전용 — 파일이 없거나 손상됐어도 조용히 단색으로 강등.
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ),
          if (hasImage)
            Positioned.fill(
              child: Container(
                color: Colors.black.withAlpha(bgScrimAlpha.clamp(0, 255)),
              ),
            ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
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
        ],
      ),
    );
  }
}
