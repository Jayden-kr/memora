// 논리 테스트가 볼 수 없는 "구조적" 회귀만 막는 트립와이어. (자매 파일
// test/lock_screen_native_contract_test.dart와 같은 방식 — _stripComments/
// _braceBalancedBodyFrom 헬퍼도 그대로 재사용한다.)
//
// v1.3.9 재설계로 다음 불변식들이 새로 생기거나 반전됐다:
// 1. timingKey는 "v2:" 프리픽스 + canonicalCsv(=encode(parse(rulesCsvRaw))) 여야 한다.
//    "v2:" 프리픽스가 없으면 업데이트 직후 prefs에 남은 구 timingKey
//    ("$intervalMin:$startTotal:..." 형식)와 우연히 충돌할 위험이 있다.
// 2. TICK 분기는 activeRule(now, rules)로 활성 규칙을 구하고, 있으면 그 intervalMin으로
//    다음 알람을 잡고 fire(rule)로 발화해야 한다. 없으면(gap) minutesUntilNextStart 기반
//    대기만 하고 발화하지 않는다 — "규칙에 안 걸리면 무음"이 이 재설계의 핵심이다.
// 3. (반전) 메인 설정 분기도 이제 activeRule(now, rules)를 호출해야 한다 — 이전 설계의
//    "메인 분기는 전역 intervalMin 기준을 유지한다(슬롯 조회 안 함)"는 전역 인터벌
//    개념 자체가 사라지면서 폐기됐다.
// 4. PushSchedule.kt가 FolderSchedule.slotContains 위임을 잃고 구간 포함 판정을
//    복제/변형하면, 반열림·자정랩 같은 미묘한 규칙이 두 파일에서 갈라질 수 있다.
// 5. FolderSchedule.kt(잠금화면)에 PushSchedule 관련 문자열이 스며들면 두 기능이
//    한 파일에서 결합되기 시작했다는 신호 — "절대 하지 말 것"으로 명시된 오염.
// 6. 삭제된 마스터창/전역값 개념(intervalMin/startTotal/endTotal/folderId 필드,
//    inMasterWindow/effectiveIntervalMin/effectiveFolderId/activeSlotNow/fireIfInRange
//    함수, PushSchedule.Slot/INHERIT/resolveFolderId/resolveIntervalMin/MAX_SLOTS)가
//    되살아나지 않아야 한다.
// 7. Dart _startPushService의 MethodChannel 페이로드는 rulesCsv만 보내고 startTotal 류의
//    옛 필드는 보내지 않아야 한다.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue,
      reason: '$path 를 찾을 수 없다. 파일이 옮겨졌다면 이 테스트의 경로도 함께 고쳐야 한다.');
  return _stripComments(file.readAsStringSync());
}

/// 주석을 걷어낸 소스를 돌려준다. 문자열 리터럴 안의 `//`는 건드리지 않는다.
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

/// [marker] 문자열이 처음 등장하는 지점부터 시작해, 그 뒤 첫 '{'부터 중괄호
/// 균형이 맞을 때까지의 블록을 잘라낸다. 함수 이름이 아니라 `if (...)` 같은
/// 조건문 블록을 잘라낼 때 쓴다.
String _braceBalancedBodyFrom(String source, int markerStart) {
  final open = source.indexOf('{', markerStart);
  expect(open, greaterThanOrEqualTo(0),
      reason: '중괄호 시작을 찾지 못했다 (marker index=$markerStart).');
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}') {
      depth--;
      if (depth == 0) return source.substring(open, i + 1);
    }
  }
  fail('중괄호 균형을 찾지 못했다 (marker index=$markerStart).');
}

String _ifBlockBody(String source, String conditionSubstring) {
  final start = source.indexOf(conditionSubstring);
  expect(start, greaterThanOrEqualTo(0),
      reason: '"$conditionSubstring" 을 찾지 못했다. 코드가 리팩터됐다면 이 테스트도 함께 고칠 것.');
  return _braceBalancedBodyFrom(source, start);
}

// 각 test() 본문 안에서 새로 읽는다 — expect()는 test 콜백 안에서만 호출할 수
// 있어(OutsideTestException), _read()의 파일 존재 검증을 group() 콜백 최상단
// 같은 test 밖 스코프에서 미리 실행해 두면 로딩 자체가 실패한다.
String _pushService() => _read(
    'android/app/src/main/kotlin/com/henry/memora/PushNotificationService.kt');
String _pushSchedule() =>
    _read('android/app/src/main/kotlin/com/henry/memora/PushSchedule.kt');
String _folderSchedule() =>
    _read('android/app/src/main/kotlin/com/henry/memora/FolderSchedule.kt');
