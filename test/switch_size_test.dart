// 앱의 모든 토글 스위치는 같은 크기여야 한다(사용자 요청 2026-10-06): `Switch`는 항상
// `Transform.scale(scale: 0.8, child: Switch(...))`로 감싸서 `ListTile.trailing`에 둔다.
// "시간대별 폴더 자동 전환"만 `SwitchListTile`이라 전체 크기 스위치가 나왔던 게 계기다.
//
// 소스를 텍스트로 읽는 트립와이어다 — 위젯 테스트로는 "누가 SwitchListTile로 되돌렸는가"를
// 볼 수 없고(화면이 DB·플랫폼 채널을 물고 있다), 값이 아닌 코드의 모양에 관한 약속이라서다.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 주석을 걷어낸 소스(문자열 리터럴 안의 `//`는 유지). 이게 없으면 "SwitchListTile 쓰지 말 것"
/// 같은 주석이 살아있는 코드로 잡힌다.
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

/// 식별자 경계를 보는 Switch 생성자 호출: `Switch(`·`Switch.adaptive(`는 잡고
/// `SwitchListTile(`·`CupertinoSwitch(`·`mySwitch(`는 안 잡는다.
final RegExp _switchCall =
    RegExp(r'(^|[^A-Za-z0-9_$])Switch(\.adaptive)?\s*\(');
final RegExp _switchListTile = RegExp(r'(^|[^A-Za-z0-9_$])SwitchListTile\b');

/// 이 `Switch(`가 `Transform.scale(scale: 0.8, child: `로 바로 감싸져 있는가(공백 무시).
bool _wrapped(String code, int callStart) {
  final before = code.substring(0, callStart).replaceAll(RegExp(r'\s+'), '');
  return before.endsWith('Transform.scale(scale:0.8,child:');
}

/// (파일, 줄) 목록: 감싸지 않은 Switch.
List<String> unwrappedSwitches(String path, String raw) {
  final code = _stripComments(raw.replaceAll('\r\n', '\n'));
  final bad = <String>[];
  for (final m in _switchCall.allMatches(code)) {
    // 그룹1이 경계 한 글자를 먹으므로 실제 호출 시작은 m.start + group(1).length.
    final start = m.start + (m.group(1)?.length ?? 0);
    if (!_wrapped(code, start)) {
      bad.add('$path:${'\n'.allMatches(code.substring(0, start)).length + 1}');
    }
  }
  return bad;
}

List<File> _libDartFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList();

void main() {
  group('탐지기 자체 점검', () {
    test('감싼 Switch는 통과, 안 감싼 Switch·Switch.adaptive는 잡는다', () {
      expect(
          unwrappedSwitches(
              'a.dart',
              'trailing: Transform.scale(\n  scale: 0.8,\n'
                  '  child: Switch(value: v, onChanged: f),\n)'),
          isEmpty);
      expect(unwrappedSwitches('a.dart', 'trailing: Switch(value: v)'),
          hasLength(1));
      expect(
          unwrappedSwitches(
              'a.dart', 'child: Transform.scale(scale: 1.0, child: Switch(value: v))'),
          hasLength(1),
          reason: '0.8이 아닌 배율은 통과하면 안 된다');
      expect(unwrappedSwitches('a.dart', 'x = Switch.adaptive(value: v);'),
          hasLength(1));
    });

    test('SwitchListTile·CupertinoSwitch·주석 속 Switch는 Switch 호출이 아니다', () {
      expect(unwrappedSwitches('a.dart', 'SwitchListTile(value: v)'), isEmpty);
      expect(unwrappedSwitches('a.dart', 'CupertinoSwitch(value: v)'), isEmpty);
      expect(unwrappedSwitches('a.dart', '// Switch(value: v)\nfinal a = 1;'),
          isEmpty);
      expect(_switchListTile.hasMatch('SwitchListTile('), isTrue);
      expect(_switchListTile.hasMatch('final MySwitchListTile = 1;'), isFalse);
    });
  });

  group('스위치 크기 통일', () {
    test('lib 어디에도 SwitchListTile이 없다', () {
      final files = _libDartFiles();
      expect(files.length, greaterThan(20)); // 스캔이 아무것도 못 보고 초록이 되는 일 방지
      final offenders = <String>[];
      for (final f in files) {
        final code = _stripComments(f.readAsStringSync());
        if (_switchListTile.hasMatch(code)) offenders.add(f.path);
      }
      expect(offenders, isEmpty, reason: '''
SwitchListTile은 전체 크기 스위치를 그려 앱의 다른 스위치(0.8배)와 크기가 어긋난다: $offenders
ListTile(trailing: Transform.scale(scale: 0.8, child: Switch(...)))로 쓰고, 행 탭 토글이
필요하면 ListTile.onTap에 건다(lock_screen_settings.dart의 "시간대별 폴더 자동 전환" 참고).
''');
    });

    test('lib의 모든 Switch(...)가 Transform.scale(scale: 0.8, child: …)로 감싸여 있다', () {
      final offenders = <String>[];
      var total = 0;
      for (final f in _libDartFiles()) {
        final raw = f.readAsStringSync();
        total += _switchCall.allMatches(_stripComments(raw)).length;
        offenders.addAll(unwrappedSwitches(f.path, raw));
      }
      // 지금 앱에는 스위치가 5개다(잠금화면 2, 푸시 1, 설정 2). 스캔이 못 보고 초록이 되거나
      // 스위치가 조용히 사라지는 일을 막는다 — 스위치를 일부러 늘리고 줄이면 이 숫자를 고칠 것.
      expect(total, 5, reason: 'lib의 Switch 호출 수가 5가 아니다 — 스캔이 깨졌거나 스위치가 바뀌었다');
      expect(offenders, isEmpty, reason: '''
0.8배로 감싸지 않은 Switch: $offenders
Transform.scale(scale: 0.8, child: Switch(...))로 감쌀 것(앱의 모든 스위치가 같은 크기).
''');
    });

    test('"시간대별 폴더 자동 전환" 행은 ListTile(enabled·onTap) + 0.8배 Switch다', () {
      final code = _stripComments(
          File('lib/screens/lock_screen_settings.dart')
              .readAsStringSync()
              .replaceAll('\r\n', '\n'));
      final compact = code.replaceAll(RegExp(r'\s+'), '');
      // 행이 꺼질 때 제목·부제목도 같이 회색이 된다(ListTile.enabled).
      expect(compact.contains('ListTile(enabled:_enabled,title:Text(t.lockScheduleEnable)'),
          isTrue,
          reason: '시간대 전환 행이 ListTile(enabled: _enabled, …)가 아니다');
      // 행을 눌러도 토글된다(SwitchListTile 시절 동작 유지), 꺼져 있으면 탭 불가.
      expect(compact.contains('onTap:_enabled?()=>_onScheduleToggled(!_scheduleShown):null'),
          isTrue,
          reason: '행 탭 토글(onTap)이 없다');
      expect(compact.contains('Switch(value:_scheduleShown,onChanged:_enabled?_onScheduleToggled:null'),
          isTrue,
          reason: '스위치가 _scheduleShown / 비활성(onChanged null) 규칙을 안 따른다');
    });
  });
}
