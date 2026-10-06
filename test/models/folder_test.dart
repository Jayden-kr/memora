import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:memora/models/folder.dart';

void main() {
  final sampleJson = {
    'cardCount': 13992,
    'folderCount': 0,
    'id': 3,
    'isDirty': false,
    'isSelected': false,
    'isSpecialFolder': false,
    'modified': 'Aug 17, 2019 16:25:16 GMT+09:00',
    'name': '영단어',
    'parent': false,
    'sequence': 0,
  };

  final sampleDbMap = {
    'id': 3,
    'name': '영단어',
    'card_count': 13992,
    'folder_count': 0,
    'sequence': 0,
    'original_sequence': 0,
    'modified': 'Aug 17, 2019 16:25:16 GMT+09:00',
    'parent': 0,
    'parent_folder_id': null,
    'parent_folder_name': null,
    'is_special_folder': 0,
    'is_bundle': 0,
  };

  group('Folder.fromJson → toJson round-trip', () {
    test('기본 필드 보존', () {
      final folder = Folder.fromJson(sampleJson);
      final json = folder.toJson();

      expect(json['id'], 3);
      expect(json['name'], '영단어');
      expect(json['cardCount'], 13992);
      expect(json['folderCount'], 0);
      expect(json['sequence'], 0);
      expect(json['modified'], 'Aug 17, 2019 16:25:16 GMT+09:00');
    });

    test('bool 필드 보존', () {
      final folder = Folder.fromJson(sampleJson);
      final json = folder.toJson();

      expect(json['parent'], false);
      expect(json['isSpecialFolder'], false);
      // isDirty, isSelected은 기본값으로 출력
      expect(json['isDirty'], false);
      expect(json['isSelected'], false);
    });
  });

  group('Folder.fromDb → toDb round-trip', () {
    test('기본 필드 보존', () {
      final folder = Folder.fromDb(sampleDbMap);
      final db = folder.toDb();

      expect(db['id'], 3);
      expect(db['name'], '영단어');
      expect(db['card_count'], 13992);
      expect(db['folder_count'], 0);
      expect(db['sequence'], 0);
      expect(db['modified'], 'Aug 17, 2019 16:25:16 GMT+09:00');
    });

    test('bool → int 변환', () {
      final folder = Folder.fromDb(sampleDbMap);
      final db = folder.toDb();

      expect(db['parent'], 0);
      expect(db['is_special_folder'], 0);
    });

    test('parent=1이면 bool true로 변환', () {
      final dbMap = Map<String, dynamic>.from(sampleDbMap);
      dbMap['parent'] = 1;
      dbMap['is_special_folder'] = 1;
      final folder = Folder.fromDb(dbMap);
      expect(folder.parent, true);
      expect(folder.isSpecialFolder, true);
      expect(folder.toDb()['parent'], 1);
      expect(folder.toDb()['is_special_folder'], 1);
    });
  });

  group('전체 round-trip: JSON → DB → JSON', () {
    test('JSON → Dart → DB map → Dart → JSON', () {
      final folder1 = Folder.fromJson(sampleJson);
      final dbMap = folder1.toDb();
      final folder2 = Folder.fromDb(dbMap);
      final json2 = folder2.toJson();

      expect(json2['name'], sampleJson['name']);
      expect(json2['cardCount'], sampleJson['cardCount']);
      expect(json2['parent'], sampleJson['parent']);
      expect(json2['isSpecialFolder'], sampleJson['isSpecialFolder']);
      expect(json2['modified'], sampleJson['modified']);
    });
  });

  group('toDb — parent_folder_name', () {
    test('toDb()는 parent_folder_name을 절대 쓰지 않는다', () {
      // parent_folder_name 컬럼은 실재하지만 조회 쪽(getNonBundleFolders 등)이
      // LEFT JOIN으로 매번 새로 채우는 파생값이라 믿을 수 없다. getAllFolders()는
      // `SELECT *`라 이 원본 컬럼을 그대로 읽으므로, toDb()가 되쓰면 그 순간의
      // 부모 이름이 영구 고정돼 updateFolder를 지운 이유였던 낡음 버그(D1-03/
      // D8-09)가 돌아온다(리뷰 발견). parentFolderName이 채워진(=JOIN으로 막
      // 조회해 온 상황을 흉내낸) Folder라도 toDb()는 그 값을 흘리면 안 된다.
      final dbMap = Map<String, dynamic>.from(sampleDbMap);
      final folder = Folder.fromDb(dbMap).copyWith(parentFolderName: '어떤묶음');
      expect(folder.parentFolderName, '어떤묶음'); // 전제 확인
      expect(folder.toDb().containsKey('parent_folder_name'), false);
    });
  });

  group('copyWith', () {
    test('이름 변경', () {
      final folder = Folder.fromJson(sampleJson);
      final updated = folder.copyWith(name: '일본어');
      expect(updated.name, '일본어');
      expect(updated.cardCount, folder.cardCount);
    });
  });

  group('isBundle', () {
    test('JSON round-trip — isBundle=false 기본값', () {
      final folder = Folder.fromJson(sampleJson);
      expect(folder.isBundle, false);
      final json = folder.toJson();
      expect(json['isBundle'], false);
    });

    test('JSON round-trip — isBundle=true', () {
      final jsonWithBundle = Map<String, dynamic>.from(sampleJson);
      jsonWithBundle['isBundle'] = true;
      final folder = Folder.fromJson(jsonWithBundle);
      expect(folder.isBundle, true);
      final json = folder.toJson();
      expect(json['isBundle'], true);
    });

    test('DB round-trip — is_bundle=0', () {
      final folder = Folder.fromDb(sampleDbMap);
      expect(folder.isBundle, false);
      final db = folder.toDb();
      expect(db['is_bundle'], 0);
    });

    test('DB round-trip — is_bundle=1', () {
      final dbMap = Map<String, dynamic>.from(sampleDbMap);
      dbMap['is_bundle'] = 1;
      final folder = Folder.fromDb(dbMap);
      expect(folder.isBundle, true);
      expect(folder.toDb()['is_bundle'], 1);
    });

    test('copyWith isBundle', () {
      final folder = Folder.fromJson(sampleJson);
      final bundle = folder.copyWith(isBundle: true);
      expect(bundle.isBundle, true);
      expect(bundle.name, folder.name);
    });
  });

  group('icon / iconColor', () {
    test('JSON round-trip — 값 보존', () {
      final jsonWithIcon = Map<String, dynamic>.from(sampleJson)
        ..['icon'] = 'star'
        ..['iconColor'] = 0xFF2196F3;
      final folder = Folder.fromJson(jsonWithIcon);
      expect(folder.icon, 'star');
      expect(folder.iconColor, 0xFF2196F3);
      final json = folder.toJson();
      expect(json['icon'], 'star');
      expect(json['iconColor'], 0xFF2196F3);
    });

    test('DB round-trip — 값 보존', () {
      final dbMap = Map<String, dynamic>.from(sampleDbMap)
        ..['icon'] = 'heart'
        ..['icon_color'] = 0xFFFF0000;
      final folder = Folder.fromDb(dbMap);
      expect(folder.icon, 'heart');
      expect(folder.iconColor, 0xFFFF0000);
      final db = folder.toDb();
      expect(db['icon'], 'heart');
      expect(db['icon_color'], 0xFFFF0000);
    });

    test('전체 round-trip: JSON → DB → JSON', () {
      final jsonWithIcon = Map<String, dynamic>.from(sampleJson)
        ..['icon'] = 'school'
        ..['iconColor'] = 0xFF112233;
      final json2 = Folder.fromDb(Folder.fromJson(jsonWithIcon).toDb()).toJson();
      expect(json2['icon'], 'school');
      expect(json2['iconColor'], 0xFF112233);
    });

    test('옛 JSON/DB 맵(키 없음) → null, toJson/toDb는 키를 null로 낸다', () {
      final fromJson = Folder.fromJson(sampleJson);
      expect(fromJson.icon, isNull);
      expect(fromJson.iconColor, isNull);
      final fromDb = Folder.fromDb(sampleDbMap);
      expect(fromDb.icon, isNull);
      expect(fromDb.iconColor, isNull);

      final json = fromJson.toJson();
      expect(json.containsKey('icon'), true);
      expect(json.containsKey('iconColor'), true);
      expect(json['icon'], isNull);
      expect(json['iconColor'], isNull);
      final db = fromDb.toDb();
      expect(db.containsKey('icon'), true);
      expect(db.containsKey('icon_color'), true);
      expect(db['icon'], isNull);
      expect(db['icon_color'], isNull);
    });

    test('타입이 틀린 JSON 값(icon:123, iconColor:"red")은 던지지 않고 null', () {
      // Folder.fromJson은 import의 try 바깥에서 돈다 — 던지면 가져오기 전체가 죽는다.
      final bad = Map<String, dynamic>.from(sampleJson)
        ..['icon'] = 123
        ..['iconColor'] = 'red';
      late Folder folder;
      expect(() => folder = Folder.fromJson(bad), returnsNormally);
      expect(folder.icon, isNull);
      expect(folder.iconColor, isNull);
    });

    test('빈 문자열 icon은 null로 본다', () {
      final empty = Map<String, dynamic>.from(sampleJson)..['icon'] = '';
      expect(Folder.fromJson(empty).icon, isNull);
    });

    test('iconColor는 실수(double)로 와도 정수로 읽는다', () {
      final dbl = Map<String, dynamic>.from(sampleJson)
        ..['iconColor'] = 4280391411.0;
      expect(Folder.fromJson(dbl).iconColor, 4280391411);
    });

    // ── iconColor 경계(검증 L1): 던지지 않고, 0..0xFFFFFFFF 정수값만 받고, 나머지는 null ──
    // Folder.fromJson은 import의 try 바깥에서 돈다 — 한 폴더의 이상한 색이 던지면 가져오기
    // 전체가 죽는다. 그래서 모든 케이스가 returnsNormally + 기대값을 같이 본다.
    Folder parseColor(Object? v) =>
        Folder.fromJson(Map<String, dynamic>.from(sampleJson)..['iconColor'] = v);

    test('iconColor: JSON `1e400`(jsonDecode가 Infinity로 읽음)도 던지지 않고 null', () {
      final decoded = jsonDecode('{"name": "x", "id": 1, "iconColor": 1e400}')
          as Map<String, dynamic>;
      // 전제: 이 입력이 실제로 Infinity가 돼야 이 테스트가 L1을 재현한다.
      expect(decoded['iconColor'], double.infinity);

      late Folder folder;
      expect(() => folder = Folder.fromJson(decoded), returnsNormally);
      expect(folder.iconColor, isNull);
      expect(folder.name, 'x'); // 색만 버리고 나머지 필드는 정상 파싱
    });

    final rejectedColors = <String, Object?>{
      'NaN': double.nan,
      '+Infinity': double.infinity,
      '-Infinity': double.negativeInfinity,
      '음수 정수 -1': -1,
      '음수 실수 -4280391411.0': -4280391411.0,
      '32비트 초과 정수 0x100000000': 0x100000000,
      '32비트 초과 실수 4294967296.0': 4294967296.0,
      '유한하지만 거대한 실수 1e300': 1e300,
      '소수 1.5': 1.5,
      '소수 0.5': 0.5,
      '소수 4280391411.5': 4280391411.5,
    };
    rejectedColors.forEach((label, value) {
      test('iconColor 거부 → null, 던지지 않음: $label', () {
        late Folder folder;
        expect(() => folder = parseColor(value), returnsNormally);
        expect(folder.iconColor, isNull);
      });
    });

    final acceptedColors = <String, (Object?, int)>{
      '하한 0': (0, 0),
      '하한 0.0': (0.0, 0),
      '음의 0(-0.0)': (-0.0, 0),
      '상한 0xFFFFFFFF': (0xFFFFFFFF, 0xFFFFFFFF),
      '상한 실수 4294967295.0': (4294967295.0, 0xFFFFFFFF),
      '불투명 파랑 0xFF2196F3': (0xFF2196F3, 0xFF2196F3),
    };
    acceptedColors.forEach((label, c) {
      test('iconColor 허용: $label', () {
        expect(parseColor(c.$1).iconColor, c.$2);
      });
    });

    // ── icon 키 모양(검증 L3): ^[a-z_]{1,32}$ 만 받는다 ──
    Folder parseIcon(Object? v) =>
        Folder.fromJson(Map<String, dynamic>.from(sampleJson)..['icon'] = v);

    final acceptedKeys = <String, String>{
      "표에 있는 키 'star'": 'star',
      "표에 없는 모양-맞는 미래 키 'new_key'": 'new_key',
      '밑줄만 "_"': '_',
      '1자 "a"': 'a',
      '정확히 32자': 'a' * 32,
    };
    acceptedKeys.forEach((label, key) {
      test('icon 키 허용·그대로 보존: $label', () {
        expect(parseIcon(key).icon, key);
      });
    });

    final rejectedKeys = <String, String>{
      '대문자 시작 "Star"': 'Star',
      '전부 대문자 "STAR"': 'STAR',
      '33자(한 글자 초과)': 'a' * 33,
      '수 MB짜리 문자열(CursorWindow 방어)': 'a' * (2 * 1024 * 1024),
      '공백 포함 "my star"': 'my star',
      '앞 공백 " star"': ' star',
      '뒤 공백 "star "': 'star ',
      // Dart의 $는 (멀티라인 아님) 입력 맨 끝에만 걸린다 — 끝 개행이 슬쩍 통과하면 안 된다.
      '뒤 개행 "star\\n"': 'star\n',
      '숫자 포함 "star2"': 'star2',
      '하이픈 "new-key"': 'new-key',
      '비ASCII "별"': '별',
    };
    rejectedKeys.forEach((label, key) {
      test('icon 키 거부 → null, 던지지 않음: $label', () {
        late Folder folder;
        expect(() => folder = parseIcon(key), returnsNormally);
        expect(folder.icon, isNull);
      });
    });

    // ── 글자 아이콘: 't:' + 이모지·글자 1~2개(그래핌), 최대 32 UTF-16 코드 단위 ──
    // 한도는 읽을 때(가져오기·그리기) 검사한다. 글자는 전부 \u 이스케이프로 적는다 —
    // 소스 인코딩·편집기에 따라 이모지가 조용히 바뀌는 일을 막는다.
    // ⚠️ 아래 목록은 lib/models/folder.dart의 글자 아이콘 한도·문자 집합과 한 쌍이다.
    final family = '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}\u200D\u{1F466}'; // 11 단위
    final scotland =
        '\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}'; // 14 단위
    final acceptedTexts = <String, String>{
      '국기 이스라엘(지역 표시 문자 2개 = 1글자)': '\u{1F1EE}\u{1F1F1}',
      '다윗의 별 + VS16': '\u2721\uFE0F',
      '이모지 책': '\u{1F4D6}',
      '히브리어 알레프': '\u05D0',
      '히브리어 2글자': '\u05D0\u05D1',
      '히라가나 あ': '\u3042',
      '한자 2글자 日本': '\u65E5\u672C',
      '라틴 대문자 EN': 'EN',
      '라틴 소문자 en': 'en',
      '분해형 é(e + U+0301) = 1글자': 'e\u0301',
      '키캡 숫자 1(1 + VS16 + U+20E3) = 1글자':'1\uFE0F\u20E3',
      '가족 이모지(ZWJ) 2개 = 22 단위': '$family$family',
      '스코틀랜드 깃발 2개 = 28 단위': '$scotland$scotland',
      '정확히 32 단위(a + 결합문자 30 + b, 2글자)': 'a${'\u0301' * 30}b',
    };
    acceptedTexts.forEach((label, glyph) {
      test('글자 아이콘 허용·그대로 보존: $label', () {
        final stored = 't:$glyph';
        expect(parseIcon(stored).icon, stored);
        expect(Folder.iconTextOf(stored), glyph);
        expect(Folder.normalizeIconText(glyph), glyph);
      });
    });

    test('경계 단위 수 확인: 가족 11·스코틀랜드 14·32단위 케이스', () {
      // 위 허용 목록이 정말 단위 상한(32)에 걸리는 값인지 못박는다.
      expect(family.length, 11);
      expect(scotland.length, 14);
      expect('a${'\u0301' * 30}b'.length, Folder.iconTextMaxCodeUnits);
      expect('$family$family'.length, 22);
      expect('$scotland$scotland'.length, 28);
    });

    final rejectedTexts = <String, String>{
      '접두사만 "t:"': 't:',
      '접두사 + 공백 한 칸': 't: ',
      '앞 공백 "t: A"(정규형 아님)': 't: A',
      '뒤 공백 "t:A "(정규형 아님)': 't:A ',
      '앞 BOM(U+FEFF)': 't:\uFEFFA',
      '3글자 "ABC"': 't:ABC',
      '국기 3개': 't:${'\u{1F1EE}\u{1F1F1}' * 3}',
      '결합문자 도배 41 단위': 't:a${'\u0301' * 40}',
      '33 단위(a + 결합문자 31 + b)': 't:a${'\u0301' * 31}b',
      '접두사 + 수 MB 문자열': 't:${'a' * (2 * 1024 * 1024)}',
      '접두사 없는 수 MB 문자열': 'a' * (2 * 1024 * 1024),
      '제어문자 BEL 섞임': 't:A\u0007',
      'NUL만': 't:\u0000',
      '개행 섞임': 't:A\nB',
      '폭 없는 공백 U+200B만': 't:\u200B',
      '한글 채움 U+3164만': 't:\u3164',
      '변이 선택자 U+FE0F만': 't:\uFE0F',
      '짝 없는 서로게이트': 't:\uD83C',
      '접두사 대문자 "T:A"': 'T:A',
      '다른 접두사 "x:A"': 'x:A',
    };
    rejectedTexts.forEach((label, value) {
      test('글자 아이콘 거부 → null, 던지지 않음: $label', () {
        late Folder folder;
        expect(() => folder = parseIcon(value), returnsNormally);
        expect(folder.icon, isNull);
        expect(Folder.iconTextOf(value), isNull);
      });
    });

    // ── 안 보이는 글자 표(lib/models/folder.dart isInvisibleIconRune)의 모든 항목 ──
    // 항목(범위는 양 끝·가운데)마다 그 글자만 있는 값이 거부돼야 한다 — 항목 하나를 표에서
    // 지우면 그 줄이 빨개진다. ⚠️ folder.dart 표를 고치면 아래 표도 같이 고칠 것.
    final invisibleTable = <String, (int, int)>{
      'U+00AD 소프트 하이픈': (0x00AD, 0x00AD),
      'U+034F 결합 그래핌 접합자': (0x034F, 0x034F),
      'U+061C 아랍 글자 표시': (0x061C, 0x061C),
      'U+115F 한글 초성 채움': (0x115F, 0x115F),
      'U+1160 한글 중성 채움': (0x1160, 0x1160),
      'U+17B4 크메르 내재 모음 AQ': (0x17B4, 0x17B4),
      'U+17B5 크메르 내재 모음 AA': (0x17B5, 0x17B5),
      'U+180B–180F 몽골 변이 선택자·모음 구분자': (0x180B, 0x180F),
      'U+1BCA0–1BCA3 속기 서식 문자': (0x1BCA0, 0x1BCA3),
      'U+200B–200F 폭 없는 공백·연결자·방향 표시': (0x200B, 0x200F),
      'U+202A–202E 방향 포함·재정의': (0x202A, 0x202E),
      'U+2060–206F 단어 접합자·보이지 않는 연산자·폐기 서식': (0x2060, 0x206F),
      'U+2800 점자 빈칸': (0x2800, 0x2800),
      'U+3164 한글 채움': (0x3164, 0x3164),
      'U+FE00–FE0F 변이 선택자': (0xFE00, 0xFE0F),
      'U+FEFF BOM(폭 없는 공백)': (0xFEFF, 0xFEFF),
      'U+FFA0 반각 한글 채움': (0xFFA0, 0xFFA0),
      'U+1D173–1D17A 음악 서식 문자': (0x1D173, 0x1D17A),
      'U+E0000–E0FFF 태그·변이 선택자 보충': (0xE0000, 0xE0FFF),
    };
    bool inTable(int cp) =>
        invisibleTable.values.any((r) => cp >= r.$1 && cp <= r.$2);

    invisibleTable.forEach((label, range) {
      final (lo, hi) = range;
      // 양 끝과 가운데(범위가 아니면 같은 값 하나).
      final probes = {lo, hi, (lo + hi) ~/ 2};
      test('안 보이는 글자만 있는 값은 거부: $label', () {
        for (final cp in probes) {
          final glyph = String.fromCharCode(cp);
          final hex = 'U+${cp.toRadixString(16).toUpperCase()}';
          expect(Folder.isInvisibleIconRune(cp), isTrue, reason: '$hex 가 표에서 빠졌다');
          expect(Folder.normalizeIconText(glyph), isNull, reason: '$hex 만 있는 값이 통과했다');
          late Folder folder;
          expect(() => folder = parseIcon('t:$glyph'), returnsNormally);
          expect(folder.icon, isNull, reason: '$hex 만 있는 "t:" 값이 통과했다');
          expect(Folder.iconTextOf('t:$glyph'), isNull);
        }
      });

      test('표는 범위 전체를 덮고 바로 바깥(이웃)은 덮지 않는다: $label', () {
        for (var cp = lo; cp <= hi; cp++) {
          expect(Folder.isInvisibleIconRune(cp), isTrue,
              reason: 'U+${cp.toRadixString(16).toUpperCase()} 가 표에서 빠졌다');
        }
        for (final neighbor in [lo - 1, hi + 1]) {
          if (inTable(neighbor)) continue; // 이웃 항목(예: U+115F|U+1160)이 덮는 칸
          expect(Folder.isInvisibleIconRune(neighbor), isFalse,
              reason: 'U+${neighbor.toRadixString(16).toUpperCase()} 까지 표가 넓어졌다');
        }
      });
    });

    test('보이는 글자와 안 보이는 글자가 섞이면 허용(이모지의 변이 선택자·접합자는 보이는 글자에 붙는다)', () {
      expect(Folder.normalizeIconText('A\u2800'), 'A\u2800');
      expect(Folder.normalizeIconText('\u2800A'), '\u2800A');
      expect(Folder.normalizeIconText('\u2721\uFE0F'), '\u2721\uFE0F');
    });

    test('키와 글자 모양은 겹치지 않는다: 접두사 없는 "en"은 모르는 키, 글자가 아니다', () {
      expect(parseIcon('en').icon, 'en');
      expect(Folder.iconTextOf('en'), isNull);
      expect(Folder.iconTextOf('star'), isNull);
      expect(Folder.iconTextOf(null), isNull);
      expect(Folder.iconTextOf(''), isNull);
      expect(Folder.iconTextPrefix, 't:');
    });

    test('normalizeIconText: 앞뒤 공백(전각 포함)은 벗기고, 쓸 수 없으면 null', () {
      expect(Folder.normalizeIconText(' \u05D0 '), '\u05D0');
      expect(Folder.normalizeIconText('\u3000EN\u3000'), 'EN');
      expect(Folder.normalizeIconText(''), isNull);
      expect(Folder.normalizeIconText('   '), isNull);
      expect(Folder.normalizeIconText('\n'), isNull);
      expect(Folder.normalizeIconText('ABC'), isNull);
      expect(Folder.normalizeIconText('A\nB'), isNull);
      expect(Folder.normalizeIconText('\u200B'), isNull);
      expect(Folder.normalizeIconText('a${'\u0301' * 40}'), isNull);
    });

    test('글자 아이콘 round-trip: JSON → DB → JSON 에서 글자·색 보존', () {
      final flag = 't:\u{1F1EE}\u{1F1F1}';
      final json = Map<String, dynamic>.from(sampleJson)
        ..['icon'] = flag
        ..['iconColor'] = 0xFFFF0000;
      final db = Folder.fromJson(json).toDb();
      expect(db['icon'], flag);
      final json2 = Folder.fromDb(db).toJson();
      expect(json2['icon'], flag);
      expect(json2['iconColor'], 0xFFFF0000);
      expect(Folder.iconTextOf(json2['icon'] as String?), '\u{1F1EE}\u{1F1F1}');
    });

    test('copyWith(icon: 글자 아이콘)은 값을 그대로 넣고 다른 필드는 유지한다', () {
      final folder = Folder.fromJson(Map<String, dynamic>.from(sampleJson)
        ..['icon'] = 'star'
        ..['iconColor'] = 0xFF2196F3);
      final changed = folder.copyWith(icon: 't:\u05D0');
      expect(changed.icon, 't:\u05D0');
      expect(changed.iconColor, 0xFF2196F3);
      expect(changed.name, folder.name);
    });

    test('copyWith(icon: null, iconColor: null)은 지우고, 다른 필드 변경은 유지한다', () {
      final folder = Folder.fromJson(Map<String, dynamic>.from(sampleJson)
        ..['icon'] = 'star'
        ..['iconColor'] = 0xFF2196F3);

      final cleared = folder.copyWith(icon: null, iconColor: null);
      expect(cleared.icon, isNull);
      expect(cleared.iconColor, isNull);

      final renamed = folder.copyWith(name: '일본어');
      expect(renamed.icon, 'star');
      expect(renamed.iconColor, 0xFF2196F3);

      final changed = folder.copyWith(icon: 'heart', iconColor: 0xFFFF0000);
      expect(changed.icon, 'heart');
      expect(changed.iconColor, 0xFFFF0000);
    });
  });
}
