// 폴더 아이콘 표(lib/utils/folder_icons.dart) 검증.
//
// 1. 키 목록·순서·키→아이콘 매핑 고정: 키는 DB/.mra에 저장되는 약속이라 이름을 바꾸거나
//    지우면 이미 저장된 폴더가 기본 아이콘으로 돌아간다(추가만 허용). 순서는 선택
//    창에 보이는 순서.
// 2. 폴백: null/빈 문자열/모르는 키 → 폴더·묶음 폴더 기본 아이콘. 색 null → 테마 primary.
// 3. 구조적 트립와이어: lib 어디에도 코드포인트로 직접 만든 아이콘 객체가 없어야 한다.
//    릴리스 빌드는 아이콘 폰트를 트리 셰이킹하는데, `const Icons.*`가 아닌 동적 아이콘이
//    있으면 셰이킹이 막혀 빌드가 실패한다(debug 빌드·테스트에서는 안 드러난다).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memora/utils/folder_icons.dart';

/// 주석을 걷어낸 소스를 돌려준다(문자열 리터럴 안의 `//`는 건드리지 않음).
/// test/widgets/color_picker_dialog_test.dart 의 동일한 헬퍼와 같은 방식 — 이게 없으면
/// 트립와이어가 "주석 속 예시"를 실제 코드로 착각한다.
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
      continue;
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

/// 아이콘 객체를 코드포인트로 직접 만드는 생성자 호출. 식별자 경계를 보는 이유:
/// `folderIconData(`처럼 이름 끝이 같은 함수 호출은 잡으면 안 된다.
final RegExp _dynamicIconCtor = RegExp(r'(^|[^A-Za-z0-9_$])IconData\s*\(');

