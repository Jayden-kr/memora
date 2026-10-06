// 잠금화면 토글 규칙(사용자 요청 2026-10-06): 잠금화면을 켜든 끄든 "시간대별 폴더 전환"
// 플래그는 꺼져서 저장되고(그래서 켜도 시간대 전환이 저절로 켜지지 않는다), 슬롯은 남는다.
//
// 1. 순수 판정(LockToggleRule.decideEnable) 단위 테스트.
// 2. 구조적 트립와이어: 화면·서비스 소스를 텍스트로 읽어, `_enabled`를 바꾸는 모든 자리가
//    같은 자리에서 `_scheduleEnabled`를 규칙 상수로 내리는지, 저장 경로가 플래그를 네이티브에
//    싣는지 본다. 화면은 DB·플랫폼 채널을 물고 있어 위젯 테스트로는 이 자리들을 못 밟는다.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memora/services/lock_screen_service.dart';

String _read(String path) {
  final f = File(path);
  // group 본문(테스트 밖)에서도 불리므로 expect 대신 throw — expect는 테스트 밖에서 못 쓴다.
  if (!f.existsSync()) {
    throw StateError('$path 를 찾을 수 없다(파일이 옮겨졌으면 경로를 고칠 것)');
  }
  return _stripComments(f.readAsStringSync().replaceAll('\r\n', '\n'));
}

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

String _compact(String s) => s.replaceAll(RegExp(r'\s+'), '');

/// `signature`로 시작하는 메서드의 본문(첫 `{`부터 짝이 맞는 `}`까지)을 돌려준다.
String _body(String code, String signature) {
  final at = code.indexOf(signature);
  expect(at, greaterThanOrEqualTo(0), reason: '$signature 를 찾을 수 없다');
  // 매개변수 목록(named 매개변수의 `{`도 포함)을 건너뛰고 본문의 `{`를 찾는다.
  var paren = 0;
  var i0 = code.indexOf('(', at);
  for (; i0 < code.length; i0++) {
    if (code[i0] == '(') paren++;
    if (code[i0] == ')') {
      paren--;
      if (paren == 0) break;
    }
  }
  final open = code.indexOf('{', i0);
  var depth = 0;
  for (var i = open; i < code.length; i++) {
    if (code[i] == '{') depth++;
    if (code[i] == '}') {
      depth--;
      if (depth == 0) return code.substring(open, i + 1);
    }
  }
  fail('$signature 의 본문 끝을 찾을 수 없다');
}

const _lowered = '_scheduleEnabled=LockToggleRule.scheduleEnabledAfterToggle;';

