// DB 테스트 하네스. sqflite_common_ffi로 실제 SQLite(디스크 파일)를 띄우고,
// path_provider의 getApplicationDocumentsDirectory()를 임시 디렉토리로 모킹한다.
//
// 그룹마다 setUp/tearDown에서 이 파일의 initDbTestEnv/tearDownDbTestEnv를 쓸 것.
// tearDown 순서가 중요하다: DB 핸들을 먼저 닫은 뒤(resetForTesting) 임시 디렉토리를
// 지운다 — 반대로 하면 Windows에서 파일이 열려 있어 삭제가 실패한다.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:memora/database/database_helper.dart';
import 'package:memora/models/card.dart';
import 'package:memora/models/folder.dart';
import 'package:memora/utils/constants.dart';

bool _ffiReady = false;
int _uuidSeq = 0;

/// 테스트 격리 DB 환경을 만든다. `setUp`에서 호출.
/// - sqflite_common_ffi 데스크톱 백엔드를 (프로세스당 1회) 초기화한다.
/// - `getApplicationDocumentsDirectory()`를 새 임시 디렉토리로 모킹한다.
/// 반환된 디렉토리를 [tearDownDbTestEnv]에 그대로 넘길 것.
Future<Directory> initDbTestEnv() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!_ffiReady) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    _ffiReady = true;
  }
  final docs = await Directory.systemTemp.createTemp('memora_db_test');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (MethodCall call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return docs.path;
      }
      return null;
    },
  );
  return docs;
}

/// [initDbTestEnv]로 만든 환경을 정리한다. `tearDown`에서 호출.
/// 순서 고정: DB 핸들을 먼저 닫고(그래야 Windows가 파일 삭제를 허용한다) 그 다음
/// 임시 디렉토리를 지운다. 삭제 실패는 삼킨다(파일 잠금 등, 테스트 결과에 영향 없음).
Future<void> tearDownDbTestEnv(Directory docs) async {
  await DatabaseHelper.resetForTesting();
  try {
    await docs.delete(recursive: true);
  } catch (_) {
    // Windows 파일 잠금 등 — 무시. OS 임시 폴더 청소는 이 테스트의 책임이 아니다.
  }
}

/// 테스트용 카드 하나. `overrides`는 [CardModel.fromDb]가 읽는 **DB 컬럼명**
/// (snake_case) 기준이다 — 예: `overrides: {'answer_image_path': 'a'}`.
/// uuid를 생략하면 프로세스 내에서 유일한 값을 자동 생성한다.
CardModel fixtureCard({
  required int folderId,
  String? uuid,
  String question = '',
  int sequence = 0,
  Map<String, Object?> overrides = const {},
}) {
  final map = <String, Object?>{
    'uuid': uuid ?? 'fixture-card-uuid-${_uuidSeq++}',
    'folder_id': folderId,
    'question': question,
    'sequence': sequence,
    ...overrides,
  };
  return CardModel.fromDb(map);
}

/// 테스트용 폴더 하나. 이름은 `idx_folders_name` UNIQUE 제약이 있으니 같은 테스트
/// 안에서 폴더를 여러 개 만들 때는 서로 다른 `name`을 넘길 것.
Folder fixtureFolder({
  String name = 'F',
  int sequence = 0,
  bool isBundle = false,
  int? parentFolderId,
}) {
  return Folder(
    name: name,
    sequence: sequence,
    isBundle: isBundle,
    parentFolderId: parentFolderId,
  );
}

/// 레거시 스키마(v1/v2/v3)로 DB 파일을 직접 만든다 — `onCreate`/`onUpgrade`를 거치지
/// 않는다. 그 뒤 [DatabaseHelper.instance.database]로 열면 `_upgradeDB`가
/// v(version)→4로 실제 프로덕션 경로를 그대로 탄다.
Future<void> openLegacyDb(Directory docs, int version) async {
  final path = p.join(docs.path, AppConstants.dbName);
  final db = await databaseFactoryFfi.openDatabase(path);
  try {
    await _createLegacySchema(db, version);
  } finally {
    await db.execute('PRAGMA user_version = $version');
    await db.close();
  }
}

