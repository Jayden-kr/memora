// 논리 테스트가 볼 수 없는 "구조적" 회귀만 막는 트립와이어. (자매 파일
// test/lock_screen_native_contract_test.dart와 같은 방식 — _stripComments/
// _kotlinFunctionBody 헬퍼도 그대로 재사용한다.)
//
// 여기서 지키는 5개 불변식은 전부 값이 아니라 코드의 "모양"에 관한 것이라, 어떤
// 단위 테스트로도 잡히지 않는다. 각각이 실제로 이 기능을 망가뜨릴 수 있는, 그럴듯한
// "정리/단순화" 리팩터가 원인이 된다:
// 1. timingKey 대입식이 scheduleEnabled/정규화된 CSV를 빼먹으면, 슬롯만 편집해서
//    저장해도 "타이밍 변경 없음"으로 오판돼 실행 중이던 타이머가 새 스케줄을
//    영영 반영하지 못한다.
// 2. fireIfInRange의 마스터창 판정(inMasterWindow)이 사라지면 시간 밖에서도
//    알림이 발사된다.
// 3. TICK의 intervalMs 계산이 raw intervalMin으로 되돌아가면, 슬롯의 간격
//    오버라이드가 조용히 무시된다(폴더만 바뀌고 간격은 절대 안 바뀜).
// 4. PushSchedule.kt가 FolderSchedule.slotContains 위임을 잃고 구간 포함 판정을
//    복제/변형하면, 반열림·자정랩 같은 미묘한 규칙이 두 파일에서 갈라질 수 있다.
// 5. FolderSchedule.kt(잠금화면)에 PushSchedule 관련 문자열이 스며들면 두 기능이
//    한 파일에서 결합되기 시작했다는 신호 — "절대 하지 말 것"으로 명시된 오염.

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

