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
}