void main() {
  group('LockToggleRule 순수 판정', () {
    test('토글 뒤 저장되는 시간대 전환 값은 false다', () {
      expect(LockToggleRule.scheduleEnabledAfterToggle, isFalse);
    });

    LockEnableOutcome decide({
      bool selected = false,
      bool folders = true,
      bool schedule = LockToggleRule.scheduleEnabledAfterToggle,
      bool slots = true,
    }) =>
        LockToggleRule.decideEnable(
          hasSelectedFolder: selected,
          hasFolders: folders,
          scheduleEnabled: schedule,
          hasSlots: slots,
        );

    test('고른 폴더가 있으면 그대로 켠다', () {
      expect(decide(selected: true), LockEnableOutcome.proceed);
    });

    test('폴더를 안 골랐고 폴더가 있으면 첫 폴더를 자동 선택한다', () {
      expect(decide(), LockEnableOutcome.autoSelectFirstFolder);
    });

    test('폴더가 아예 없으면 켤 수 없다', () {
      expect(decide(folders: false), LockEnableOutcome.blockedNoFolder);
    });

    test('핵심: 켤 때 시간대 전환은 꺼진 값으로 판정하므로 슬롯이 있어도 "슬롯만으로 켜짐" 예외가 없다', () {
      // 슬롯이 있고 폴더도 있는데 기본 폴더가 없다 → 예전엔(시간대 ON 보존 시) 자동 선택을
      // 건너뛰었다. 이제는 첫 폴더를 고른다.
      expect(decide(slots: true), LockEnableOutcome.autoSelectFirstFolder);
      // 슬롯만 있고 폴더가 없으면 막는다(스낵바).
      expect(decide(slots: true, folders: false), LockEnableOutcome.blockedNoFolder);
    });

    test('가드 자체는 살아 있다: 시간대 전환 ON + 슬롯이 있을 때만 폴더 없이 켠다', () {
      expect(decide(schedule: true, slots: true, folders: false),
          LockEnableOutcome.proceed);
      expect(decide(schedule: true, slots: true), LockEnableOutcome.proceed);
      // 시간대 전환 ON이어도 슬롯이 없으면 유효한 슬롯이 아니다.
      expect(decide(schedule: true, slots: false), LockEnableOutcome.autoSelectFirstFolder);
      expect(decide(schedule: true, slots: false, folders: false),
          LockEnableOutcome.blockedNoFolder);
    });
  });

  group('구조적 트립와이어: lock_screen_settings.dart', () {
    final code = _read('lib/screens/lock_screen_settings.dart');

    test('_enabled를 바꾸는 모든 대입이 같은 setState 안에서 시간대 전환을 내린다', () {
      // 필드 선언(`bool _enabled = false;`)과 로드(`_enabled = settings[...]`)는 제외한다.
      final assign = RegExp(r'(?<!bool\s)_enabled\s*=\s*(?!settings\[)(\w+)\s*;');
      final matches = assign.allMatches(code).toList();
      // 사용자 토글(_onEnabledChanged)과 오버레이 권한 거부(_checkOverlayAndStartImpl).
      expect(matches.length, 2, reason: '_enabled를 바꾸는 자리 수가 바뀌었다 — 새 자리에도 규칙을 적용하고 이 숫자를 고칠 것');
      for (final m in matches) {
        final tail = _compact(code.substring(m.end, (m.end + 160).clamp(0, code.length)));
        expect(tail.startsWith(_lowered), isTrue,
            reason: '${m.group(0)} 바로 뒤에서 $_lowered 가 없다 — 잠금화면을 토글하면 시간대 전환도 꺼야 한다');
      }
    });

    test('_onEnabledChanged는 LockToggleRule.decideEnable로 판정하고 옛 hasValidSlots 가드를 안 쓴다', () {
      final body = _compact(_body(code, 'Future<void> _onEnabledChanged('));
      expect(body.contains('LockToggleRule.decideEnable('), isTrue);
      expect(body.contains('scheduleEnabled:LockToggleRule.scheduleEnabledAfterToggle'), isTrue,
          reason: '켠 뒤에 저장될 값(false)이 아니라 현재 _scheduleEnabled로 판정하면 옛 복원 동작으로 돌아간다');
      expect(body.contains('hasValidSlots'), isFalse);
      expect(body.contains('_scheduleEnabled&&'), isFalse);
      expect(body.contains('LockEnableOutcome.blockedNoFolder'), isTrue);
      expect(body.contains('LockEnableOutcome.autoSelectFirstFolder'), isTrue);
    });

    test('오버레이 권한 거부 경로가 _enabled=false와 함께 시간대 전환을 내리고 저장한다', () {
      final body = _compact(_body(code, 'Future<void> _checkOverlayAndStartImpl('));
      expect(body.contains('_enabled=false;$_lowered'), isTrue);
      // 꺼진 값이 화면에만 남지 않고 저장된다.
      expect(body.contains('_enabled=false;$_lowered});'), isTrue);
      expect(body.contains('await_applySettings();return;'), isTrue);
    });

    test('저장 경로(_applySettings)가 두 갈래 모두 scheduleEnabled·scheduleCsv를 네이티브로 보낸다', () {
      final body = _compact(_body(code, 'Future<void> _applySettings('));
      expect(RegExp(r'scheduleEnabled:_scheduleEnabled,scheduleCsv:scheduleCsv,').allMatches(body).length, 2,
          reason: 'startService / saveSettings 두 호출 모두 플래그와 슬롯을 실어야 꺼진 값이 prefs에 남는다');
      expect(body.contains('LockScreenSchedule.encode(_slots)'), isTrue,
          reason: '슬롯은 지우지 않고 그대로 저장한다');
    });

    test('토글 경로는 슬롯 목록을 비우지 않는다(다시 켜면 재사용)', () {
      final onEnabled = _compact(_body(code, 'Future<void> _onEnabledChanged('));
      expect(onEnabled.contains('_slots'), isTrue); // hasSlots 판정에만 읽는다
      expect(onEnabled.contains('_slots.clear'), isFalse);
      expect(onEnabled.contains('_slots=['), isFalse);
      expect(onEnabled.contains('_slots.removeWhere'), isFalse);
    });
  });

  group('구조적 트립와이어: lock_screen_service.dart', () {
    final code = _read('lib/services/lock_screen_service.dart');

    test('폴더 삭제로 잠금화면이 자동으로 꺼질 때도 시간대 전환을 끄고 슬롯은 보존한다', () {
      final body = _compact(_body(code, 'static Future<bool> removeFoldersFromSettingsBatch('));
      expect(
          body.contains('saveSettings(enabled:false,folderIds:const[],'
              'finishedFilter:finishedFilter,sortOrder:sortOrder,reversed:reversed,bgColor:bgColor,'
              'scheduleEnabled:LockToggleRule.scheduleEnabledAfterToggle,scheduleCsv:scheduleCsv,'),
          isTrue,
          reason: '자동 꺼짐 갈래가 scheduleEnabled를 규칙 상수로 내리지 않거나 scheduleCsv를 빼먹었다');
    });
  });
}
