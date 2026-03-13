class CardModel {
  final int? id;
  final String uuid;
  final int folderId;
  final String? folderName; // JSON only, not in DB
  final String question;
  final String answer;

  // 앞면 이미지 (최대 5장)
  final String? questionImagePath;
  final double? questionImageRatio;
  final String? questionImagePath2;
  final double? questionImageRatio2;
  final String? questionImagePath3;
  final double? questionImageRatio3;
  final String? questionImagePath4;
  final double? questionImageRatio4;
  final String? questionImagePath5;
  final double? questionImageRatio5;

  // 뒷면 이미지 (최대 5장)
  final String? answerImagePath;
  final double? answerImageRatio;
  final String? answerImagePath2;
  final double? answerImageRatio2;
  final String? answerImagePath3;
  final double? answerImageRatio3;
  final String? answerImagePath4;
  final double? answerImageRatio4;
  final String? answerImagePath5;
  final double? answerImageRatio5;

  // 손글씨 이미지 (UI 없음, 데이터 보존)
  final String? questionHandImagePath;
  final String? questionHandImagePath2;
  final String? questionHandImagePath3;
  final String? questionHandImagePath4;
  final String? questionHandImagePath5;
  final double? questionHandImageRatio;
  final String? answerHandImagePath;
  final String? answerHandImagePath2;
  final String? answerHandImagePath3;
  final String? answerHandImagePath4;
  final String? answerHandImagePath5;
  final double? answerHandImageRatio;

  // 음성 녹음 (UI 없음, 데이터 보존)
  final String? questionVoiceRecordPath;
  final String? questionVoiceRecordPath2;
  final String? questionVoiceRecordPath3;
  final String? questionVoiceRecordPath4;
  final String? questionVoiceRecordPath5;
  final String? questionVoiceRecordPath6;
  final String? questionVoiceRecordPath7;
  final String? questionVoiceRecordPath8;
  final String? questionVoiceRecordPath9;
  final String? questionVoiceRecordPath10;
  final int? questionVoiceRecordLength;
  final String? answerVoiceRecordPath;
  final String? answerVoiceRecordPath2;
  final String? answerVoiceRecordPath3;
  final String? answerVoiceRecordPath4;
  final String? answerVoiceRecordPath5;
  final String? answerVoiceRecordPath6;
  final String? answerVoiceRecordPath7;
  final String? answerVoiceRecordPath8;
  final String? answerVoiceRecordPath9;
  final String? answerVoiceRecordPath10;
  final int? answerVoiceRecordLength;

  // 상태
  final bool finished;
  final bool starred;
  final int starLevel;
  final bool reversed;
  final bool selected;

  // 정렬
  final int sequence;
  final int sequence2;
  final int sequence3;
  final int sequence4;

  // 메타
  final String? modified;

  CardModel({
    this.id,
    required this.uuid,
    required this.folderId,
    this.folderName,
    this.question = '',
    this.answer = '',
    this.questionImagePath,
    this.questionImageRatio,
    this.questionImagePath2,
    this.questionImageRatio2,
    this.questionImagePath3,
    this.questionImageRatio3,
    this.questionImagePath4,
    this.questionImageRatio4,
    this.questionImagePath5,
    this.questionImageRatio5,
    this.answerImagePath,
    this.answerImageRatio,
    this.answerImagePath2,
    this.answerImageRatio2,
    this.answerImagePath3,
    this.answerImageRatio3,
    this.answerImagePath4,
    this.answerImageRatio4,
    this.answerImagePath5,
    this.answerImageRatio5,
    this.questionHandImagePath,
    this.questionHandImagePath2,
    this.questionHandImagePath3,
    this.questionHandImagePath4,
    this.questionHandImagePath5,
    this.questionHandImageRatio,
    this.answerHandImagePath,
    this.answerHandImagePath2,
    this.answerHandImagePath3,
    this.answerHandImagePath4,
    this.answerHandImagePath5,
    this.answerHandImageRatio,
    this.questionVoiceRecordPath,
    this.questionVoiceRecordPath2,
    this.questionVoiceRecordPath3,
    this.questionVoiceRecordPath4,
    this.questionVoiceRecordPath5,
    this.questionVoiceRecordPath6,
    this.questionVoiceRecordPath7,
    this.questionVoiceRecordPath8,
    this.questionVoiceRecordPath9,
    this.questionVoiceRecordPath10,
    this.questionVoiceRecordLength,
    this.answerVoiceRecordPath,
    this.answerVoiceRecordPath2,
    this.answerVoiceRecordPath3,
    this.answerVoiceRecordPath4,
    this.answerVoiceRecordPath5,
    this.answerVoiceRecordPath6,
    this.answerVoiceRecordPath7,
    this.answerVoiceRecordPath8,
    this.answerVoiceRecordPath9,
    this.answerVoiceRecordPath10,
    this.answerVoiceRecordLength,
    this.finished = false,
    this.starred = false,
    this.starLevel = 0,
    this.reversed = false,
    this.selected = false,
    this.sequence = 0,
    this.sequence2 = 0,
    this.sequence3 = 0,
    this.sequence4 = 0,
    this.modified,
  });

  /// 앞면 이미지 경로 리스트 (non-null, non-empty만)
  List<String> get questionImagePaths => [
        questionImagePath,
        questionImagePath2,
        questionImagePath3,
        questionImagePath4,
        questionImagePath5,
      ].where((p) => p != null && p.isNotEmpty).cast<String>().toList();

  /// 뒷면 이미지 경로 리스트 (non-null, non-empty만)
  List<String> get answerImagePaths => [
        answerImagePath,
        answerImagePath2,
        answerImagePath3,
        answerImagePath4,
        answerImagePath5,
      ].where((p) => p != null && p.isNotEmpty).cast<String>().toList();

  /// .memk JSON → Dart
  factory CardModel.fromJson(Map<String, dynamic> json) {
    return CardModel(
      id: json['id'] as int?,
      uuid: json['uuid'] as String,
      folderId: (json['folderId'] as num?)?.toInt() ?? 0,
      folderName: json['folderName'] as String?,
      question: json['question'] as String? ?? '',
      answer: json['answer'] as String? ?? '',
      // 앞면 이미지
      questionImagePath: json['questionImagePath'] as String?,
      questionImageRatio: (json['questionImageRatio'] as num?)?.toDouble(),
      questionImagePath2: json['questionImagePath2'] as String?,
      questionImageRatio2: (json['questionImageRatio2'] as num?)?.toDouble(),
      questionImagePath3: json['questionImagePath3'] as String?,
      questionImageRatio3: (json['questionImageRatio3'] as num?)?.toDouble(),
      questionImagePath4: json['questionImagePath4'] as String?,
      questionImageRatio4: (json['questionImageRatio4'] as num?)?.toDouble(),
      questionImagePath5: json['questionImagePath5'] as String?,
      questionImageRatio5: (json['questionImageRatio5'] as num?)?.toDouble(),
      // 뒷면 이미지
      answerImagePath: json['answerImagePath'] as String?,
      answerImageRatio: (json['answerImageRatio'] as num?)?.toDouble(),
      answerImagePath2: json['answerImagePath2'] as String?,
      answerImageRatio2: (json['answerImageRatio2'] as num?)?.toDouble(),
      answerImagePath3: json['answerImagePath3'] as String?,
      answerImageRatio3: (json['answerImageRatio3'] as num?)?.toDouble(),
      answerImagePath4: json['answerImagePath4'] as String?,
      answerImageRatio4: (json['answerImageRatio4'] as num?)?.toDouble(),
      answerImagePath5: json['answerImagePath5'] as String?,
      answerImageRatio5: (json['answerImageRatio5'] as num?)?.toDouble(),
      // 손글씨
      questionHandImagePath: json['questionHandImagePath'] as String?,
      questionHandImagePath2: json['questionHandImagePath2'] as String?,
      questionHandImagePath3: json['questionHandImagePath3'] as String?,
      questionHandImagePath4: json['questionHandImagePath4'] as String?,
      questionHandImagePath5: json['questionHandImagePath5'] as String?,
      questionHandImageRatio:
          (json['questionHandImageRatio'] as num?)?.toDouble(),
      answerHandImagePath: json['answerHandImagePath'] as String?,
      answerHandImagePath2: json['answerHandImagePath2'] as String?,
      answerHandImagePath3: json['answerHandImagePath3'] as String?,
      answerHandImagePath4: json['answerHandImagePath4'] as String?,
      answerHandImagePath5: json['answerHandImagePath5'] as String?,
      answerHandImageRatio:
          (json['answerHandImageRatio'] as num?)?.toDouble(),
      // 음성
      questionVoiceRecordPath: json['questionVoiceRecordPath'] as String?,
      questionVoiceRecordPath2: json['questionVoiceRecordPath2'] as String?,
      questionVoiceRecordPath3: json['questionVoiceRecordPath3'] as String?,
      questionVoiceRecordPath4: json['questionVoiceRecordPath4'] as String?,
      questionVoiceRecordPath5: json['questionVoiceRecordPath5'] as String?,
      questionVoiceRecordPath6: json['questionVoiceRecordPath6'] as String?,
      questionVoiceRecordPath7: json['questionVoiceRecordPath7'] as String?,
      questionVoiceRecordPath8: json['questionVoiceRecordPath8'] as String?,
      questionVoiceRecordPath9: json['questionVoiceRecordPath9'] as String?,
      questionVoiceRecordPath10: json['questionVoiceRecordPath10'] as String?,
      questionVoiceRecordLength: (json['questionVoiceRecordLength'] as num?)?.toInt(),
      answerVoiceRecordPath: json['answerVoiceRecordPath'] as String?,
      answerVoiceRecordPath2: json['answerVoiceRecordPath2'] as String?,
      answerVoiceRecordPath3: json['answerVoiceRecordPath3'] as String?,
      answerVoiceRecordPath4: json['answerVoiceRecordPath4'] as String?,
      answerVoiceRecordPath5: json['answerVoiceRecordPath5'] as String?,
      answerVoiceRecordPath6: json['answerVoiceRecordPath6'] as String?,
      answerVoiceRecordPath7: json['answerVoiceRecordPath7'] as String?,
      answerVoiceRecordPath8: json['answerVoiceRecordPath8'] as String?,
      answerVoiceRecordPath9: json['answerVoiceRecordPath9'] as String?,
      answerVoiceRecordPath10: json['answerVoiceRecordPath10'] as String?,
      answerVoiceRecordLength: (json['answerVoiceRecordLength'] as num?)?.toInt(),
      // 상태
      finished: _parseBool(json['finished']),
      starred: _parseBool(json['starred']),
      starLevel: (json['starLevel'] as num?)?.toInt() ?? 0,
      reversed: _parseBool(json['reversed']),
      selected: _parseBool(json['selected']),
      // 정렬
      sequence: (json['sequence'] as num?)?.toInt() ?? 0,
      sequence2: (json['sequence2'] as num?)?.toInt() ?? 0,
      sequence3: (json['sequence3'] as num?)?.toInt() ?? 0,
      sequence4: (json['sequence4'] as num?)?.toInt() ?? 0,
      // 메타
      modified: json['modified']?.toString(),
    );
  }

  /// JSON value → bool (handles bool, int 0/1, null)
  static bool _parseBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    return false;
  }

  /// Dart → .memk JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'uuid': uuid,
      'folderId': folderId,
      'folderName': folderName ?? '',
      'question': question,
      'answer': answer,
      // 앞면 이미지
      'questionImagePath': questionImagePath,
      'questionImageRatio': questionImageRatio,
      'questionImagePath2': questionImagePath2,
      'questionImageRatio2': questionImageRatio2,
      'questionImagePath3': questionImagePath3,
      'questionImageRatio3': questionImageRatio3,
      'questionImagePath4': questionImagePath4,
      'questionImageRatio4': questionImageRatio4,
      'questionImagePath5': questionImagePath5,
      'questionImageRatio5': questionImageRatio5,
      // 뒷면 이미지
      'answerImagePath': answerImagePath,
      'answerImageRatio': answerImageRatio,
      'answerImagePath2': answerImagePath2,
      'answerImageRatio2': answerImageRatio2,
      'answerImagePath3': answerImagePath3,
      'answerImageRatio3': answerImageRatio3,
      'answerImagePath4': answerImagePath4,
      'answerImageRatio4': answerImageRatio4,
      'answerImagePath5': answerImagePath5,
      'answerImageRatio5': answerImageRatio5,
      // 손글씨
      'questionHandImagePath': questionHandImagePath,
      'questionHandImagePath2': questionHandImagePath2,
      'questionHandImagePath3': questionHandImagePath3,
      'questionHandImagePath4': questionHandImagePath4,
      'questionHandImagePath5': questionHandImagePath5,
      'questionHandImageRatio': questionHandImageRatio,
      'answerHandImagePath': answerHandImagePath,
      'answerHandImagePath2': answerHandImagePath2,
      'answerHandImagePath3': answerHandImagePath3,
      'answerHandImagePath4': answerHandImagePath4,
      'answerHandImagePath5': answerHandImagePath5,
      'answerHandImageRatio': answerHandImageRatio,
      // 음성
      'questionVoiceRecordPath': questionVoiceRecordPath,
      'questionVoiceRecordPath2': questionVoiceRecordPath2,
      'questionVoiceRecordPath3': questionVoiceRecordPath3,
      'questionVoiceRecordPath4': questionVoiceRecordPath4,
      'questionVoiceRecordPath5': questionVoiceRecordPath5,
      'questionVoiceRecordPath6': questionVoiceRecordPath6,
      'questionVoiceRecordPath7': questionVoiceRecordPath7,
      'questionVoiceRecordPath8': questionVoiceRecordPath8,
      'questionVoiceRecordPath9': questionVoiceRecordPath9,
      'questionVoiceRecordPath10': questionVoiceRecordPath10,
      'questionVoiceRecordLength': questionVoiceRecordLength,
      'answerVoiceRecordPath': answerVoiceRecordPath,
      'answerVoiceRecordPath2': answerVoiceRecordPath2,
      'answerVoiceRecordPath3': answerVoiceRecordPath3,
      'answerVoiceRecordPath4': answerVoiceRecordPath4,
      'answerVoiceRecordPath5': answerVoiceRecordPath5,
      'answerVoiceRecordPath6': answerVoiceRecordPath6,
      'answerVoiceRecordPath7': answerVoiceRecordPath7,
      'answerVoiceRecordPath8': answerVoiceRecordPath8,
      'answerVoiceRecordPath9': answerVoiceRecordPath9,
      'answerVoiceRecordPath10': answerVoiceRecordPath10,
      'answerVoiceRecordLength': answerVoiceRecordLength,
      // 상태
      'finished': finished,
      'starred': starred,
      'starLevel': starLevel,
      'reversed': reversed,
      'selected': selected,
      // 정렬
      'sequence': sequence,
      'sequence2': sequence2,
      'sequence3': sequence3,
      'sequence4': sequence4,
      // 메타
      'modified': modified,
    };
  }

  /// SQLite row → Dart
  factory CardModel.fromDb(Map<String, dynamic> map) {
    return CardModel(
      id: map['id'] as int?,
      uuid: map['uuid'] as String,
      folderId: map['folder_id'] as int,
      question: map['question'] as String? ?? '',
      answer: map['answer'] as String? ?? '',
      // 앞면 이미지
      questionImagePath: map['question_image_path'] as String?,
      questionImageRatio: (map['question_image_ratio'] as num?)?.toDouble(),
      questionImagePath2: map['question_image_path_2'] as String?,
      questionImageRatio2: (map['question_image_ratio_2'] as num?)?.toDouble(),
      questionImagePath3: map['question_image_path_3'] as String?,
      questionImageRatio3: (map['question_image_ratio_3'] as num?)?.toDouble(),
      questionImagePath4: map['question_image_path_4'] as String?,
      questionImageRatio4: (map['question_image_ratio_4'] as num?)?.toDouble(),
      questionImagePath5: map['question_image_path_5'] as String?,
      questionImageRatio5: (map['question_image_ratio_5'] as num?)?.toDouble(),
      // 뒷면 이미지
      answerImagePath: map['answer_image_path'] as String?,
      answerImageRatio: (map['answer_image_ratio'] as num?)?.toDouble(),
      answerImagePath2: map['answer_image_path_2'] as String?,
      answerImageRatio2: (map['answer_image_ratio_2'] as num?)?.toDouble(),
      answerImagePath3: map['answer_image_path_3'] as String?,
      answerImageRatio3: (map['answer_image_ratio_3'] as num?)?.toDouble(),
      answerImagePath4: map['answer_image_path_4'] as String?,
      answerImageRatio4: (map['answer_image_ratio_4'] as num?)?.toDouble(),
      answerImagePath5: map['answer_image_path_5'] as String?,
      answerImageRatio5: (map['answer_image_ratio_5'] as num?)?.toDouble(),
      // 손글씨
      questionHandImagePath: map['question_hand_image_path'] as String?,
      questionHandImagePath2: map['question_hand_image_path_2'] as String?,
      questionHandImagePath3: map['question_hand_image_path_3'] as String?,
      questionHandImagePath4: map['question_hand_image_path_4'] as String?,
      questionHandImagePath5: map['question_hand_image_path_5'] as String?,
      questionHandImageRatio:
          (map['question_hand_image_ratio'] as num?)?.toDouble(),
      answerHandImagePath: map['answer_hand_image_path'] as String?,
      answerHandImagePath2: map['answer_hand_image_path_2'] as String?,
      answerHandImagePath3: map['answer_hand_image_path_3'] as String?,
      answerHandImagePath4: map['answer_hand_image_path_4'] as String?,
      answerHandImagePath5: map['answer_hand_image_path_5'] as String?,
      answerHandImageRatio:
          (map['answer_hand_image_ratio'] as num?)?.toDouble(),
      // 음성
      questionVoiceRecordPath: map['question_voice_record_path'] as String?,
      questionVoiceRecordPath2:
          map['question_voice_record_path_2'] as String?,
      questionVoiceRecordPath3:
          map['question_voice_record_path_3'] as String?,
      questionVoiceRecordPath4:
          map['question_voice_record_path_4'] as String?,
      questionVoiceRecordPath5:
          map['question_voice_record_path_5'] as String?,
      questionVoiceRecordPath6:
          map['question_voice_record_path_6'] as String?,
      questionVoiceRecordPath7:
          map['question_voice_record_path_7'] as String?,
      questionVoiceRecordPath8:
          map['question_voice_record_path_8'] as String?,
      questionVoiceRecordPath9:
          map['question_voice_record_path_9'] as String?,
      questionVoiceRecordPath10:
          map['question_voice_record_path_10'] as String?,
      questionVoiceRecordLength:
          map['question_voice_record_length'] as int?,
      answerVoiceRecordPath: map['answer_voice_record_path'] as String?,
      answerVoiceRecordPath2: map['answer_voice_record_path_2'] as String?,
      answerVoiceRecordPath3: map['answer_voice_record_path_3'] as String?,
      answerVoiceRecordPath4: map['answer_voice_record_path_4'] as String?,
      answerVoiceRecordPath5: map['answer_voice_record_path_5'] as String?,
      answerVoiceRecordPath6: map['answer_voice_record_path_6'] as String?,
      answerVoiceRecordPath7: map['answer_voice_record_path_7'] as String?,
      answerVoiceRecordPath8: map['answer_voice_record_path_8'] as String?,
      answerVoiceRecordPath9: map['answer_voice_record_path_9'] as String?,
      answerVoiceRecordPath10:
          map['answer_voice_record_path_10'] as String?,
      answerVoiceRecordLength: map['answer_voice_record_length'] as int?,
      // 상태
      finished: (map['finished'] as int? ?? 0) == 1,
      starred: (map['starred'] as int? ?? 0) == 1,
      starLevel: map['star_level'] as int? ?? 0,
      reversed: (map['reversed'] as int? ?? 0) == 1,
      selected: (map['selected'] as int? ?? 0) == 1,
      // 정렬
      sequence: map['sequence'] as int? ?? 0,
      sequence2: map['sequence2'] as int? ?? 0,
      sequence3: map['sequence3'] as int? ?? 0,
      sequence4: map['sequence4'] as int? ?? 0,
      // 메타
      modified: map['modified'] as String?,
    );
  }

  /// Dart → SQLite row
  Map<String, dynamic> toDb() {
    final map = <String, dynamic>{
      'uuid': uuid,
      'folder_id': folderId,
      'question': question,
      'answer': answer,
      // 앞면 이미지
      'question_image_path': questionImagePath,
      'question_image_ratio': questionImageRatio,
      'question_image_path_2': questionImagePath2,
      'question_image_ratio_2': questionImageRatio2,
      'question_image_path_3': questionImagePath3,
      'question_image_ratio_3': questionImageRatio3,
      'question_image_path_4': questionImagePath4,
      'question_image_ratio_4': questionImageRatio4,
      'question_image_path_5': questionImagePath5,
      'question_image_ratio_5': questionImageRatio5,
      // 뒷면 이미지
      'answer_image_path': answerImagePath,
      'answer_image_ratio': answerImageRatio,
      'answer_image_path_2': answerImagePath2,
      'answer_image_ratio_2': answerImageRatio2,
      'answer_image_path_3': answerImagePath3,
      'answer_image_ratio_3': answerImageRatio3,
      'answer_image_path_4': answerImagePath4,
      'answer_image_ratio_4': answerImageRatio4,
      'answer_image_path_5': answerImagePath5,
      'answer_image_ratio_5': answerImageRatio5,
      // 손글씨
      'question_hand_image_path': questionHandImagePath,
      'question_hand_image_path_2': questionHandImagePath2,
      'question_hand_image_path_3': questionHandImagePath3,
      'question_hand_image_path_4': questionHandImagePath4,
      'question_hand_image_path_5': questionHandImagePath5,
      'question_hand_image_ratio': questionHandImageRatio,
      'answer_hand_image_path': answerHandImagePath,
      'answer_hand_image_path_2': answerHandImagePath2,
      'answer_hand_image_path_3': answerHandImagePath3,
      'answer_hand_image_path_4': answerHandImagePath4,
      'answer_hand_image_path_5': answerHandImagePath5,
      'answer_hand_image_ratio': answerHandImageRatio,
      // 음성
      'question_voice_record_path': questionVoiceRecordPath,
      'question_voice_record_path_2': questionVoiceRecordPath2,
      'question_voice_record_path_3': questionVoiceRecordPath3,
      'question_voice_record_path_4': questionVoiceRecordPath4,
      'question_voice_record_path_5': questionVoiceRecordPath5,
      'question_voice_record_path_6': questionVoiceRecordPath6,
      'question_voice_record_path_7': questionVoiceRecordPath7,
      'question_voice_record_path_8': questionVoiceRecordPath8,
      'question_voice_record_path_9': questionVoiceRecordPath9,
      'question_voice_record_path_10': questionVoiceRecordPath10,
      'question_voice_record_length': questionVoiceRecordLength,
      'answer_voice_record_path': answerVoiceRecordPath,
      'answer_voice_record_path_2': answerVoiceRecordPath2,
      'answer_voice_record_path_3': answerVoiceRecordPath3,
      'answer_voice_record_path_4': answerVoiceRecordPath4,
      'answer_voice_record_path_5': answerVoiceRecordPath5,
      'answer_voice_record_path_6': answerVoiceRecordPath6,
      'answer_voice_record_path_7': answerVoiceRecordPath7,
      'answer_voice_record_path_8': answerVoiceRecordPath8,
      'answer_voice_record_path_9': answerVoiceRecordPath9,
      'answer_voice_record_path_10': answerVoiceRecordPath10,
      'answer_voice_record_length': answerVoiceRecordLength,
      // 상태
      'finished': finished ? 1 : 0,
      'starred': starred ? 1 : 0,
      'star_level': starLevel,
      'reversed': reversed ? 1 : 0,
      'selected': selected ? 1 : 0,
      // 정렬
      'sequence': sequence,
      'sequence2': sequence2,
      'sequence3': sequence3,
      'sequence4': sequence4,
      // 메타
      'modified': modified,
    };
    if (id != null) {
      map['id'] = id;
    }
    return map;
  }

  static const _absent = Object();

  CardModel copyWith({
    int? id,
    String? uuid,
    int? folderId,
    String? folderName,
    String? question,
    String? answer,
    Object? questionImagePath = _absent,
    Object? questionImageRatio = _absent,
    Object? questionImagePath2 = _absent,
    Object? questionImageRatio2 = _absent,
    Object? questionImagePath3 = _absent,
    Object? questionImageRatio3 = _absent,
    Object? questionImagePath4 = _absent,
    Object? questionImageRatio4 = _absent,
    Object? questionImagePath5 = _absent,
    Object? questionImageRatio5 = _absent,
    Object? answerImagePath = _absent,
    Object? answerImageRatio = _absent,
    Object? answerImagePath2 = _absent,
    Object? answerImageRatio2 = _absent,
    Object? answerImagePath3 = _absent,
    Object? answerImageRatio3 = _absent,
    Object? answerImagePath4 = _absent,
    Object? answerImageRatio4 = _absent,
    Object? answerImagePath5 = _absent,
    Object? answerImageRatio5 = _absent,
    // 손글씨 이미지
    Object? questionHandImagePath = _absent,
    Object? questionHandImagePath2 = _absent,
    Object? questionHandImagePath3 = _absent,
    Object? questionHandImagePath4 = _absent,
    Object? questionHandImagePath5 = _absent,
    Object? questionHandImageRatio = _absent,
    Object? answerHandImagePath = _absent,
    Object? answerHandImagePath2 = _absent,
    Object? answerHandImagePath3 = _absent,
    Object? answerHandImagePath4 = _absent,
    Object? answerHandImagePath5 = _absent,
    Object? answerHandImageRatio = _absent,
    // 음성 녹음
    Object? questionVoiceRecordPath = _absent,
    Object? questionVoiceRecordPath2 = _absent,
    Object? questionVoiceRecordPath3 = _absent,
    Object? questionVoiceRecordPath4 = _absent,
    Object? questionVoiceRecordPath5 = _absent,
    Object? questionVoiceRecordPath6 = _absent,
    Object? questionVoiceRecordPath7 = _absent,
    Object? questionVoiceRecordPath8 = _absent,
    Object? questionVoiceRecordPath9 = _absent,
    Object? questionVoiceRecordPath10 = _absent,
    Object? questionVoiceRecordLength = _absent,
    Object? answerVoiceRecordPath = _absent,
    Object? answerVoiceRecordPath2 = _absent,
    Object? answerVoiceRecordPath3 = _absent,
    Object? answerVoiceRecordPath4 = _absent,
    Object? answerVoiceRecordPath5 = _absent,
    Object? answerVoiceRecordPath6 = _absent,
    Object? answerVoiceRecordPath7 = _absent,
    Object? answerVoiceRecordPath8 = _absent,
    Object? answerVoiceRecordPath9 = _absent,
    Object? answerVoiceRecordPath10 = _absent,
    Object? answerVoiceRecordLength = _absent,
    bool? finished,
    bool? starred,
    int? starLevel,
    bool? reversed,
    bool? selected,
    int? sequence,
    int? sequence2,
    int? sequence3,
    int? sequence4,
    String? modified,
  }) {
    return CardModel(
      id: id ?? this.id,
      uuid: uuid ?? this.uuid,
      folderId: folderId ?? this.folderId,
      folderName: folderName ?? this.folderName,
      question: question ?? this.question,
      answer: answer ?? this.answer,
      questionImagePath: identical(questionImagePath, _absent) ? this.questionImagePath : questionImagePath as String?,
      questionImageRatio: identical(questionImageRatio, _absent) ? this.questionImageRatio : questionImageRatio as double?,
      questionImagePath2: identical(questionImagePath2, _absent) ? this.questionImagePath2 : questionImagePath2 as String?,
      questionImageRatio2: identical(questionImageRatio2, _absent) ? this.questionImageRatio2 : questionImageRatio2 as double?,
      questionImagePath3: identical(questionImagePath3, _absent) ? this.questionImagePath3 : questionImagePath3 as String?,
      questionImageRatio3: identical(questionImageRatio3, _absent) ? this.questionImageRatio3 : questionImageRatio3 as double?,
      questionImagePath4: identical(questionImagePath4, _absent) ? this.questionImagePath4 : questionImagePath4 as String?,
      questionImageRatio4: identical(questionImageRatio4, _absent) ? this.questionImageRatio4 : questionImageRatio4 as double?,
      questionImagePath5: identical(questionImagePath5, _absent) ? this.questionImagePath5 : questionImagePath5 as String?,
      questionImageRatio5: identical(questionImageRatio5, _absent) ? this.questionImageRatio5 : questionImageRatio5 as double?,
      answerImagePath: identical(answerImagePath, _absent) ? this.answerImagePath : answerImagePath as String?,
      answerImageRatio: identical(answerImageRatio, _absent) ? this.answerImageRatio : answerImageRatio as double?,
      answerImagePath2: identical(answerImagePath2, _absent) ? this.answerImagePath2 : answerImagePath2 as String?,
      answerImageRatio2: identical(answerImageRatio2, _absent) ? this.answerImageRatio2 : answerImageRatio2 as double?,
      answerImagePath3: identical(answerImagePath3, _absent) ? this.answerImagePath3 : answerImagePath3 as String?,
      answerImageRatio3: identical(answerImageRatio3, _absent) ? this.answerImageRatio3 : answerImageRatio3 as double?,
      answerImagePath4: identical(answerImagePath4, _absent) ? this.answerImagePath4 : answerImagePath4 as String?,
      answerImageRatio4: identical(answerImageRatio4, _absent) ? this.answerImageRatio4 : answerImageRatio4 as double?,
      answerImagePath5: identical(answerImagePath5, _absent) ? this.answerImagePath5 : answerImagePath5 as String?,
      answerImageRatio5: identical(answerImageRatio5, _absent) ? this.answerImageRatio5 : answerImageRatio5 as double?,
      questionHandImagePath: identical(questionHandImagePath, _absent) ? this.questionHandImagePath : questionHandImagePath as String?,
      questionHandImagePath2: identical(questionHandImagePath2, _absent) ? this.questionHandImagePath2 : questionHandImagePath2 as String?,
      questionHandImagePath3: identical(questionHandImagePath3, _absent) ? this.questionHandImagePath3 : questionHandImagePath3 as String?,
      questionHandImagePath4: identical(questionHandImagePath4, _absent) ? this.questionHandImagePath4 : questionHandImagePath4 as String?,
      questionHandImagePath5: identical(questionHandImagePath5, _absent) ? this.questionHandImagePath5 : questionHandImagePath5 as String?,
      questionHandImageRatio: identical(questionHandImageRatio, _absent) ? this.questionHandImageRatio : questionHandImageRatio as double?,
      answerHandImagePath: identical(answerHandImagePath, _absent) ? this.answerHandImagePath : answerHandImagePath as String?,
      answerHandImagePath2: identical(answerHandImagePath2, _absent) ? this.answerHandImagePath2 : answerHandImagePath2 as String?,
      answerHandImagePath3: identical(answerHandImagePath3, _absent) ? this.answerHandImagePath3 : answerHandImagePath3 as String?,
      answerHandImagePath4: identical(answerHandImagePath4, _absent) ? this.answerHandImagePath4 : answerHandImagePath4 as String?,
      answerHandImagePath5: identical(answerHandImagePath5, _absent) ? this.answerHandImagePath5 : answerHandImagePath5 as String?,
      answerHandImageRatio: identical(answerHandImageRatio, _absent) ? this.answerHandImageRatio : answerHandImageRatio as double?,
      questionVoiceRecordPath: identical(questionVoiceRecordPath, _absent) ? this.questionVoiceRecordPath : questionVoiceRecordPath as String?,
      questionVoiceRecordPath2: identical(questionVoiceRecordPath2, _absent) ? this.questionVoiceRecordPath2 : questionVoiceRecordPath2 as String?,
      questionVoiceRecordPath3: identical(questionVoiceRecordPath3, _absent) ? this.questionVoiceRecordPath3 : questionVoiceRecordPath3 as String?,
      questionVoiceRecordPath4: identical(questionVoiceRecordPath4, _absent) ? this.questionVoiceRecordPath4 : questionVoiceRecordPath4 as String?,
      questionVoiceRecordPath5: identical(questionVoiceRecordPath5, _absent) ? this.questionVoiceRecordPath5 : questionVoiceRecordPath5 as String?,
      questionVoiceRecordPath6: identical(questionVoiceRecordPath6, _absent) ? this.questionVoiceRecordPath6 : questionVoiceRecordPath6 as String?,
      questionVoiceRecordPath7: identical(questionVoiceRecordPath7, _absent) ? this.questionVoiceRecordPath7 : questionVoiceRecordPath7 as String?,
      questionVoiceRecordPath8: identical(questionVoiceRecordPath8, _absent) ? this.questionVoiceRecordPath8 : questionVoiceRecordPath8 as String?,
      questionVoiceRecordPath9: identical(questionVoiceRecordPath9, _absent) ? this.questionVoiceRecordPath9 : questionVoiceRecordPath9 as String?,
      questionVoiceRecordPath10: identical(questionVoiceRecordPath10, _absent) ? this.questionVoiceRecordPath10 : questionVoiceRecordPath10 as String?,
      questionVoiceRecordLength: identical(questionVoiceRecordLength, _absent) ? this.questionVoiceRecordLength : questionVoiceRecordLength as int?,
      answerVoiceRecordPath: identical(answerVoiceRecordPath, _absent) ? this.answerVoiceRecordPath : answerVoiceRecordPath as String?,
      answerVoiceRecordPath2: identical(answerVoiceRecordPath2, _absent) ? this.answerVoiceRecordPath2 : answerVoiceRecordPath2 as String?,
      answerVoiceRecordPath3: identical(answerVoiceRecordPath3, _absent) ? this.answerVoiceRecordPath3 : answerVoiceRecordPath3 as String?,
      answerVoiceRecordPath4: identical(answerVoiceRecordPath4, _absent) ? this.answerVoiceRecordPath4 : answerVoiceRecordPath4 as String?,
      answerVoiceRecordPath5: identical(answerVoiceRecordPath5, _absent) ? this.answerVoiceRecordPath5 : answerVoiceRecordPath5 as String?,
      answerVoiceRecordPath6: identical(answerVoiceRecordPath6, _absent) ? this.answerVoiceRecordPath6 : answerVoiceRecordPath6 as String?,
      answerVoiceRecordPath7: identical(answerVoiceRecordPath7, _absent) ? this.answerVoiceRecordPath7 : answerVoiceRecordPath7 as String?,
      answerVoiceRecordPath8: identical(answerVoiceRecordPath8, _absent) ? this.answerVoiceRecordPath8 : answerVoiceRecordPath8 as String?,
      answerVoiceRecordPath9: identical(answerVoiceRecordPath9, _absent) ? this.answerVoiceRecordPath9 : answerVoiceRecordPath9 as String?,
      answerVoiceRecordPath10: identical(answerVoiceRecordPath10, _absent) ? this.answerVoiceRecordPath10 : answerVoiceRecordPath10 as String?,
      answerVoiceRecordLength: identical(answerVoiceRecordLength, _absent) ? this.answerVoiceRecordLength : answerVoiceRecordLength as int?,
      finished: finished ?? this.finished,
      starred: starred ?? this.starred,
      starLevel: starLevel ?? this.starLevel,
      reversed: reversed ?? this.reversed,
      selected: selected ?? this.selected,
      sequence: sequence ?? this.sequence,
      sequence2: sequence2 ?? this.sequence2,
      sequence3: sequence3 ?? this.sequence3,
      sequence4: sequence4 ?? this.sequence4,
      modified: modified ?? this.modified,
    );
  }
}