String _notificationService() =>
    _read('lib/services/notification_service.dart');

void main() {
  group('네이티브 계약 트립와이어 — 푸시 알림 시간대 규칙(v1.3.9)', () {
    test('timingKey 대입식에 "v2:" 프리픽스와 canonicalCsv가 등장해야 한다', () {
      final pushServiceSource = _pushService();
      final lines = pushServiceSource
          .split('\n')
          .where((l) => l.contains('val timingKey ='))
          .toList();
      expect(lines, isNotEmpty, reason: 'timingKey 대입식을 찾지 못했다.');
      for (final line in lines) {
        expect(line.contains('"v2:'), isTrue, reason: '''
timingKey 대입식에 "v2:" 프리픽스가 없다:
  ${line.trim()}

이 프리픽스가 없으면 업데이트 직후 prefs에 남아있는 구 timingKey
("\$intervalMin:\$startTotal:..." 형식)와 우연히 같은 문자열이 나와 충돌할 수 있다.
''');
        expect(line.contains('canonicalCsv'), isTrue,
            reason: 'timingKey 대입식에 canonicalCsv 변수가 보이지 않는다: ${line.trim()}');
      }
    });

    test('canonicalCsv는 PushSchedule.parse로 정규화한 뒤 encode한 값이어야 한다', () {
      final pushServiceSource = _pushService();
      expect(
        pushServiceSource.contains(
            'PushSchedule.encode(PushSchedule.parse(rulesCsvRaw))'),
        isTrue,
        reason: '''
canonicalCsv를 만드는 "encode(parse(rulesCsvRaw))" 정규화 파이프라인을 찾지 못했다.
원본 문자열(rulesCsvRaw)을 그대로 timingKey에 쓰면 공백/순서 차이만으로도
불필요하게 타이머가 리셋된다.
''',
      );
    });

    test('TICK 분기는 activeRule(now, rules)로 활성 규칙을 구하고 fire(rule)로 발화해야 한다', () {
      final tickBody =
          _ifBlockBody(_pushService(), 'if (intent?.action == ACTION_TICK)');
      expect(tickBody.contains('PushSchedule.activeRule(now, rules)'), isTrue,
          reason: 'TICK 분기가 PushSchedule.activeRule(now, rules)로 활성 규칙을 구하지 않는다.');
      expect(tickBody.contains('rule.intervalMin'), isTrue, reason: '''
TICK 분기의 간격 계산이 rule.intervalMin을 쓰지 않는다.

전역 intervalMin으로 되돌아가면 규칙별 간격 오버라이드가 조용히 무시된다.
''');
      expect(tickBody.contains('fire(rule)'), isTrue, reason: '''
TICK 분기가 fire(rule) 형태로 판정된 규칙을 발화 경로에 넘기지 않는다.
''');
      expect(tickBody.contains('minutesUntilNextStart'), isTrue, reason: '''
TICK 분기가 활성 규칙이 없을 때(gap) minutesUntilNextStart로 다음 재평가 시각을
계산하지 않는다 — 이게 없으면 gap 진입 후 다음 규칙 시작을 영영 놓칠 수 있다.
''');
    });

    test('rule이 null이면(gap) TICK이 fire를 호출하지 않아야 한다(무음 동작 보증)', () {
      final tickBody =
          _ifBlockBody(_pushService(), 'if (intent?.action == ACTION_TICK)');
      expect(tickBody.contains('if (rule != null) fire(rule)'), isTrue,
          reason: 'TICK 분기가 "if (rule != null) fire(rule)" 형태로 gap일 때 발화를 건너뛰지 않는다.');
    });

    test('(반전) 메인 설정 분기도 이제 activeRule(now, rules)를 호출해야 한다', () {
      // v1.3.8까지는 "메인 분기는 슬롯을 조회하지 않는다"가 불변식이었지만, 전역
      // 인터벌 개념 자체가 사라지면서 이 트립와이어는 의도적으로 반전됐다 — 메인
      // 분기도 지금 활성 규칙이 있는지에 따라 delayMs를 계산해야 첫 알람이 올바른
      // 시각에 잡힌다.
      //
      // 주석은 _stripComments가 미리 제거하므로 마커로 쓸 수 없다 — 대신 파일
      // 전체에서 "PushSchedule.activeRule(now, rules)" 호출 횟수를 센다. TICK
      // 분기에 최소 1회(위 테스트가 이미 확인), 그리고 TICK 분기 밖(=메인 분기)에도
      // 최소 1회 있어야 한다.
      final pushServiceSource = _pushService();
      final tickBody =
          _ifBlockBody(pushServiceSource, 'if (intent?.action == ACTION_TICK)');
      const needle = 'PushSchedule.activeRule(now, rules)';
      int countOccurrences(String haystack) {
        var count = 0;
        var idx = 0;
        while (true) {
          idx = haystack.indexOf(needle, idx);
          if (idx < 0) break;
          count++;
          idx += needle.length;
        }
        return count;
      }

      final totalCount = countOccurrences(pushServiceSource);
      final tickCount = countOccurrences(tickBody);
      expect(totalCount - tickCount, greaterThanOrEqualTo(1), reason: '''
TICK 분기 밖(메인 설정 분기)에 activeRule(now, rules) 호출이 없다.

전체 호출 횟수=$totalCount, TICK 분기 안 호출 횟수=$tickCount.
''');
    });

    test('PushSchedule.kt는 FolderSchedule.slotContains를 호출해 위임해야 한다(복제 금지)', () {
      expect(_pushSchedule().contains('FolderSchedule.slotContains('), isTrue,
          reason: '''
PushSchedule.kt가 더 이상 FolderSchedule.slotContains를 호출하지 않는다.

구간 포함 판정(반열림, 자정랩)을 복제하면 두 파일이 미묘하게 갈라질 수 있다 —
단일 진실원천을 유지하기 위해 위임이 반드시 남아 있어야 한다.
''');
    });

    test('FolderSchedule.kt(잠금화면)는 PushSchedule 관련 코드로 오염되지 않아야 한다', () {
      final folderScheduleSource = _folderSchedule();
      expect(folderScheduleSource.contains('intervalMin'), isFalse, reason: '''
FolderSchedule.kt(잠금화면 전용)에 intervalMin이 등장한다.

이 필드는 PushSchedule 전용이다 — FolderSchedule.kt/LockScreenService.kt는
"한 글자도 수정 금지(읽기·호출만)" 대상이므로, 여기 intervalMin이 스며들었다면
잠금화면 파일이 수정됐다는 뜻이다.
''');
      expect(folderScheduleSource.contains('PushSchedule'), isFalse, reason: '''
FolderSchedule.kt가 PushSchedule을 참조한다 — 두 기능이 결합되기 시작했다는
신호. FolderSchedule.kt는 순수하게 잠금화면 전용으로 남아야 하고, 위임 방향은
항상 PushSchedule → FolderSchedule 한 방향이어야 한다.
''');
    });

    test('MAX_RULES는 12로 고정돼 있어야 한다(잠금화면의 50과 혼동 금지)', () {
      expect(_pushSchedule().contains('const val MAX_RULES = 12'), isTrue,
          reason: 'PushSchedule.MAX_RULES가 12가 아니게 바뀌었다(설계상 잠금화면의 50과 다름).');
    });

    test('삭제된 마스터창/전역값 개념이 되살아나지 않아야 한다', () {
      final pushServiceSource = _pushService();
      final pushScheduleSource = _pushSchedule();
      const deletedInService = [
        'private var intervalMin',
        'private var startTotal',
        'private var endTotal',
        'private var folderId',
        'private var scheduleEnabled',
        'fun inMasterWindow',
        'fun effectiveIntervalMin',
        'fun effectiveFolderId',
        'fun activeSlotNow',
        'fun fireIfInRange',
      ];
      for (final needle in deletedInService) {
        expect(pushServiceSource.contains(needle), isFalse,
            reason: 'PushNotificationService.kt에 삭제됐어야 할 "$needle"이 남아있다.');
      }
      const deletedInSchedule = [
        'PushSchedule.INHERIT',
        'class Slot',
        'data class Slot',
        'fun resolveFolderId',
        'fun resolveIntervalMin',
        'MAX_SLOTS',
      ];
      for (final needle in deletedInSchedule) {
        expect(pushScheduleSource.contains(needle), isFalse,
            reason: 'PushSchedule.kt에 삭제됐어야 할 "$needle"이 남아있다.');
      }
    });

    test('Dart _startPushService 페이로드는 rulesCsv만 보내고 옛 필드(startTotal 등)를 보내지 않아야 한다', () {
      final source = _notificationService();
      expect(source.contains("'rulesCsv'"), isTrue,
          reason: 'notification_service.dart의 startService 페이로드에 rulesCsv 키가 없다.');
      const deletedPayloadKeys = [
        "'startTotal'",
        "'endTotal'",
        "'intervalMin'",
        "'folderId'",
        "'scheduleEnabled'",
        "'scheduleCsv'",
      ];
      for (final needle in deletedPayloadKeys) {
        expect(source.contains(needle), isFalse,
            reason: 'notification_service.dart에 삭제됐어야 할 페이로드 키 $needle이 남아있다.');
      }
    });
  });
}
