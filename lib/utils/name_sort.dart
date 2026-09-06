/// 앱 전체가 쓰는 "이름순" 비교 규칙.
///
/// 기준은 잠금화면 네이티브가 쓰는 `java.text.Collator`(SECONDARY 강도 = 대소문자
/// 무시)다. Dart에는 로케일 콜레이션이 없으므로 그 결과를 실질적으로 재현한다:
/// 먼저 소문자로 접어 비교하고, 그래도 같으면 원문으로 갈라 순서를 고정한다.
///
/// 한글 음절(U+AC00~U+D7A3)은 코드포인트 순서가 곧 가나다 순서라 접기와 무관하게
/// Collator와 같은 결과가 나온다. 영문은 접기 덕에 대소문자를 섞어도 사전 순으로
/// 붙는다 — 예전엔 카드 목록만 SQL `question ASC`(바이트 순)를 써서 `Apple`,
/// `Zebra`, `apple` 처럼 대문자가 전부 앞에 몰렸고, 같은 덱을 잠금화면에서 보면
/// 순서가 달랐다.
///
/// SQL 쪽 짝은 `question COLLATE NOCASE ASC, question ASC`다(같은 규칙).
int compareNamesForSort(String a, String b) {
  final folded = a.toLowerCase().compareTo(b.toLowerCase());
  return folded != 0 ? folded : a.compareTo(b);
}
