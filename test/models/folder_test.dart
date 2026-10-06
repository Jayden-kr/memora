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
