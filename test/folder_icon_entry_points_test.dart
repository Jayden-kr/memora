// 폴더 아이콘 기능의 "진입점"이 조용히 사라지는 회귀를 막는 소스 스캔 트립와이어.
//
// 아이콘 선택 다이얼로그(folder_icon_dialog_test)와 DB 저장(database_helper_test)은 각각
// 따로 검증되지만, 그 둘을 사용자 화면에 이어 붙이는 자리 — 홈 화면 팝업 메뉴 항목, 묶음
// 안 목록의 선택 앱바 버튼, 폴더 행/묶음 편집 화면의 아이콘 그리기 — 는 위젯 테스트로
// 띄우기 어렵다(홈/묶음 화면은 sqlite와 플랫폼 채널에 물려 있어 testWidgets에서 교착한다).
// 그래서 정리/리팩터링 중에 메뉴 항목 하나, 버튼 하나, 호출 한 줄이 빠져도 모든 테스트가
// 초록인 채로 "아이콘을 바꿀 방법이 없는 앱"이 나갈 수 있다. 소스를 텍스트로 읽어 그 이음새만
// 확인한다(lock_screen_native_contract_test.dart와 같은 방식).
//
// 주석을 걷어낸 소스만 본다 — 안 그러면 "주석 처리된 코드"를 살아 있는 코드로 착각한다.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 주석을 걷어낸 소스를 돌려준다(문자열 리터럴 안의 `//`는 건드리지 않음).
/// test/lock_screen_native_contract_test.dart 의 동일한 헬퍼와 같은 방식.
String _stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  var quote = '';
  while (i < src.length) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';
    if (quote.isNotEmpty) {
      out.write(c);
      if (c == '\\' && i + 1 < src.length) {
        out.write(next);
        i += 2;
        continue;
      }
      if (c == quote) quote = '';
      i++;
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && next == '/') {
      while (i < src.length && src.codeUnitAt(i) != 10) {
        i++;
      }
      continue; // 개행은 다음 회차에서 그대로 기록된다
    }
    if (c == '/' && next == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
        i++;
      }
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

String _read(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue,
      reason: '$path 를 찾을 수 없다. 파일이 옮겨졌다면 이 테스트의 경로도 함께 고쳐야 한다.');
  final code = _stripComments(file.readAsStringSync());
  // 스캔이 빈 문자열이나 주석만 보고 초록이 되는 일을 막는다.
  expect(code.length, greaterThan(500), reason: '$path 의 코드가 비정상적으로 짧다');
  expect(code.contains('///'), isFalse, reason: '$path 의 문서 주석이 안 걷혔다');
  return code;
}

/// [open]에 있는 여는 괄호(`{` 또는 `(`)부터 짝이 맞는 닫는 괄호까지(포함)의 텍스트.
String _balanced(String code, int open) {
  final openCh = code[open];
  final closeCh = switch (openCh) {
    '{' => '}',
    '(' => ')',
    _ => throw ArgumentError('지원하지 않는 괄호: $openCh'),
  };
  var depth = 0;
  for (var i = open; i < code.length; i++) {
    final c = code[i];
    if (c == openCh) {
      depth++;
    } else if (c == closeCh) {
      depth--;
      if (depth == 0) return code.substring(open, i + 1);
    }
  }
  fail('$openCh 의 짝이 맞는 $closeCh 를 못 찾았다');
}

/// [signature](예: `Future<void> _foo()`)로 정의된 메서드의 본문(`{…}`).
/// 정의가 정확히 하나여야 한다 — 이름이 바뀌었거나 둘이 됐으면 테스트도 함께 고칠 것.
String _methodBody(String code, String signature) {
  final first = code.indexOf(signature);
  expect(first, greaterThanOrEqualTo(0),
      reason: '`$signature` 정의를 찾지 못했다. 이름이 바뀌었다면 이 테스트도 함께 고칠 것.');
  expect(code.indexOf(signature, first + 1), -1,
      reason: '`$signature` 정의가 둘 이상이다 — 어느 쪽을 보는지 모호하다.');
  final open = code.indexOf('{', first);
  return _balanced(code, open);
}

/// 식별자 경계를 보는 호출 탐지: `folderIconData(`는 잡고 `myfolderIconData(`는 안 잡는다.
bool _calls(String code, String name) =>
    RegExp('(^|[^A-Za-z0-9_\$])$name\\s*\\(').hasMatch(code);

