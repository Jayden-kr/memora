import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:memora/models/card.dart';
import 'package:memora/screens/card_edit_screen.dart';
import 'package:memora/services/import_export_controller.dart';

/// 감사 클러스터 20(import/export)에서 순수 함수로 뽑아낸 두 규칙의 회귀 그물.
void main() {
  group('ImportExportController.sanitizeFileName (D7-14)', () {
    test('금지 문자는 _로, 앞뒤 공백 제거, 빈 결과는 export', () {
      expect(ImportExportController.sanitizeFileName(' a/b:c*d '), 'a_b_c_d');
      expect(ImportExportController.sanitizeFileName('   '), 'export');
      expect(ImportExportController.sanitizeFileName('///'), '___');
    });

    test('긴 ASCII 이름은 200바이트 안으로 잘린다', () {
      final long = 'a' * 300;
      final out = ImportExportController.sanitizeFileName(long);
      expect(utf8.encode(out).length, lessThanOrEqualTo(200));
      expect(out, isNotEmpty);
    });

    test('멀티바이트 이름은 글자 경계에서 잘린다(깨진 UTF-8 없음)', () {
      final long = '가' * 100; // 300바이트
      final out = ImportExportController.sanitizeFileName(long);
      final bytes = utf8.encode(out);
      expect(bytes.length, lessThanOrEqualTo(200));
      // 3바이트 글자만 있으므로 길이는 3의 배수 = 글자 경계에서 잘렸다
      expect(bytes.length % 3, 0);
      expect(utf8.decode(bytes, allowMalformed: false), out);
    });

    test('짧은 이름은 그대로', () {
      expect(ImportExportController.sanitizeFileName('영단어 3장'), '영단어 3장');
    });
  });

  group('CardEditScreen.changedDbFields (X3-02)', () {
    final before = CardModel(
      id: 7,
      uuid: 'u',
      folderId: 1,
      question: 'q',
      answer: 'a',
      questionImagePath: '', // 시작 GC가 남긴 빈 문자열
      questionVoiceRecordPath: '/x/voice.m4a',
      questionVoiceRecordLength: 1200,
    );

    test('아무것도 안 바꾸면(경로 ""→null 정규화만) 빈 맵', () {
      final after = before.copyWith(questionImagePath: null);
      // copyWith가 null을 "변경 없음"으로 다룰 수 있으니 직접 만든다
      final afterExplicit = CardModel(
        id: 7,
        uuid: 'u',
        folderId: 1,
        question: 'q',
        answer: 'a',
        questionImagePath: null,
        questionVoiceRecordPath: '/x/voice.m4a',
        questionVoiceRecordLength: 1200,
        sequence: before.sequence,
        modified: before.modified,
      );
      expect(CardEditScreen.changedDbFields(before, after), isEmpty);
      expect(CardEditScreen.changedDbFields(before, afterExplicit), isEmpty);
    });

    test('바뀐 컬럼만 들어가고 id는 절대 안 들어간다', () {
      final after = before.copyWith(question: 'q2', modified: 'now');
      final changed = CardEditScreen.changedDbFields(before, after);
      expect(changed.keys.toSet(), {'question', 'modified'});
      expect(changed['question'], 'q2');
      expect(changed.containsKey('id'), isFalse);
      // 이 화면이 노출하지 않는 컬럼(음성 슬롯 등)은 손대지 않는다
      expect(changed.containsKey('question_voice_record_path'), isFalse);
      expect(changed.containsKey('answer_hand_image_path'), isFalse);
    });

    test('경로를 실제로 지우면(값→null) 변경으로 잡힌다', () {
      final after = CardModel(
        id: 7,
        uuid: 'u',
        folderId: 1,
        question: 'q',
        answer: 'a',
        questionImagePath: null,
        questionVoiceRecordPath: null,
        questionVoiceRecordLength: 0,
        sequence: before.sequence,
        modified: before.modified,
      );
      final changed = CardEditScreen.changedDbFields(before, after);
      expect(changed.containsKey('question_voice_record_path'), isTrue);
      expect(changed['question_voice_record_path'], isNull);
      expect(changed.containsKey('question_voice_record_length'), isTrue);
    });
  });
}
