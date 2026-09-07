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
/// ⚠️ 비교는 반드시 **코드포인트** 단위로 한다(`_compareByCodepoint`), `String.compareTo`가
/// 아니다. `compareTo`는 UTF-16 **코드유닛**을 비교하는데, 서로게이트 쌍(U+10000 이상,
/// 이모지 등 대부분)의 앞쪽 유닛(0xD800~0xDBFF)이 BMP 상위 영역 문자(0xE000~0xFFFF,
/// 예: 전각 라틴·PUA·U+FFFD)보다 수치상 작아서, **실제 코드포인트로는 더 큰 문자가
/// 코드유닛 비교에서는 더 작게 취급**된다. SQLite의 BINARY collation은 UTF-8 바이트
/// 비교라 곧 진짜 코드포인트 순서와 같다 — 그래서 이 divergence는 SQL과도 어긋난다
/// (리뷰로 발견, 실측: `'😀zz'` vs `'�zz'`가 Dart `compareTo`와 SQLite에서
/// 정반대 순서로 나옴). 지금은 두 정렬이 같은 데이터에 동시에 노출되는 화면이 없어
/// 무해하지만, 코드유닛 비교를 그대로 쓰면 언젠가 또 이 문서 맨 위 문장("정확히 같은
/// 순서")이 거짓이 된다.
///
/// 잠금화면 네이티브는 `java.text.Collator`(SECONDARY)를 쓴다. 한글과 순수 ASCII
/// 영문에서는 세 규칙이 모두 같은 결과를 낸다 — 한글 음절은 코드포인트 순서가 곧
/// 가나다 순서이고, 영문은 대소문자만 다르기 때문이다. 악센트가 붙은 라틴 문자처럼
/// 진짜 언어별 콜레이션이 필요한 입력에서는 Collator만 다른 답을 낸다. Dart에는
/// 로케일 콜레이션이 없어 그 차이는 그대로 둔다.
int compareNamesForSort(String a, String b) {
  final folded = _compareByCodepoint(_foldAscii(a), _foldAscii(b));
  return folded != 0 ? folded : _compareByCodepoint(a, b);
}

/// 코드포인트(진짜 유니코드 스칼라값) 단위 사전식 비교. `String.compareTo`(UTF-16
/// 코드유닛 비교)와 달리 서로게이트 쌍을 하나의 코드포인트로 정확히 다뤄, SQLite의
/// UTF-8 바이트 비교(=코드포인트 순서)와 항상 일치한다.
int _compareByCodepoint(String a, String b) {
  final ar = a.runes.iterator;
  final br = b.runes.iterator;
  while (true) {
    final aHas = ar.moveNext();
    final bHas = br.moveNext();
    if (!aHas && !bHas) return 0;
    if (!aHas) return -1;
    if (!bHas) return 1;
    final cmp = ar.current.compareTo(br.current);
    if (cmp != 0) return cmp;
  }
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
