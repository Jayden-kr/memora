// 앱의 모든 토글 스위치는 같은 크기여야 한다(사용자 요청 2026-10-06): `Switch`는 항상
// `Transform.scale(scale: 0.8, child: Switch(...))`로 감싸서 `ListTile.trailing`에 둔다.
// "시간대별 폴더 자동 전환"만 `SwitchListTile`이라 전체 크기 스위치가 나왔던 게 계기다.
//
// 소스를 텍스트로 읽는 트립와이어다 — 위젯 테스트로는 "누가 SwitchListTile로 되돌렸는가"를
// 볼 수 없고(화면이 DB·플랫폼 채널을 물고 있다), 값이 아닌 코드의 모양에 관한 약속이라서다.
import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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

final RegExp _listTileCall = RegExp(r'(^|[^A-Za-z0-9_$])ListTile\s*\(');

/// `code[open]`이 `(`일 때 짝이 맞는 `)`의 위치(문자열 리터럴 속 괄호는 건너뜀). 없으면 -1.
int _matchParen(String code, int open) {
  var depth = 0;
  var quote = '';
  for (var i = open; i < code.length; i++) {
    final c = code[i];
    if (quote.isNotEmpty) {
      if (c == '\\') {
        i++;
      } else if (c == quote) {
        quote = '';
      }
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
    } else if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

/// (파일, 줄) 목록: `MergeSemantics(child: ListTile(…Switch…))` 모양이 아닌 Switch 행.
/// 스위치를 감싼 가장 가까운 `ListTile(`을 찾아, 그 호출이 이 Switch를 실제로 품고 있고
/// 바로 앞이 `MergeSemantics(child:`인지 본다. 안 묶으면 TalkBack이 제목과 스위치를 따로
/// 읽어 이름 없는 "꺼짐, 스위치"가 나온다(SwitchListTile은 이걸 해줬다).
List<String> switchRowsWithoutMergeSemantics(String path, String raw) {
  final code = _stripComments(raw.replaceAll('\r\n', '\n'));
  final bad = <String>[];
  for (final m in _switchCall.allMatches(code)) {
    final start = m.start + (m.group(1)?.length ?? 0);
    final line = '\n'.allMatches(code.substring(0, start)).length + 1;
    int? tileAt;
    for (final t in _listTileCall.allMatches(code.substring(0, start))) {
      tileAt = t.start + (t.group(1)?.length ?? 0);
    }
    if (tileAt == null) {
      bad.add('$path:$line (ListTile 밖의 Switch)');
      continue;
    }
    final close = _matchParen(code, code.indexOf('(', tileAt));
    if (close < start) {
      bad.add('$path:$line (가장 가까운 ListTile이 이 Switch를 품지 않는다)');
      continue;
    }
    final before = code.substring(0, tileAt).replaceAll(RegExp(r'\s+'), '');
    if (!before.endsWith('MergeSemantics(child:')) {
      bad.add('$path:$line (ListTile이 MergeSemantics(child: …)로 감싸이지 않았다)');
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

    const sw = 'Transform.scale(scale: 0.8, child: Switch(value: v))';

    test('MergeSemantics로 감싼 ListTile 행은 통과, 안 감싼 행·ListTile 밖 Switch는 잡는다', () {
      expect(
          switchRowsWithoutMergeSemantics('a.dart',
              'MergeSemantics(\n  child: ListTile(title: Text("x"), trailing: $sw),\n)'),
          isEmpty);
      // 문자열 속 괄호·onChanged 클로저가 있어도 짝을 맞춘다.
      expect(
          switchRowsWithoutMergeSemantics(
              'a.dart',
              'MergeSemantics(child: ListTile(title: Text(")("), '
                  'trailing: Transform.scale(scale: 0.8, child: Switch(value: v, '
                  'onChanged: (b) { f(b); }))))'),
          isEmpty);
      expect(switchRowsWithoutMergeSemantics('a.dart', 'ListTile(trailing: $sw)'),
          hasLength(1),
          reason: 'MergeSemantics 없는 행');
      expect(
          switchRowsWithoutMergeSemantics(
              'a.dart', 'Semantics(child: ListTile(trailing: $sw))'),
          hasLength(1),
          reason: 'MergeSemantics가 아닌 Semantics는 병합하지 않는다');
      expect(
          switchRowsWithoutMergeSemantics('a.dart', 'Row(children: [$sw])'),
          hasLength(1),
          reason: 'ListTile 밖의 Switch');
      // 앞쪽의 감싼 ListTile이 닫힌 뒤에 나온 Switch는 그 ListTile 덕을 못 본다.
      expect(
          switchRowsWithoutMergeSemantics('a.dart',
              'MergeSemantics(child: ListTile(title: Text("a")))\nRow(children: [$sw])'),
          hasLength(1));
      expect(
          switchRowsWithoutMergeSemantics(
              'a.dart', '// MergeSemantics(child: ListTile(\nListTile(trailing: $sw)'),
          hasLength(1),
          reason: '주석 속 MergeSemantics는 감싼 게 아니다');
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

    test('lib의 모든 Switch 행이 MergeSemantics(child: ListTile(…))로 묶여 있다', () {
      final offenders = <String>[];
      var total = 0;
      for (final f in _libDartFiles()) {
        final raw = f.readAsStringSync();
        total += _switchCall.allMatches(_stripComments(raw)).length;
        offenders.addAll(switchRowsWithoutMergeSemantics(f.path, raw));
      }
      expect(total, 5, reason: 'Switch 호출 수가 5가 아니다 — 스캔이 깨졌거나 스위치가 바뀌었다');
      expect(offenders, isEmpty, reason: '''
MergeSemantics로 묶이지 않은 Switch 행: $offenders
MergeSemantics(child: ListTile(…trailing: Transform.scale(scale: 0.8, child: Switch(…))))로 쓸 것.
묶지 않으면 TalkBack이 제목과 스위치를 따로 읽는다(SwitchListTile이 해주던 일).
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

  group('접근성: MergeSemantics 행은 제목과 켜짐 상태를 한 노드로 낸다', () {
    // 화면의 행(lock_screen_settings.dart 잠금화면·시간대 행)과 같은 모양의 순수 UI 하네스.
    // 화면 자체는 DB·플랫폼 채널을 물어 위젯 테스트로 못 띄우므로, "이 모양이면 한 노드가
    // 된다"는 것은 여기서, "화면이 이 모양이다"는 위 소스 스캔이 본다.
    Widget row({required bool merge, required bool on, required bool enabled}) {
      final tile = ListTile(
        enabled: enabled,
        title: const Text('Time-based folder switching'),
        subtitle: const Text('Switch folders by time'),
        onTap: enabled ? () {} : null,
        trailing: Transform.scale(
          scale: 0.8,
          child: Switch(
            key: const ValueKey('sw'),
            value: on,
            onChanged: enabled ? (_) {} : null,
          ),
        ),
      );
      return MaterialApp(
        home: Scaffold(body: ListView(children: [merge ? MergeSemantics(child: tile) : tile])),
      );
    }

    SemanticsData node(WidgetTester tester) =>
        tester.getSemantics(find.byKey(const ValueKey('sw'))).getSemanticsData();

    for (final on in [true, false]) {
      testWidgets('MergeSemantics: 스위치 노드가 제목·부제목과 toggled=$on을 함께 가진다', (tester) async {
        final handle = tester.ensureSemantics();
        try {
          await tester.pumpWidget(row(merge: true, on: on, enabled: true));
          final d = node(tester);
          expect(d.label, contains('Time-based folder switching'));
          expect(d.label, contains('Switch folders by time'));
          expect(d.flagsCollection.isToggled, on ? Tristate.isTrue : Tristate.isFalse);
          expect(d.hasAction(SemanticsAction.tap), isTrue);
        } finally {
          handle.dispose();
        }
      });
    }

    testWidgets('비활성 행도 제목과 꺼진 상태를 한 노드로 낸다', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await tester.pumpWidget(row(merge: true, on: false, enabled: false));
        final d = node(tester);
        expect(d.label, contains('Time-based folder switching'));
        expect(d.flagsCollection.isToggled, Tristate.isFalse);
        expect(d.flagsCollection.isEnabled, Tristate.isFalse);
      } finally {
        handle.dispose();
      }
    });

    testWidgets('대조군: MergeSemantics가 없으면 스위치 노드에 제목이 없다(이 테스트가 병합을 실제로 가른다)',
        (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await tester.pumpWidget(row(merge: false, on: true, enabled: true));
        expect(node(tester).label, isNot(contains('Time-based folder switching')));
      } finally {
        handle.dispose();
      }
    });
  });
}
