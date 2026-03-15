import 'package:flutter_test/flutter_test.dart';
import 'package:amki_wang/models/card.dart';

void main() {
  final sampleJson = {
    'id': 1,
    'uuid': '2efd2549-e801-40c1-aa54-2e40d401ec50-browser-1567343095060',
    'folderId': 3,
    'folderName': '영단어',
    'question': 'deprecate',
    'answer': 'v-to not approve of something',
    'answerImagePath':
        '/data/user/0/com.metastudiolab.memorize/files/image/R_119076ce-test.jpg',
    'answerImageRatio': 0.6666666666666666,
    'answerImagePath2': null,
    'answerImageRatio2': null,
    'questionImagePath': null,
    'questionImageRatio': null,
    'finished': false,
    'starred': false,
    'starLevel': 0,
    'reversed': false,
    'selected': false,
    'sequence': 1,
    'sequence2': 865,
    'sequence3': 0,
    'sequence4': 0,
    'modified': 'Sep 26, 2024 09:26:25 GMT+09:00',
  };

  final sampleDbMap = {
    'id': 1,
    'uuid': '2efd2549-e801-40c1-aa54-2e40d401ec50-browser-1567343095060',
    'folder_id': 3,
    'question': 'deprecate',
    'answer': 'v-to not approve of something',
    'answer_image_path':
        '/data/user/0/com.metastudiolab.memorize/files/image/R_119076ce-test.jpg',
    'answer_image_ratio': 0.6666666666666666,
    'answer_image_path_2': null,
    'answer_image_ratio_2': null,
    'question_image_path': null,
    'question_image_ratio': null,
    'finished': 0,
    'starred': 0,
    'star_level': 0,
    'reversed': 0,
    'selected': 0,
    'sequence': 1,
    'sequence2': 865,
    'sequence3': 0,
    'sequence4': 0,
    'modified': 'Sep 26, 2024 09:26:25 GMT+09:00',
  };

  group('CardModel.fromJson → toJson round-trip', () {
    test('기본 필드 보존', () {
      final card = CardModel.fromJson(sampleJson);
      final json = card.toJson();

      expect(json['uuid'], sampleJson['uuid']);
      expect(json['folderId'], sampleJson['folderId']);
      expect(json['question'], sampleJson['question']);
      expect(json['answer'], sampleJson['answer']);
      expect(json['answerImagePath'], sampleJson['answerImagePath']);
      expect(json['answerImageRatio'], sampleJson['answerImageRatio']);
      expect(json['sequence'], sampleJson['sequence']);
      expect(json['sequence2'], sampleJson['sequence2']);
      expect(json['modified'], sampleJson['modified']);
    });

    test('bool 필드 보존', () {
      final card = CardModel.fromJson(sampleJson);
      final json = card.toJson();

      expect(json['finished'], false);
      expect(json['starred'], false);
      expect(json['reversed'], false);
      expect(json['selected'], false);
    });
  });

  group('CardModel.fromDb → toDb round-trip', () {
    test('기본 필드 보존', () {
      final card = CardModel.fromDb(sampleDbMap);
      final db = card.toDb();

      expect(db['uuid'], sampleDbMap['uuid']);
      expect(db['folder_id'], sampleDbMap['folder_id']);
      expect(db['question'], sampleDbMap['question']);
      expect(db['answer'], sampleDbMap['answer']);
      expect(db['answer_image_path'], sampleDbMap['answer_image_path']);
      expect(db['answer_image_ratio'], sampleDbMap['answer_image_ratio']);
    });

    test('bool → int 변환', () {
      final card = CardModel.fromDb(sampleDbMap);
      final db = card.toDb();

      expect(db['finished'], 0);
      expect(db['starred'], 0);
      expect(db['reversed'], 0);
      expect(db['selected'], 0);
    });

    test('finished=1이면 bool true로 변환', () {
      final dbMap = Map<String, dynamic>.from(sampleDbMap);
      dbMap['finished'] = 1;
      final card = CardModel.fromDb(dbMap);
      expect(card.finished, true);
      expect(card.toDb()['finished'], 1);
    });
  });

  group('전체 round-trip: JSON → DB → JSON', () {
    test('JSON → Dart → DB map → Dart → JSON', () {
      final card1 = CardModel.fromJson(sampleJson);
      final dbMap = card1.toDb();
      // DB에서는 folderName 없음 — folder_id로 조회
      final card2 = CardModel.fromDb(dbMap);
      final json2 = card2.toJson();

      expect(json2['uuid'], sampleJson['uuid']);
      expect(json2['question'], sampleJson['question']);
      expect(json2['answer'], sampleJson['answer']);
      expect(json2['answerImagePath'], sampleJson['answerImagePath']);
      expect(json2['finished'], sampleJson['finished']);
      expect(json2['sequence2'], sampleJson['sequence2']);
    });
  });

  group('이미지 경로 getter', () {
    test('answerImagePaths — non-null만 반환', () {
      final card = CardModel.fromJson(sampleJson);
      expect(card.answerImagePaths, hasLength(1));
      expect(card.answerImagePaths.first, sampleJson['answerImagePath']);
    });

    test('questionImagePaths — 이미지 없으면 빈 리스트', () {
      final card = CardModel.fromJson(sampleJson);
      expect(card.questionImagePaths, isEmpty);
    });

    test('이미지 5장 모두 있는 카드', () {
      final json = Map<String, dynamic>.from(sampleJson);
      json['answerImagePath'] = 'img1.jpg';
      json['answerImagePath2'] = 'img2.jpg';
      json['answerImagePath3'] = 'img3.jpg';
      json['answerImagePath4'] = 'img4.jpg';
      json['answerImagePath5'] = 'img5.jpg';
      final card = CardModel.fromJson(json);
      expect(card.answerImagePaths, hasLength(5));
    });
  });

  group('빈 카드', () {
    test('최소 필드로 생성', () {
      final json = {
        'uuid': 'test-uuid',
        'folderId': 1,
      };
      final card = CardModel.fromJson(json);
      expect(card.question, '');
      expect(card.answer, '');
      expect(card.answerImagePaths, isEmpty);
      expect(card.questionImagePaths, isEmpty);
      expect(card.finished, false);
      expect(card.sequence, 0);
    });
  });

  group('_parseBool String 호환', () {
    test('String "true" → true', () {
      final json = {
        'uuid': 'test-uuid',
        'folderId': 1,
        'finished': 'true',
        'starred': 'TRUE',
      };
      final card = CardModel.fromJson(json);
      expect(card.finished, true);
      expect(card.starred, true);
    });

    test('String "1" → true', () {
      final json = {
        'uuid': 'test-uuid',
        'folderId': 1,
        'finished': '1',
      };
      final card = CardModel.fromJson(json);
      expect(card.finished, true);
    });

    test('String "false" → false', () {
      final json = {
        'uuid': 'test-uuid',
        'folderId': 1,
        'finished': 'false',
        'starred': '0',
      };
      final card = CardModel.fromJson(json);
      expect(card.finished, false);
      expect(card.starred, false);
    });

    test('null → false', () {
      final json = {
        'uuid': 'test-uuid',
        'folderId': 1,
        'finished': null,
      };
      final card = CardModel.fromJson(json);
      expect(card.finished, false);
    });
  });
}
