/// 잠금화면 배경색에 맞춰 텍스트를 밝게/어둡게 자동 판정하는 순수 함수.
///
/// Android 쪽 미러: android/app/src/main/kotlin/com/henry/memora/BgContrast.kt
/// — 라이브 미리보기(이 파일을 쓰는 쪽)가 실제 잠금화면과 같은 판정을 보여주려면
/// 여기와 저기가 똑같은 공식을 써야 한다. 두 값(특히 [kLockScreenLuminanceThreshold])이
/// 갈라지지 않게 test/lock_screen_native_contract_test.dart 가 감시한다.
///
/// WCAG 상대휘도 근사 — sRGB 감마 보정은 생략하고 채널을 그대로 선형으로 사용한다
/// (0.2126*R + 0.7152*G + 0.0722*B, 채널은 0..1로 정규화).
library;

/// 이 값보다 어두우면(휘도가 낮으면) "다크 팔레트"로 판정해 밝은(흰색 계열)
/// 텍스트를 쓴다. BgContrast.LUMINANCE_THRESHOLD와 반드시 같은 값이어야 한다.
const double kLockScreenLuminanceThreshold = 0.55;

/// ARGB int에서 알파를 무시하고 상대휘도(0..1)를 구한다.
double lockScreenRelativeLuminance(int argb) {
  final r = (argb >> 16) & 0xFF;
  final g = (argb >> 8) & 0xFF;
  final b = argb & 0xFF;
  return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0;
}

/// true면 배경이 어둡다 → 밝은(흰색 계열) 텍스트를 써야 한다.
bool isDarkPalette(int bgColor) =>
    lockScreenRelativeLuminance(bgColor) < kLockScreenLuminanceThreshold;
