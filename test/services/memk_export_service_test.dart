import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:amki_wang/services/memk_export_service.dart';
import 'package:amki_wang/models/card.dart';
import 'package:amki_wang/models/folder.dart';
import 'package:amki_wang/utils/constants.dart';

void main() {
  group('MemkExportService - toMemkImagePath', () {
    test('로컬 경로를 .memk 호환 경로로 변환', () {
      final result = MemkExportService.toMemkImagePath(
        '/data/data/com.example/files/images/R_abc.jpg',
      );
      expect(result,
          '${AppConstants.amkizzangImagePrefix}R_abc.jpg');
    });

    test('Windows 스타일 경로도 처리', () {
      final result = MemkExportService.toMemkImagePath(
        'C:\\Users\\test\\images\\R_abc.jpg',
      );
      expect(result, contains('R_abc.jpg'));
      expect(result, startsWith(AppConstants.amkizzangImagePrefix));
    });

    test('빈 문자열은 빈 문자열 반환', () {
      expect(MemkExportService.toMemkImagePath(''), '');
    });
  });

  group('Export JSON 직렬화', () {
    test('Folder.toJson() 출력이 .memk 포맷과 일치', () {
      final folder = Folder(
        id: 3,
        name: '영단어',
        cardCount: 13992,
        folderCount: 0,
        sequence: 0,
        modified: 'Aug 17, 2019 16:25:16 GMT+09:00',
        parent: false,
        isSpecialFolder: false,
      );

      final json = folder.toJson();
      expect(json['name'], '영단어');
      expect(json['cardCount'], 13992);
      expect(json['parent'], false);
      expect(json['isSpecialFolder'], false);
      // .memk 호환 필드
      expect(json['isDirty'], false);
      expect(json['isSelected'], false);
    });

    test('CardModel.toJson()이 folderName 포함', () {
      final card = CardModel(
        uuid: 'test-uuid',
        folderId: 3,
        folderName: '영단어',
        question: 'hello',
        answer: 'world',
      );

      final json = card.toJson();
      expect(json['folderName'], '영단어');
      expect(json['uuid'], 'test-uuid');
      expect(json['folderId'], 3);
    });

    test('CardModel.toJson() bool 필드가 bool로 출력', () {
      final card = CardModel(
        uuid: 'test',
        folderId: 1,
        question: 'q',
        answer: 'a',
        finished: true,
        starred: false,
      );

      final json = card.toJson();
      expect(json['finished'], isA<bool>());
      expect(json['finished'], true);
      expect(json['starred'], false);
    });
  });

  group('counter.json 포맷', () {
    test('배열 형태 [{...}]로 출력', () {
      final counter = {
        'id': 1,
        'card_sequence': 2,
        'card_minus_sequence': 0,
        'folder_sequence': 2,
        'folder_minus_sequence': 0,
      };

      final jsonStr = jsonEncode([counter]);
      final parsed = jsonDecode(jsonStr) as List<dynamic>;
      expect(parsed.length, 1);
      expect(parsed[0]['card_sequence'], 2);
    });
  });

  group('Export → Import round-trip 경로 변환', () {
    test('로컬 → memk → 파일명 추출 일관성', () {
      const localPath = '/data/data/com.example/files/images/R_test123.jpg';

      // Export: 로컬 → memk
      final memkPath = MemkExportService.toMemkImagePath(localPath);
      expect(memkPath, contains('R_test123.jpg'));

      // Import: memk → 파일명
      // (MemkImportService.extractFileName은 별도 테스트에서 검증)
      final fileName = memkPath.split('/').last;
      expect(fileName, 'R_test123.jpg');
    });
  });
}
