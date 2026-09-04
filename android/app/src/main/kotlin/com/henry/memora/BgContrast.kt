package com.henry.memora

/**
 * 잠금화면 배경색에 맞춰 텍스트를 밝게/어둡게 자동 판정하는 순수 함수.
 * Android 의존성 0 — JVM 유닛테스트 대상(BgContrastTest.kt).
 *
 * Dart 쪽 미러: lib/services/lock_screen_contrast.dart — 라이브 미리보기가 여기와
 * 똑같은 공식을 써야 실제 잠금화면과 어긋나지 않는다. 두 값(특히
 * [LUMINANCE_THRESHOLD])이 갈라지지 않게 test/lock_screen_native_contract_test.dart
 * 가 감시한다.
 *
 * WCAG 상대휘도 근사 — sRGB 감마 보정은 생략하고 채널을 그대로 선형으로 사용한다
 * (0.2126*R + 0.7152*G + 0.0722*B, 채널은 0..1로 정규화). 목적이 픽셀 단위 WCAG
 * 준수가 아니라 "얼추 맞는 대비"이므로 이 근사로 충분하다.
 */
object BgContrast {
    /**
     * 이 값보다 어두우면(휘도가 낮으면) "다크 팔레트"로 판정해 밝은(흰색 계열)
     * 텍스트/장식을 쓴다. 기본 배경색(0xFF1A1A2E)의 휘도는 이 값보다 한참 낮아야
     * 한다 — 그래야 "auto"가 오늘의 하드코딩된 다크 팔레트와 동일한 결과를 낸다
     * (회귀 기준, BgContrastTest 참고).
     */
    const val LUMINANCE_THRESHOLD = 0.55

    /**
     * ARGB int에서 알파를 무시하고 상대휘도(0..1)를 구한다. bgColor의 알파는
     * 배경 위에 실제로 뭐가 깔리는지(런처 배경 등)에 따라 최종 표시 색이 달라져
     * 여기서는 알 수 없으므로, RGB 채널만으로 근사한다.
     */
    fun relativeLuminance(argb: Int): Double {
        val r = (argb shr 16) and 0xFF
        val g = (argb shr 8) and 0xFF
        val b = argb and 0xFF
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
    }

    /** true면 배경이 어둡다 → 밝은(흰색 계열) 텍스트/장식을 써야 한다. */
    fun isDarkPalette(bgColor: Int): Boolean =
        relativeLuminance(bgColor) < LUMINANCE_THRESHOLD
}
