/// 앱 전체가 쓰는 "이름순" 비교 규칙.
///
/// 짝이 되는 SQL은 `question COLLATE NOCASE ASC, question ASC`다. 두 규칙은 **정확히
/// 같은 순서**를 내야 한다 — 그래서 여기서도 SQLite의 `NOCASE`와 똑같이 ASCII A~Z만
/// 접는다. `String.toLowerCase()`는 유니코드 전체를 접어서, 예컨대 켈빈 기호(U+212A)를
/// 'k'로 바꾸고 'É'를 'é'로 바꾼다. SQLite는 둘 다 그대로 두므로, 유니코드 접기를 쓰면
/// 같은 이름이 화면마다 다른 자리에 놓인다(리뷰 A-01에서 실측).
///
/// 접었을 때 같으면 원문으로 갈라 순서를 고정한다(전순서 보장).
///
/// 잠금화면 네이티브는 `java.text.Collator`(SECONDARY)를 쓴다. 한글과 순수 ASCII
/// 영문에서는 세 규칙이 모두 같은 결과를 낸다 — 한글 음절은 코드포인트 순서가 곧
/// 가나다 순서이고, 영문은 대소문자만 다르기 때문이다. 악센트가 붙은 라틴 문자처럼
/// 진짜 언어별 콜레이션이 필요한 입력에서는 Collator만 다른 답을 낸다. Dart에는
/// 로케일 콜레이션이 없어 그 차이는 그대로 둔다.
int compareNamesForSort(String a, String b) {
  final folded = _foldAscii(a).compareTo(_foldAscii(b));
  return folded != 0 ? folded : a.compareTo(b);
}

/// ASCII 대문자만 소문자로 내린다. 나머지 코드포인트는 손대지 않는다
/// (= SQLite `NOCASE`의 정의).
String _foldAscii(String s) {
  StringBuffer? buf;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c >= 0x41 && c <= 0x5A) {
      buf ??= StringBuffer(s.substring(0, i));
      buf.writeCharCode(c + 0x20);
    } else {
      buf?.writeCharCode(c);
    }
  }
  return buf?.toString() ?? s;
}
