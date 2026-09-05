import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:memora/services/memk_import_service.dart';
import 'package:memora/models/card.dart';
import 'package:memora/models/folder.dart';
import 'package:memora/utils/constants.dart';

void main() {
  group('MemkImportService - extractFileName', () {
    test('.memk 경로에서 파일명 추출', () {
      expect(
        MemkImportService.extractFileName(
          '/data/user/0/com.metastudiolab.memorize/files/image/R_119076ce-app-1567343095060.jpg',
        ),
        'R_119076ce-app-1567343095060.jpg',
      );
    });

    test('단순 파일명은 그대로 반환', () {
      expect(
        MemkImportService.extractFileName('R_abc.jpg'),
        'R_abc.jpg',
      );
    });

    test('빈 문자열은 빈 문자열 반환', () {
      expect(MemkImportService.extractFileName(''), '');
    });

    test('Windows 백슬래시 경로에서 파일명 추출', () {
      expect(
        MemkImportService.extractFileName(
          r'C:\Users\test\images\R_abc.jpg',
        ),
        'R_abc.jpg',
      );
    });

    test('혼합 경로 (/ + \\)에서 파일명 추출', () {
      expect(
        MemkImportService.extractFileName(
          r'path/to\images\test.png',
        ),
        'test.png',
      );
    });
  });

  group('MemkImportService - localImagePath', () {
    test('로컬 이미지 경로 생성', () {
      final result = MemkImportService.localImagePath(
        '/data/data/com.example/files',
        'R_abc.jpg',
      );
      expect(result, contains(AppConstants.imageDir));
      expect(result, contains('R_abc.jpg'));
    });
  });

  group('folders.json 파싱', () {
    test('PRD Section 10 샘플 데이터 파싱', () {
      const sampleFoldersJson = '''[
        {
          "cardCount": 13992,
          "folderCount": 0,
          "id": 3,
          "isDirty": false,
          "isSelected": false,
          "isSpecialFolder": false,
          "modified": "Aug 17, 2019 16:25:16 GMT+09:00",
          "name": "영단어",
          "parent": false,
          "sequence": 0
        }
      ]''';

      final List<dynamic> parsed = jsonDecode(sampleFoldersJson);
      final folderData = parsed[0] as Map<String, dynamic>;

      expect(folderData['name'], '영단어');
      expect(folderData['cardCount'], 13992);
      expect(folderData['id'], 3);

      // Folder.fromJson으로 변환 가능한지 확인
      final folder = Folder.fromJson(folderData);
      expect(folder.name, '영단어');
      expect(folder.cardCount, 13992);
      expect(folder.parent, false);
      expect(folder.isSpecialFolder, false);
    });

    // ('여러 폴더 파싱' 테스트 삭제 — dart:convert의 jsonDecode만 검증하고 프로덕션 코드를
    //  한 줄도 부르지 않는 항등식이었다. 감사 Z2-02.)
  });

  group('cards.json 파싱', () {
    test('PRD Section 10 샘플 카드 파싱', () {
      const sampleCardJson = '''{
        "id": 1,
        "uuid": "2efd2549-e801-40c1-aa54-2e40d401ec50-browser-1567343095060",
        "folderId": 3,
        "folderName": "영단어",
        "question": "deprecate",
        "answer": "v-to not approve of something...",
        "answerImagePath": "/data/user/0/com.metastudiolab.memorize/files/image/R_119076ce-app-1567343095060.jpg",
        "answerImageRatio": 0.6666666666666666,
        "finished": false,
        "starred": false,
        "starLevel": 0,
        "reversed": false,
        "selected": false,
        "sequence": 1,
        "sequence2": 865,
        "sequence3": 0,
        "sequence4": 0,
        "modified": "Sep 26, 2024 09:26:25 GMT+09:00"
      }''';

      final cardData = jsonDecode(sampleCardJson) as Map<String, dynamic>;
      final card = CardModel.fromJson(cardData);

      expect(card.uuid,
          '2efd2549-e801-40c1-aa54-2e40d401ec50-browser-1567343095060');
      expect(card.folderId, 3);
      expect(card.question, 'deprecate');
      expect(card.answer, 'v-to not approve of something...');
      expect(card.answerImagePath, contains('R_119076ce'));
      expect(card.answerImageRatio, closeTo(0.6667, 0.001));
      expect(card.finished, false);
      expect(card.sequence2, 865);
    });

    test('이미지 없는 카드 파싱', () {
      const json = '''{
        "id": 2,
        "uuid": "test-uuid-123",
        "folderId": 1,
        "folderName": "테스트",
        "question": "hello",
        "answer": "world",
        "finished": true,
        "starred": false,
        "starLevel": 0,
        "reversed": false,
        "selected": false,
        "sequence": 0,
        "sequence2": 0,
        "sequence3": 0,
        "sequence4": 0
      }''';

      final card = CardModel.fromJson(
        jsonDecode(json) as Map<String, dynamic>,
      );
      expect(card.answerImagePath, isNull);
      expect(card.answerImagePaths, isEmpty);
      expect(card.questionImagePaths, isEmpty);
      expect(card.finished, true);
    });
  });

  group('이미지 경로 변환 (import)', () {
    test('JSON 맵의 이미지 경로가 올바르게 변환됨', () {
      final cardJson = <String, dynamic>{
        'id': 1,
        'uuid': 'test',
        'folderId': 1,
        'question': 'q',
        'answer': 'a',
        'answerImagePath':
            '/data/user/0/com.metastudiolab.memorize/files/image/R_abc.jpg',
        'answerImageRatio': 0.5,
        'finished': false,
        'starred': false,
        'starLevel': 0,
        'reversed': false,
        'selected': false,
        'sequence': 0,
        'sequence2': 0,
        'sequence3': 0,
        'sequence4': 0,
      };

      // extractFileName 유틸리티로 경로 변환 검증
      final fileName = MemkImportService.extractFileName(
        cardJson['answerImagePath'] as String,
      );
      expect(fileName, 'R_abc.jpg');
    });
  });

  // ('카드 필터링 로직' 테스트 삭제 — 테스트 파일 안의 where 두 줄을 스스로 검증하는 항등식
  //  이었다. 실제 필터는 memk_import_service.dart의 selectedFolderSet 경로인데 그 코드는
  //  한 줄도 실행되지 않았다. 감사 Z2-02.)
}
