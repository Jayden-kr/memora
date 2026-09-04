// 논리 테스트가 볼 수 없는 "구조적" 회귀만 막는 트립와이어.
//
// 여기 있는 불변식들은 값이 아니라 코드의 모양(또는 두 언어 간 상수 동기화)에
// 관한 것이라, 어떤 단위 테스트로도 잡히지 않는다. 실제로 이 기능을 망가뜨릴 수
// 있는, 그럴듯한 "정리/단순화"가 원인이 된다. 그래서 소스를 텍스트로 읽어 확인한다.
// (자매 프로젝트 Moneta의 native_capture_contract_test 와 같은 방식)
//
// Stage 2(자동 대비 팔레트) 추가분: BgContrast.kt(Kotlin)와
// lock_screen_contrast.dart(Dart)가 같은 임계값/가중치를 쓰는지 확인한다 — 각
// 파일 자체의 로직 정확성은 BgContrastTest.kt / lock_screen_contrast_test.dart가
// 이미 검증하므로, 여기서는 "둘이 갈라지지 않았는가"만 본다.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue,
      reason: '$path 를 찾을 수 없다. 파일이 옮겨졌다면 이 테스트의 경로도 함께 고쳐야 한다.');
  return _stripComments(file.readAsStringSync());
}

/// 주석을 걷어낸 소스를 돌려준다.
///
/// 이게 없으면 트립와이어가 "주석 처리된 코드"를 살아있는 코드로 착각한다. 실제로
/// 이 테스트의 첫 판에서 `// queryCardsInto(baseFolderIds)` 로 폴백을 죽여도 초록이
/// 나왔다(네거티브 컨트롤에서 발견). 문자열 리터럴 안의 `//` 는 건드리지 않는다.
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

/// `fun <name>(` 부터 중괄호 균형이 맞을 때까지의 본문을 잘라낸다.
String _kotlinFunctionBody(String source, String name) {
  final start = source.indexOf('fun $name(');
  expect(start, greaterThanOrEqualTo(0),
      reason: 'Kotlin 함수 $name 을 찾지 못했다. 이름이 바뀌었다면 이 테스트도 함께 고칠 것.');
  final open = source.indexOf('{', start);
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}') {
      depth--;
      if (depth == 0) return source.substring(open, i + 1);
    }
  }
  fail('$name 의 본문에서 중괄호 균형을 찾지 못했다.');
}