/// `fun <name>(` 부터 중괄호 균형이 맞을 때까지의 본문을 잘라낸다.
String _kotlinFunctionBody(String source, String name) {
  final start = source.indexOf('fun $name(');
  expect(start, greaterThanOrEqualTo(0),
      reason: 'Kotlin 함수 $name 을 찾지 못했다. 이름이 바뀌었다면 이 테스트도 함께 고칠 것.');
  return _braceBalancedBodyFrom(source, start);
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

void main() {
  group('네이티브 계약 트립와이어 — 푸시 알림 시간대 스케줄', () {
    test('timingKey 대입식에 scheduleEnabled와 정규화된 스케줄 CSV 변수가 둘 다 등장해야 한다', () {
      final pushServiceSource = _pushService();
      final lines = pushServiceSource
          .split('\n')
          .where((l) => l.contains('val timingKey ='))
          .toList();
      expect(lines, isNotEmpty, reason: 'timingKey 대입식을 찾지 못했다.');
      for (final line in lines) {
        expect(line.contains('scheduleEnabled'), isTrue, reason: '''
timingKey 대입식이 scheduleEnabled를 포함하지 않는다:
  ${line.trim()}

scheduleEnabled/스케줄 CSV가 timingKey에서 빠지면, 슬롯만 편집해서 저장해도
"타이밍 변경 없음"으로 오판돼(timingKey == savedTimingKey) 실행 중이던 타이머가
새 스케줄을 영영 반영하지 못한다.
''');
        // canonicalCsv(정규화된 CSV) 변수가 쓰여야 한다 — scheduleCsvRaw를 그대로 쓰면
        // 공백/순서 차이로 편집할 때마다 불필요하게 타이머가 리셋된다.
        expect(line.contains('canonicalCsv') || line.contains('Csv'), isTrue,
            reason: 'timingKey 대입식에 스케줄 CSV 변수가 보이지 않는다: ${line.trim()}');
      }
    });

    test('canonicalCsv는 PushSchedule.parse로 정규화한 뒤 encode한 값이어야 한다', () {
      final pushServiceSource = _pushService();
      expect(
        pushServiceSource.contains(
            'PushSchedule.encode(PushSchedule.parse(scheduleCsvRaw))'),
        isTrue,
        reason: '''
canonicalCsv를 만드는 "encode(parse(raw))" 정규화 파이프라인을 찾지 못했다.
원본 문자열(scheduleCsvRaw)을 그대로 timingKey에 쓰면 공백/순서 차이만으로도
불필요하게 타이머가 리셋된다.
''',
      );
    });

    test('fireIfInRange 경로에 마스터창 판정(inMasterWindow)이 살아있어야 한다', () {
      final body = _kotlinFunctionBody(_pushService(), 'fireIfInRange');
      expect(body.contains('inMasterWindow('), isTrue, reason: '''
fireIfInRange()가 더 이상 inMasterWindow()를 호출하지 않는다.

이 판정이 없어지면 활성시간창(startTotal~endTotal) 밖에서도 알림이 발사된다 —
시간대 슬롯 기능을 붙이기 전부터 있던 마스터 게이트가 무너지는 것이다.
''');
    });

    test('inMasterWindow는 양끝 포함 판정을 유지해야 한다(반열림으로 "통일" 금지)', () {
      final body = _kotlinFunctionBody(_pushService(), 'inMasterWindow');
      expect(body.contains('..'), isTrue, reason: '''
inMasterWindow()에서 양끝 포함 range 연산자(..)가 사라졌다.

fireIfInRange의 "쏠지 말지"는 단일 범위라 경계 포함(..)이 맞고, PushSchedule.Slot
쪽 반열림 판정과는 의도적으로 다르다 — 통일하지 말 것.
''');
    });

    test('ACTION_TICK의 간격 계산은 raw intervalMin이 아니라 effectiveIntervalMin(slot)을 써야 한다',
        () {
      final tickBody =
          _ifBlockBody(_pushService(), 'if (intent?.action == ACTION_TICK)');
      expect(tickBody.contains('effectiveIntervalMin(slot)'), isTrue, reason: '''
TICK 분기의 intervalMs 계산이 effectiveIntervalMin(slot)을 쓰지 않는다.

raw intervalMin(전역값)으로 되돌아가면 시간대 슬롯의 간격 오버라이드가 조용히
무시된다 — 폴더는 바뀌어도 알림 간격은 절대 안 바뀐다.
''');
      expect(tickBody.contains('activeSlotNow(now)'), isTrue, reason: '''
TICK 분기가 activeSlotNow(now)로 현재 활성 슬롯을 구하지 않는다.
''');
      expect(tickBody.contains('fireIfInRange(now, slot)'), isTrue, reason: '''
TICK 분기가 fireIfInRange(now, slot) 형태로 판정된 슬롯을 발화 경로에 넘기지
않는다 — 폴더가 즉시 전환되지 않는다.
''');
    });

    test('메인 설정 분기는 전역 intervalMin 기준을 유지해야 한다(슬롯 조회 안 함)', () {
      // "타이머 유지"/"새로 시작" 분기(if (wasRunning && timingKey == savedTimingKey) 이후)는
      // 의도적으로 슬롯을 조회하지 않는다 — timingKey가 바뀌면 이 분기 자체가
      // (savedTimingKey 불일치로) "새로 시작" 쪽으로 빠지기 때문이다. 이 두 곳이
      // activeSlotNow를 쓰기 시작하면 "메인 분기는 슬롯 조회 안 함" 설계가 깨진 것이다.
      final pushServiceSource = _pushService();
      final mainBranchStart =
          pushServiceSource.indexOf('if (wasRunning && timingKey == savedTimingKey)');
      expect(mainBranchStart, greaterThanOrEqualTo(0));
      final openBrace = pushServiceSource.indexOf('{', mainBranchStart);
      final mainBranchBody = _braceBalancedBodyFrom(pushServiceSource, mainBranchStart);
      // if/else 전체(타이머 유지 + 새로 시작)를 포함하려면 else 블록도 봐야 하므로,
      // if 블록이 실제로 끝나는 절대 위치(openBrace + 본문 길이) 뒤에서 else를 찾아
      // 이어 붙인다. (if 본문 안에도 중첩된 "} else {"가 있어 단순 substring 탐색은
      // 잘못된 지점을 집을 수 있다 — 절대 종료 위치를 명시적으로 계산해야 한다.)
      final ifEndAbsolute = openBrace + mainBranchBody.length;
      final elseIdx = pushServiceSource.indexOf('else', ifEndAbsolute);
      expect(elseIdx, greaterThanOrEqualTo(0),
          reason: 'if (wasRunning...) 블록 뒤에서 else를 찾지 못했다.');
      final elseBody = _braceBalancedBodyFrom(pushServiceSource, elseIdx);
      final combined = mainBranchBody + elseBody;
      expect(combined.contains('activeSlotNow'), isFalse, reason: '''
메인 설정 분기("타이머 유지"/"새로 시작")가 activeSlotNow를 호출하기 시작했다.

설계상 이 분기는 슬롯을 조회하지 않는다 — timingKey가 스케줄 변경을 포함하도록
이미 확장되어 있으므로, 스케줄이 바뀌면 이 분기 자체가 (savedTimingKey 불일치로)
건너뛰어지고 TICK이 다음 발화 때 새 슬롯을 반영한다.
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

    test('MAX_SLOTS는 5로 고정돼 있어야 한다(잠금화면의 50과 혼동 금지)', () {
      expect(_pushSchedule().contains('const val MAX_SLOTS = 5'), isTrue,
          reason: 'PushSchedule.MAX_SLOTS가 5가 아니게 바뀌었다(설계상 잠금화면의 50과 다름).');
    });
  });
}
