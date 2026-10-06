// 폴더 아이콘 규칙(lib/utils/folder_icons.dart) 검증.
//
// 1. 24개 키→아이콘 표(`folderIcons`)는 없앴다(사용자 요청 2026-10-06). 예전에 저장된 키는
//    DB/.mra에 그대로 남지만 그릴 때는 전부 기본 아이콘이다 — 24개 옛 키를 이 파일에 못박아
//    "표가 되살아나 키가 다시 다른 그림으로 그려지는" 일을 막는다.
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
  group('예전 아이콘 표는 없다', () {
    // 예전 24개 키(저장된 데이터에는 남아 있을 수 있다). 지금은 어느 것도 고유한 그림이 없다.
    const legacyKeys = <String>[
      'book', 'language', 'star', 'heart', 'school', 'science', 'music', 'work', //
      'idea', 'flag', 'bookmark', 'math', 'code', 'globe', 'mind', 'history', //
      'art', 'sports', 'travel', 'medical', 'pets', 'food', 'chat', 'home',
    ];

    test('옛 키 24개 전부 기본 폴더 아이콘이다(묶음이면 folder_special)', () {
      expect(legacyKeys.length, 24);
      expect(legacyKeys.toSet().length, 24);
      for (final key in legacyKeys) {
        expect(folderIconData(key, isBundle: false), Icons.folder,
            reason: '옛 키 "$key"가 기본 아이콘이 아니다 — 표가 되살아났는가');
        expect(folderIconData(key, isBundle: true), Icons.folder_special,
            reason: '옛 키 "$key"가 묶음 기본 아이콘이 아니다');
      }
    });

    test('lib 소스에 folderIcons 표나 folderIconName 도우미가 없다', () {
      final offenders = <String>[];
      final pattern = RegExp(r'(^|[^A-Za-z0-9_$])(folderIcons\b|folderIconName\w*)');
      final files = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();
      expect(files.length, greaterThan(20));
      for (final f in files) {
        if (pattern.hasMatch(_stripComments(f.readAsStringSync()))) {
          offenders.add(f.path);
        }
      }
      expect(offenders, isEmpty,
          reason: '24개 아이콘 표·이름 도우미가 되살아났다: $offenders');
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

    test('예전 표의 키("star")도 묶음 여부에 맞는 기본 아이콘', () {
      expect(folderIconData('star', isBundle: false), Icons.folder);
      expect(folderIconData('star', isBundle: true), Icons.folder_special);
    });

    test('글자 아이콘("t:…")은 키가 아니므로 기본 아이콘 — 글자는 FolderIconView가 그린다', () {
      // 키만 아는 빌드·위젯도 글자 아이콘 폴더를 기본 아이콘으로 안전하게 그려야 한다.
      expect(folderIconData('t:\u{1F1EE}\u{1F1F1}', isBundle: false), Icons.folder);
      expect(folderIconData('t:\u05D0', isBundle: true), Icons.folder_special);
      expect(folderIconData('t:en', isBundle: false), Icons.folder);
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