/// [database_helper.dart]의 `_createDB`(v4 fresh create)를 기준으로, 각 버전에서
/// 아직 없었던 부분을 뺀 DDL. `_upgradeDB`의 각 `if (oldVersion < N)` 분기와
/// 정확히 짝이 맞아야 한다:
///  - v1: is_bundle 없음, exported_files/push_alarms 없음, idx_cards_folder_seq 없음
///  - v2: v1 + is_bundle + exported_files + push_alarms(mode/start_time/end_time/interval_min 없음)
///  - v3: v2 + push_alarms에 그 네 컬럼 추가
/// (idx_cards_folder_seq는 오직 `_upgradeDB`의 `oldVersion < 4` 분기에서만 생기므로
/// v1/v2/v3 전부 이 인덱스가 없는 채로 만든다.)
Future<void> _createLegacySchema(Database db, int version) async {
  await db.execute('''
    CREATE TABLE ${AppConstants.tableFolders} (
      id                INTEGER PRIMARY KEY AUTOINCREMENT,
      name              TEXT NOT NULL,
      card_count        INTEGER NOT NULL DEFAULT 0,
      folder_count      INTEGER NOT NULL DEFAULT 0,
      sequence          INTEGER NOT NULL DEFAULT 0,
      original_sequence INTEGER NOT NULL DEFAULT 0,
      modified          TEXT,
      parent            INTEGER NOT NULL DEFAULT 0,
      parent_folder_id  INTEGER,
      parent_folder_name TEXT,
      is_special_folder INTEGER NOT NULL DEFAULT 0
      ${version >= 2 ? ', is_bundle INTEGER NOT NULL DEFAULT 0' : ''}
    )
  ''');

  await db.execute('''
    CREATE UNIQUE INDEX idx_folders_name ON ${AppConstants.tableFolders}(name)
  ''');

  await db.execute('''
    CREATE TABLE ${AppConstants.tableCards} (
      id                    INTEGER PRIMARY KEY AUTOINCREMENT,
      uuid                  TEXT UNIQUE NOT NULL,
      folder_id             INTEGER NOT NULL REFERENCES ${AppConstants.tableFolders}(id) ON DELETE CASCADE,
      question              TEXT NOT NULL DEFAULT '',
      answer                TEXT NOT NULL DEFAULT '',
      question_image_path   TEXT,
      question_image_ratio  REAL,
      question_image_path_2 TEXT,
      question_image_ratio_2 REAL,
      question_image_path_3 TEXT,
      question_image_ratio_3 REAL,
      question_image_path_4 TEXT,
      question_image_ratio_4 REAL,
      question_image_path_5 TEXT,
      question_image_ratio_5 REAL,
      answer_image_path     TEXT,
      answer_image_ratio    REAL,
      answer_image_path_2   TEXT,
      answer_image_ratio_2  REAL,
      answer_image_path_3   TEXT,
      answer_image_ratio_3  REAL,
      answer_image_path_4   TEXT,
      answer_image_ratio_4  REAL,
      answer_image_path_5   TEXT,
      answer_image_ratio_5  REAL,
      question_hand_image_path  TEXT,
      question_hand_image_path_2 TEXT,
      question_hand_image_path_3 TEXT,
      question_hand_image_path_4 TEXT,
      question_hand_image_path_5 TEXT,
      question_hand_image_ratio  REAL,
      answer_hand_image_path    TEXT,
      answer_hand_image_path_2  TEXT,
      answer_hand_image_path_3  TEXT,
      answer_hand_image_path_4  TEXT,
      answer_hand_image_path_5  TEXT,
      answer_hand_image_ratio   REAL,
      question_voice_record_path  TEXT,
      question_voice_record_path_2 TEXT,
      question_voice_record_path_3 TEXT,
      question_voice_record_path_4 TEXT,
      question_voice_record_path_5 TEXT,
      question_voice_record_path_6 TEXT,
      question_voice_record_path_7 TEXT,
      question_voice_record_path_8 TEXT,
      question_voice_record_path_9 TEXT,
      question_voice_record_path_10 TEXT,
      question_voice_record_length INTEGER,
      answer_voice_record_path   TEXT,
      answer_voice_record_path_2 TEXT,
      answer_voice_record_path_3 TEXT,
      answer_voice_record_path_4 TEXT,
      answer_voice_record_path_5 TEXT,
      answer_voice_record_path_6 TEXT,
      answer_voice_record_path_7 TEXT,
      answer_voice_record_path_8 TEXT,
      answer_voice_record_path_9 TEXT,
      answer_voice_record_path_10 TEXT,
      answer_voice_record_length  INTEGER,
      finished              INTEGER NOT NULL DEFAULT 0,
      starred               INTEGER NOT NULL DEFAULT 0,
      star_level            INTEGER NOT NULL DEFAULT 0,
      reversed              INTEGER NOT NULL DEFAULT 0,
      selected              INTEGER NOT NULL DEFAULT 0,
      sequence              INTEGER NOT NULL DEFAULT 0,
      sequence2             INTEGER NOT NULL DEFAULT 0,
      sequence3             INTEGER NOT NULL DEFAULT 0,
      sequence4             INTEGER NOT NULL DEFAULT 0,
      modified              TEXT
    )
  ''');

  await db.execute('''
    CREATE INDEX idx_cards_folder_id ON ${AppConstants.tableCards}(folder_id)
  ''');
  await db.execute('''
    CREATE INDEX idx_cards_finished ON ${AppConstants.tableCards}(finished)
  ''');
  await db.execute('''
    CREATE INDEX idx_cards_uuid ON ${AppConstants.tableCards}(uuid)
  ''');

  await db.execute('''
    CREATE TABLE ${AppConstants.tableCounters} (
      id                    INTEGER PRIMARY KEY DEFAULT 1,
      card_sequence         INTEGER NOT NULL DEFAULT 0,
      card_minus_sequence   INTEGER NOT NULL DEFAULT 0,
      folder_sequence       INTEGER NOT NULL DEFAULT 0,
      folder_minus_sequence INTEGER NOT NULL DEFAULT 0
    )
  ''');

  await db.execute('''
    CREATE TABLE ${AppConstants.tableSettings} (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  ''');

  if (version >= 2) {
    await db.execute('''
      CREATE TABLE ${AppConstants.tableExportedFiles} (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        file_name   TEXT NOT NULL,
        file_path   TEXT NOT NULL,
        file_size   INTEGER,
        file_type   TEXT,
        created_at  TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE ${AppConstants.tablePushAlarms} (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        time          TEXT NOT NULL,
        enabled       INTEGER DEFAULT 1,
        folder_id     INTEGER,
        days          TEXT,
        sound_enabled INTEGER DEFAULT 1
        ${version >= 3 ? ", mode TEXT NOT NULL DEFAULT 'fixed', start_time TEXT, end_time TEXT, interval_min INTEGER" : ''}
      )
    ''');
  }

  await db.insert(AppConstants.tableCounters, {
    'id': 1,
    'card_sequence': 0,
    'card_minus_sequence': 0,
    'folder_sequence': 0,
    'folder_minus_sequence': 0,
  });
}
