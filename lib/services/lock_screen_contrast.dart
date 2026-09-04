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
///
/// ⚠️ 알려진 한계(4라운드 감사, 2026-09-04): 이 함수는 [bgColor] 단색만 본다.
/// 네이티브(BgContrast.kt)는 배경 이미지+스크림까지 합성한 실제 화면 기준으로
/// `isDarkPaletteEffective()`를 써서 더 정확하게 판정하도록 고쳐졌지만, 이
/// Dart 함수(=설정화면 라이브 미리보기 [LockScreenPreview]가 쓴다)는 의도적으로
/// 그대로 남겨뒀다 — 미리보기가 실제 파일을 디코딩해 평균 밝기를 구하려면
/// 상당한 복잡도(비동기 디코딩+캐싱)가 추가되는데, 이 위젯은 애초에 "픽셀 단위
/// 일치가 목적이 아니라 방향성만 맞으면 된다"고 설계됐다(lock_screen_preview.dart
/// 문서 참고). 그 결과 "밝은 이미지를 낮은 스크림으로 올린 auto 모드"처럼 드문
/// 조합에서는 미리보기와 실제 잠금화면의 텍스트 색이 잠깐 어긋날 수 있다 —
/// 알고 있는 잔여 격차이지 놓친 게 아니다.
bool isDarkPalette(int bgColor) =>
    lockScreenRelativeLuminance(bgColor) < kLockScreenLuminanceThreshold;