void main() {
  group('folderIcons 표', () {
    // 키와 순서를 이 목록으로 못박는다. 바꾸고 싶으면 저장된 데이터가 깨지는지부터
    // 따질 것 — 지우거나 이름을 바꾸지 말고 추가만.
    const expected = <(String, IconData)>[
      ('book', Icons.menu_book),
      ('language', Icons.translate),
      ('star', Icons.star),
      ('heart', Icons.favorite),
      ('school', Icons.school),
      ('science', Icons.science),
      ('music', Icons.music_note),
      ('work', Icons.work),
      ('idea', Icons.lightbulb),
      ('flag', Icons.flag),
      ('bookmark', Icons.bookmark),
      ('math', Icons.calculate),
      ('code', Icons.code),
      ('globe', Icons.public),
      ('mind', Icons.psychology),
      ('history', Icons.history_edu),
      ('art', Icons.palette),
      ('sports', Icons.sports_soccer),
      ('travel', Icons.flight),
      ('medical', Icons.medical_services),
      ('pets', Icons.pets),
      ('food', Icons.restaurant),
      ('chat', Icons.chat_bubble),
      ('home', Icons.home),
    ];

    test('키 24개가 이 순서 그대로 있다', () {
      expect(folderIcons.keys.toList(), [for (final e in expected) e.$1]);
      expect(folderIcons.length, 24);
    });

    test('각 키가 가리키는 아이콘이 고정돼 있다', () {
      for (final (key, icon) in expected) {
        expect(folderIcons[key], icon, reason: '키 "$key"의 아이콘이 바뀌었다');
      }
    });

    test('키는 소문자/밑줄만 쓴다(DB·JSON에 그대로 저장되는 식별자)', () {
      final pattern = RegExp(r'^[a-z_]+$');
      for (final key in folderIcons.keys) {
        expect(pattern.hasMatch(key), isTrue, reason: '키 "$key"가 규칙에 안 맞는다');
      }
    });

    test('서로 다른 키가 같은 아이콘을 가리키지 않는다(선택 창에서 구별이 안 된다)', () {
      expect(folderIcons.values.toSet().length, folderIcons.length);
    });

    test('기본 폴더/묶음 폴더 아이콘은 표에 없다(표는 "고르는" 아이콘만)', () {
      expect(folderIcons.values, isNot(contains(Icons.folder)));
      expect(folderIcons.values, isNot(contains(Icons.folder_special)));
    });
  });

  group('folderIconData 폴백', () {
    test('null/빈 문자열/모르는 키는 기본 폴더 아이콘', () {
      expect(folderIconData(null, isBundle: false), Icons.folder);
      expect(folderIconData('', isBundle: false), Icons.folder);
      expect(folderIconData('no_such', isBundle: false), Icons.folder);
    });

    test('묶음 폴더는 기본이 folder_special', () {
      expect(folderIconData(null, isBundle: true), Icons.folder_special);
      expect(folderIconData('', isBundle: true), Icons.folder_special);
      expect(folderIconData('no_such', isBundle: true), Icons.folder_special);
    });

    test('아는 키는 묶음 여부와 무관하게 그 아이콘', () {
      expect(folderIconData('star', isBundle: false), Icons.star);
      expect(folderIconData('star', isBundle: true), Icons.star);
    });

    test('키 대소문자는 구분한다("Star"는 모르는 키)', () {
      expect(folderIconData('Star', isBundle: false), Icons.folder);
    });
  });

  group('folderIconColor', () {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFFFF6B6B));

    test('null이면 테마 primary', () {
      expect(folderIconColor(null, scheme), scheme.primary);
    });

    test('값이 있으면 그 색 그대로(테마 무관)', () {
      expect(folderIconColor(0xFF2196F3, scheme), const Color(0xFF2196F3));
      final dark = ColorScheme.fromSeed(
          seedColor: const Color(0xFFFF6B6B), brightness: Brightness.dark);
      expect(folderIconColor(0xFF2196F3, dark), const Color(0xFF2196F3));
    });

    test('알파가 0이거나 반투명으로 저장돼 있어도 불투명하게 그린다(안 보이는 아이콘 방지)', () {
      // 선택 창은 항상 불투명 값만 저장하지만 다른 경로(가져온 데이터 등)의 값은 알파가
      // 섞여 있을 수 있다 — Color(argb)를 그대로 쓰면 알파 0이 투명한 아이콘이 된다.
      expect(folderIconColor(0x00112233, scheme), const Color(0xFF112233));
      expect(folderIconColor(0x80112233, scheme), const Color(0xFF112233));
      expect(folderIconColor(0x00112233, scheme).a, 1.0);
      // 이미 불투명한 값은 그대로.
      expect(folderIconColor(0xFF112233, scheme), const Color(0xFF112233));
    });
  });

  group('구조적 트립와이어: 동적 아이콘 금지(릴리스 트리 셰이킹)', () {
    test('탐지기 자체 점검: 진짜 생성자는 잡고 함수 호출·주석은 안 잡는다', () {
      bool hits(String src) => _dynamicIconCtor.hasMatch(_stripComments(src));
      expect(hits("const x = IconData(0xe000, fontFamily: 'MaterialIcons');"),
          isTrue);
      expect(hits('final x = const IconData (0xe000);'), isTrue);
      expect(hits('final x = folderIconData(key, isBundle: false);'), isFalse);
      expect(hits('// IconData(0xe000) 같은 건 쓰지 말 것\nfinal y = 1;'),
          isFalse);
      expect(hits('/* IconData(0xe000) */ final y = 1;'), isFalse);
    });

    test('lib/**/*.dart 어디에도 코드포인트로 만든 아이콘 객체가 없다', () {
      final files = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();
      // 스캔이 아무 파일도 못 보고 초록이 되는 일을 막는다.
      expect(files.length, greaterThan(20));
      expect(
        files.any((f) => f.path.replaceAll('\\', '/').endsWith('utils/folder_icons.dart')),
        isTrue,
      );

      final offenders = <String>[];
      for (final f in files) {
        final code = _stripComments(f.readAsStringSync());
        if (_dynamicIconCtor.hasMatch(code)) offenders.add(f.path);
      }
      expect(offenders, isEmpty, reason: '''
코드포인트로 직접 만든 아이콘 객체가 있다: $offenders

릴리스 빌드(flutter build apk --release)는 아이콘 폰트를 트리 셰이킹하는데,
const Icons.* 가 아닌 아이콘 객체가 있으면 셰이킹이 막혀 빌드가 실패한다.
debug 빌드와 테스트에서는 드러나지 않는다. lib/utils/folder_icons.dart의 표에
Icons.* 상수로 추가할 것.
''');
    });
  });
}