void main() {
  group('네이티브 계약 트립와이어', () {
    test(
        'MainActivity.saveSettings 는 스케줄 키를 "인자가 있을 때만" 기록해야 한다',
        () {
      final source =
          _read('android/app/src/main/kotlin/com/henry/memora/MainActivity.kt');
      final body = _kotlinFunctionBody(source, 'saveSettings');

      for (final key in ['schedule_enabled', 'folder_schedule']) {
        final lines = body
            .split('\n')
            .where((l) => l.contains('"$key"'))
            .toList();

        expect(lines, isNotEmpty,
            reason: 'saveSettings 가 $key 를 더 이상 기록하지 않는다. '
                '설정 화면에서 시간대를 바꿔도 저장되지 않는다.');

        for (final line in lines) {
          expect(line.contains('?.let'), isTrue,
              reason: '''
saveSettings 가 $key 를 조건 없이 기록하고 있다:
  ${line.trim()}

이 함수는 나머지 6개 키를 "인자가 없으면 기본값으로" 무조건 덮어쓴다. 스케줄 키까지
같은 방식으로 만들면, 이 두 인자를 넘기지 않는 호출자가 사용자의 시간대 설정을
지워버린다. 그 호출자가 실제로 있다 — lib/main.dart 의 _restoreLockScreenService()
는 앱을 켤 때마다 startService 를 태우면서 스케줄을 싣지 않는다. 즉 이 한 줄을
"일관성 있게" 정리하는 순간, 앱을 껐다 켤 때마다 시간대 설정이 조용히 사라진다.

`(settings["..."] as? T)?.let { editor.put...(...) }` 형태를 유지할 것.
''');
        }
      }
    });

    test(
        'MainActivity.saveSettings 는 bg_text_mode를 "인자가 있을 때만" 기록해야 한다',
        () {
      final source =
          _read('android/app/src/main/kotlin/com/henry/memora/MainActivity.kt');
      final body = _kotlinFunctionBody(source, 'saveSettings');

      final lines = body
          .split('\n')
          .where((l) => l.contains('"bg_text_mode"'))
          .toList();

      expect(lines, isNotEmpty,
          reason: 'saveSettings 가 bg_text_mode 를 더 이상 기록하지 않는다. '
              '설정 화면에서 텍스트 모드를 바꿔도 저장되지 않는다.');

      for (final line in lines) {
        expect(line.contains('?.let'), isTrue, reason: '''
saveSettings 가 bg_text_mode 를 조건 없이 기록하고 있다:
  ${line.trim()}

scheduleEnabled/scheduleCsv와 정확히 같은 이유로 위험하다 — lib/main.dart의
_restoreLockScreenService()는 앱을 켤 때마다 startService를 태우면서 bgTextMode를
싣지 않는다. 조건 없이 기록하면 앱을 껐다 켤 때마다 사용자가 고른 텍스트 모드가
"auto"로 조용히 되돌아간다.

`(settings["bgTextMode"] as? String)?.let { editor.putString("bg_text_mode", it) }`
형태를 유지할 것.
''');
      }
    });

    test('LockScreenService 는 폴더가 바뀐 경우에만 덱을 다시 읽어야 한다', () {
      final source = _read(
          'android/app/src/main/kotlin/com/henry/memora/LockScreenService.kt');

      expect(source.contains('loadedFolderIds'), isTrue, reason: '''
loadedFolderIds 필드가 사라졌다.

이 필드가 "지금 들고 있는 덱이 어느 폴더 것인지"를 기억하는 유일한 곳이다. 없어지면
둘 중 하나가 된다:
  (1) 오버레이가 떠 있는 동안 시간대가 바뀌어도 덱을 안 바꾼다 → 기능 자체가 무동작.
      오버레이는 화면을 켜도 안 사라지므로(하단 바 스와이프로만 사라짐) 몇 시간이고
      이전 시간대 폴더가 계속 보인다.
  (2) 매 글랜스마다 덱을 다시 읽는다 → random 정렬이 매번 다시 섞여 advanceCard 의
      반복 방지가 무력화되고, currentIndex 가 0으로 리셋돼 1번 카드에 갇힌다.
''');

      expect(source.contains('loadedFolderIds != folderIds'), isTrue, reason: '''
"폴더가 바뀌었을 때만 재로드" 판정(loadedFolderIds != folderIds)이 사라졌다.
위 (1)/(2) 중 하나가 바로 재현된다.
''');

      final body = _kotlinFunctionBody(source, 'loadCardsFromDb');
      expect(body.contains('queryCardsInto(baseFolderIds)'), isTrue, reason: '''
시간대 폴더가 비었을 때 기본 폴더로 폴백하는 경로가 사라졌다.

폴백이 없으면 showOverlay() 의 `if (cards.isEmpty()) return` 에 걸려 오버레이가
아예 안 뜬다 — 에러도 토스트도 없이 잠금화면이 그냥 비어버린다. 시간대 기능은
"유효해야 하는 폴더 id" 개수를 늘리므로 이건 드문 경우가 아니라 폴더를 지우면
바로 나오는 기본 시나리오다.
''');

      expect(body.contains('loadedFolderIds = requested'), isTrue, reason: '''
loadedFolderIds 에 "실제로 쿼리한 폴더"를 기록하고 있다(요청한 폴더가 아니라).

폴백이 일어난 뒤 base 를 기록하면, 다음 글랜스에서 loadSettings() 가 시간대 폴더를
다시 해석해 "달라졌다"고 오판한다. 그러면 빈 폴더가 걸린 시간대 내내 매 글랜스가
재로드로 이어지고 currentIndex 가 0으로 리셋돼 카드가 안 넘어간다.
''');
    });

    test('Dart 쪽 스케줄 인자는 nullable 이어야 하고 null 이면 생략돼야 한다', () {
      final source = _read('lib/services/lock_screen_service.dart');

      // startService / saveSettings 두 곳
      expect('bool? scheduleEnabled,'.allMatches(source).length, 2,
          reason: '''
scheduleEnabled 파라미터가 nullable 이 아니다(또는 개수가 2가 아니다).

기본값을 가진 non-nullable 파라미터로 바꾸면 컴파일은 통과하지만, 이 인자를 넘기지
않는 호출자가 조용히 기본값을 저장해 사용자의 시간대 설정을 지운다. 컴파일러는
아무 말도 하지 않는다 — 그래서 이 테스트가 있다.
''');
      expect('String? scheduleCsv,'.allMatches(source).length, 2,
          reason: 'scheduleCsv 파라미터가 nullable 이 아니다. 위와 같은 이유로 위험하다.');

      expect(
          "if (scheduleEnabled != null) args['scheduleEnabled'] = scheduleEnabled;"
              .allMatches(source)
              .length,
          2,
          reason: 'null 인 scheduleEnabled 를 인자 맵에서 빼는 가드가 사라졌다.');
      expect(
          "if (scheduleCsv != null) args['scheduleCsv'] = scheduleCsv;"
              .allMatches(source)
              .length,
          2,
          reason: 'null 인 scheduleCsv 를 인자 맵에서 빼는 가드가 사라졌다.');
    });

    test('Dart 쪽 bgTextMode 인자도 nullable 이어야 하고 null 이면 생략돼야 한다', () {
      final source = _read('lib/services/lock_screen_service.dart');

      // startService / saveSettings 두 곳
      expect('String? bgTextMode,'.allMatches(source).length, 2,
          reason: '''
bgTextMode 파라미터가 nullable 이 아니다(또는 개수가 2가 아니다).

scheduleEnabled/scheduleCsv와 같은 이유로 위험하다 — 기본값을 가진 non-nullable
파라미터로 바꾸면 컴파일은 통과하지만, 이 인자를 넘기지 않는 호출자
(_restoreLockScreenService)가 조용히 기본값("auto")을 저장해 사용자가 고른
텍스트 모드를 지운다.
''');
      expect(
          "if (bgTextMode != null) args['bgTextMode'] = bgTextMode;"
              .allMatches(source)
              .length,
          2,
          reason: 'null 인 bgTextMode 를 인자 맵에서 빼는 가드가 사라졌다.');
    });

    test('BgContrast 대비 임계값이 Kotlin/Dart 양쪽에서 같은 값이어야 한다', () {
      final kotlinSource = _read(
          'android/app/src/main/kotlin/com/henry/memora/BgContrast.kt');
      final dartSource = _read('lib/services/lock_screen_contrast.dart');

      final kotlinMatch =
          RegExp(r'LUMINANCE_THRESHOLD\s*=\s*([0-9]+(?:\.[0-9]+)?)')
              .firstMatch(kotlinSource);
      expect(kotlinMatch, isNotNull,
          reason:
              'Kotlin BgContrast.LUMINANCE_THRESHOLD 상수를 찾지 못했다. 이름이 바뀌었다면 '
              '이 테스트도 함께 고칠 것.');

      final dartMatch = RegExp(
              r'kLockScreenLuminanceThreshold\s*=\s*([0-9]+(?:\.[0-9]+)?)')
          .firstMatch(dartSource);
      expect(dartMatch, isNotNull,
          reason: 'Dart kLockScreenLuminanceThreshold 상수를 찾지 못했다. 이름이 '
              '바뀌었다면 이 테스트도 함께 고칠 것.');

      expect(dartMatch!.group(1), kotlinMatch!.group(1), reason: '''
Kotlin BgContrast.LUMINANCE_THRESHOLD(${kotlinMatch.group(1)})와
Dart kLockScreenLuminanceThreshold(${dartMatch.group(1)})가 다른 값이다.

두 값이 갈라지면 설정 화면의 라이브 미리보기(Dart)가 보여주는 텍스트 색과 실제
잠금화면(Kotlin, 네이티브 오버레이)에 뜨는 텍스트 색이 특정 배경색 구간에서
서로 어긋난다.
''');
    });

    test('BgContrast/lock_screen_contrast 공식이 동일한 가중치를 써야 한다', () {
      final kotlinSource = _read(
          'android/app/src/main/kotlin/com/henry/memora/BgContrast.kt');
      final dartSource = _read('lib/services/lock_screen_contrast.dart');
      const weights = ['0.2126', '0.7152', '0.0722'];
      for (final w in weights) {
        expect(kotlinSource.contains(w), isTrue,
            reason: 'BgContrast.kt에서 WCAG 가중치 $w 를 찾지 못했다.');
        expect(dartSource.contains(w), isTrue,
            reason: 'lock_screen_contrast.dart에서 WCAG 가중치 $w 를 찾지 못했다.');
      }
    });
  });
}