void main() {
  group('탐지기 자체 점검', () {
    test('주석 처리된 호출은 안 잡고, 본문 추출은 중괄호 짝을 맞추며, 다른 함수 본문은 안 섞인다', () {
      final code = _stripComments('''
class A {
  Future<void> _go() async {
    if (x) { foo(); }
    // updateFolderIcon(1);
    /* updateFolderIcon(2); */
  }
  void _other() { updateFolderIcon(3); }
}
''');
      final body = _methodBody(code, 'Future<void> _go()');
      expect(body.contains('foo()'), isTrue);
      expect(_calls(body, 'updateFolderIcon'), isFalse,
          reason: '주석 속 호출이나 다른 함수의 호출을 잡았다');
      expect(_calls(code, 'updateFolderIcon'), isTrue); // 진짜 호출은 잡는다
      expect(_calls('final x = myupdateFolderIcon(1);', 'updateFolderIcon'),
          isFalse);
    });
  });

  group('홈 화면(일반/묶음 폴더 선택) → 아이콘 변경', () {
    late String home;
    late String homeState;

    setUpAll(() {
      home = _read('lib/screens/home_screen.dart');
      final start = home.indexOf('class _HomeScreenState');
      final end = home.indexOf('class _BundleChildListScreen ');
      expect(start, greaterThanOrEqualTo(0), reason: '_HomeScreenState를 못 찾았다');
      expect(end, greaterThan(start), reason: '_BundleChildListScreen을 못 찾았다');
      homeState = home.substring(start, end);
    });

    test("팝업 메뉴에 value: 'icon' 항목이 있다", () {
      expect(
        RegExp(r"PopupMenuItem\b[^(]*\(\s*value:\s*'icon'").hasMatch(homeState),
        isTrue,
        reason: '''
홈 화면 선택 앱바의 팝업 메뉴에서 아이콘 변경 항목(PopupMenuItem(value: 'icon'))이 사라졌다.
일반 폴더·묶음 폴더의 아이콘을 바꿀 길이 없어진다(항목은 선택이 1개일 때만 나온다).
''');
    });

    test("팝업 onSelected가 'icon'일 때 _changeSelectedFolderIcon()을 부른다", () {
      var found = false;
      var from = 0;
      while (true) {
        final at = homeState.indexOf('onSelected:', from);
        if (at < 0) break;
        from = at + 1;
        final open = homeState.indexOf('{', at);
        if (open < 0) continue;
        final body = _balanced(homeState, open);
        if (RegExp(r"value\s*==\s*'icon'\s*\)\s*\{?\s*_changeSelectedFolderIcon\(\)")
            .hasMatch(body)) {
          found = true;
        }
      }
      expect(found, isTrue, reason: '''
팝업 메뉴의 onSelected 핸들러가 value == 'icon'일 때 _changeSelectedFolderIcon()을 부르지
않는다 — 메뉴 항목은 보이는데 눌러도 아무 일도 안 일어난다.
''');
    });

    test('_changeSelectedFolderIcon이 다이얼로그를 띄우고 updateFolderIcon으로 저장한다', () {
      final body =
          _methodBody(homeState, 'Future<void> _changeSelectedFolderIcon()');
      expect(_calls(body, 'showFolderIconDialog'), isTrue,
          reason: '아이콘 선택 다이얼로그를 띄우지 않는다');
      expect(_calls(body, 'updateFolderIcon'), isTrue, reason: '''
고른 아이콘을 DB에 저장하지 않는다 — DatabaseHelper.updateFolderIcon 호출이 사라졌다.
(아이콘·색 두 열만 UPDATE하는 전용 메서드여야 한다. 폴더 스냅샷을 통째로 되쓰지 말 것.)
''');
    });
  });

  group('묶음 안 폴더 목록(_BundleChildListScreen) → 아이콘 변경', () {
    late String region;

    setUpAll(() {
      final home = _read('lib/screens/home_screen.dart');
      final start = home.indexOf('class _BundleChildListScreenState');
      expect(start, greaterThanOrEqualTo(0),
          reason: '_BundleChildListScreenState를 못 찾았다');
      region = home.substring(start);
    });

    test('선택 앱바에 Icons.palette_outlined IconButton이 있고 _changeIconSelected를 부른다', () {
      final at = region.indexOf('Icons.palette_outlined');
      expect(at, greaterThanOrEqualTo(0), reason: '''
묶음 안 폴더 목록의 선택 앱바에서 아이콘 변경 버튼(Icons.palette_outlined)이 사라졌다.
묶음 안 폴더의 아이콘을 바꿀 길이 없어진다.
''');
      final buttonStart = region.lastIndexOf('IconButton(', at);
      expect(buttonStart, greaterThanOrEqualTo(0),
          reason: 'palette_outlined 아이콘이 IconButton 안에 있지 않다');
      final button = _balanced(region, buttonStart + 'IconButton'.length);
      expect(buttonStart + 'IconButton'.length + button.length, greaterThan(at),
          reason: 'palette_outlined가 가장 가까운 IconButton의 안쪽이 아니다');
      expect(RegExp(r'onPressed:\s*_changeIconSelected\b').hasMatch(button),
          isTrue, reason: '''
팔레트 버튼의 onPressed가 _changeIconSelected가 아니다 — 눌러도 아이콘 변경이 안 된다.
''');
    });

    test('_changeIconSelected가 다이얼로그를 띄우고 updateFolderIcon으로 저장한다', () {
      final body = _methodBody(region, 'Future<void> _changeIconSelected()');
      expect(_calls(body, 'showFolderIconDialog'), isTrue,
          reason: '아이콘 선택 다이얼로그를 띄우지 않는다');
      expect(_calls(body, 'updateFolderIcon'), isTrue, reason: '''
고른 아이콘을 DB에 저장하지 않는다 — DatabaseHelper.updateFolderIcon 호출이 사라졌다.
''');
    });
  });

  group('저장한 아이콘을 실제로 그리는 자리', () {
    test('묶음 편집 화면(bundle_folder_screen.dart)이 folderIconData(를 쓴다', () {
      final code = _read('lib/screens/bundle_folder_screen.dart');
      expect(_calls(code, 'folderIconData'), isTrue, reason: '''
묶음 편집 화면의 폴더 목록이 folderIconData(...)로 아이콘을 그리지 않는다 — 저장된 아이콘이
이 화면에서만 기본 폴더 아이콘으로 보인다.
''');
    });

    test('폴더 행(folder_tile.dart)이 folderIconData(와 folderIconColor(를 쓴다', () {
      final code = _read('lib/widgets/folder_tile.dart');
      expect(_calls(code, 'folderIconData'), isTrue,
          reason: '폴더 행이 저장된 아이콘을 그리지 않는다');
      expect(_calls(code, 'folderIconColor'), isTrue,
          reason: '폴더 행이 저장된 아이콘 색을 쓰지 않는다');
    });
  });
}
