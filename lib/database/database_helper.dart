import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../models/card.dart';
import '../models/folder.dart';
import '../utils/constants.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Completer<Database>? _dbCompleter;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_dbCompleter != null) return _dbCompleter!.future;
    _dbCompleter = Completer<Database>();
    try {
      final db = await _initDB();
      _dbCompleter!.complete(db);
    } catch (e) {
      _dbCompleter!.completeError(e);
      _dbCompleter = null;
      rethrow;
    }
    return _dbCompleter!.future;
  }

  Future<Database> _initDB() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, AppConstants.dbName);
    return await openDatabase(
      path,
      version: AppConstants.dbVersion,
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
    );
  }

  Future<void> _createDB(Database db, int version) async {
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
        is_special_folder INTEGER NOT NULL DEFAULT 0,
        is_bundle         INTEGER NOT NULL DEFAULT 0
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
        sound_enabled INTEGER DEFAULT 1,
        mode          TEXT NOT NULL DEFAULT 'fixed',
        start_time    TEXT,
        end_time      TEXT,
        interval_min  INTEGER
      )
    ''');

    // 초기 카운터 row
    await db.insert(AppConstants.tableCounters, {
      'id': 1,
      'card_sequence': 0,
      'card_minus_sequence': 0,
      'folder_sequence': 0,
      'folder_minus_sequence': 0,
    });
  }

  Future<void> _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute(
          'ALTER TABLE ${AppConstants.tableFolders} ADD COLUMN is_bundle INTEGER NOT NULL DEFAULT 0');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS ${AppConstants.tableExportedFiles} (
          id          INTEGER PRIMARY KEY AUTOINCREMENT,
          file_name   TEXT NOT NULL,
          file_path   TEXT NOT NULL,
          file_size   INTEGER,
          file_type   TEXT,
          created_at  TEXT
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS ${AppConstants.tablePushAlarms} (
          id            INTEGER PRIMARY KEY AUTOINCREMENT,
          time          TEXT NOT NULL,
          enabled       INTEGER DEFAULT 1,
          folder_id     INTEGER,
          days          TEXT,
          sound_enabled INTEGER DEFAULT 1
        )
      ''');
    }
    if (oldVersion < 3) {
      await db.execute(
          "ALTER TABLE ${AppConstants.tablePushAlarms} ADD COLUMN mode TEXT NOT NULL DEFAULT 'fixed'");
      await db.execute(
          'ALTER TABLE ${AppConstants.tablePushAlarms} ADD COLUMN start_time TEXT');
      await db.execute(
          'ALTER TABLE ${AppConstants.tablePushAlarms} ADD COLUMN end_time TEXT');
      await db.execute(
          'ALTER TABLE ${AppConstants.tablePushAlarms} ADD COLUMN interval_min INTEGER');
    }
  }

  // ─── Folder CRUD ───

  Future<int> insertFolder(Folder folder) async {
    final db = await database;
    return await db.insert(AppConstants.tableFolders, folder.toDb());
  }

  Future<List<Folder>> getAllFolders() async {
    final db = await database;
    final maps = await db.query(
      AppConstants.tableFolders,
      orderBy: 'sequence ASC',
    );
    return maps.map((m) => Folder.fromDb(m)).toList();
  }

  Future<List<Folder>> getBundleFolders() async {
    final db = await database;
    final maps = await db.query(
      AppConstants.tableFolders,
      where: 'is_bundle = 1',
      orderBy: 'sequence ASC',
    );
    return maps.map((m) => Folder.fromDb(m)).toList();
  }

  Future<List<Folder>> getNonBundleFolders() async {
    final db = await database;
    final maps = await db.query(
      AppConstants.tableFolders,
      where: 'is_bundle = 0',
      orderBy: 'sequence ASC',
    );
    return maps.map((m) => Folder.fromDb(m)).toList();
  }

  Future<List<Folder>> getChildFolders(int parentId) async {
    final db = await database;
    final maps = await db.query(
      AppConstants.tableFolders,
      where: 'parent_folder_id = ?',
      whereArgs: [parentId],
      orderBy: 'sequence ASC',
    );
    return maps.map((m) => Folder.fromDb(m)).toList();
  }

  Future<Folder?> getFolderById(int id) async {
    final db = await database;
    final maps = await db.query(
      AppConstants.tableFolders,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return Folder.fromDb(maps.first);
  }

  Future<Folder?> getFolderByName(String name) async {
    final db = await database;
    final maps = await db.query(
      AppConstants.tableFolders,
      where: 'name = ?',
      whereArgs: [name],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return Folder.fromDb(maps.first);
  }

  Future<int> updateFolder(Folder folder) async {
    final db = await database;
    final map = folder.toDb();
    map.remove('id'); // id는 WHERE 절에서 사용하므로 SET 절에서 제외
    return await db.update(
      AppConstants.tableFolders,
      map,
      where: 'id = ?',
      whereArgs: [folder.id],
    );
  }

  Future<int> updateFolderSequence(int folderId, int sequence) async {
    final db = await database;
    return await db.update(
      AppConstants.tableFolders,
      {'sequence': sequence},
      where: 'id = ?',
      whereArgs: [folderId],
    );
  }

  /// 폴더 시퀀스 일괄 업데이트 (트랜잭션 사용)
  Future<void> updateFolderSequencesBatch(
      Map<int, int> folderIdToSequence) async {
    final db = await database;
    await db.transaction((txn) async {
      for (final entry in folderIdToSequence.entries) {
        await txn.update(
          AppConstants.tableFolders,
          {'sequence': entry.value},
          where: 'id = ?',
          whereArgs: [entry.key],
        );
      }
    });
  }

  Future<int> deleteFolder(int id) async {
    final db = await database;
    return await db.delete(
      AppConstants.tableFolders,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 삭제된 폴더를 참조하는 push_alarms의 folder_id를 NULL로 변경.
  /// (알람 자체는 유지 — 사용자의 시간/간격 설정 보존, 동작은 '전체 폴더' 모드로 fallback)
  /// 영향받은 행 수 반환.
  Future<int> clearFolderRefInPushAlarms(int folderId) async {
    final db = await database;
    return await db.update(
      AppConstants.tablePushAlarms,
      {'folder_id': null},
      where: 'folder_id = ?',
      whereArgs: [folderId],
    );
  }

  /// 묶음 폴더 삭제: 자식 폴더 해제 + 묶음 삭제를 원자적으로 실행
  Future<void> deleteBundleFolder(int bundleId) async {
    final db = await database;
    await db.transaction((txn) async {
      // 자식 폴더의 parent_folder_id 해제
      await txn.update(
        AppConstants.tableFolders,
        {'parent_folder_id': null},
        where: 'parent_folder_id = ?',
        whereArgs: [bundleId],
      );
      // 묶음 폴더 삭제
      await txn.delete(
        AppConstants.tableFolders,
        where: 'id = ?',
        whereArgs: [bundleId],
      );
    });
  }

  Future<void> updateFolderCardCount(int folderId) async {
    final db = await database;
    final count = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM ${AppConstants.tableCards} WHERE folder_id = ?',
      [folderId],
    )) ?? 0;
    await db.update(
      AppConstants.tableFolders,
      {'card_count': count},
      where: 'id = ?',
      whereArgs: [folderId],
    );
  }

  Future<int> getMaxFolderSequence() async {
    final db = await database;
    return Sqflite.firstIntValue(await db.rawQuery(
      'SELECT MAX(sequence) FROM ${AppConstants.tableFolders}',
    )) ?? 0;
  }

  // ─── Card CRUD ───

  Future<int> insertCard(CardModel card) async {
    final db = await database;
    return await db.insert(AppConstants.tableCards, card.toDb());
  }

  Future<List<CardModel>> getCardsByFolderId(
    int folderId, {
    int? limit,
    int? offset,
    int? finished,
  }) async {
    final db = await database;
    String where = 'folder_id = ?';
    List<dynamic> whereArgs = [folderId];
    if (finished != null) {
      where += ' AND finished = ?';
      whereArgs.add(finished);
    }
    final maps = await db.query(
      AppConstants.tableCards,
      where: where,
      whereArgs: whereArgs,
      orderBy: 'sequence ASC',
      limit: limit,
      offset: offset,
    );
    return maps.map((m) => CardModel.fromDb(m)).toList();
  }

  Future<CardModel?> getCardById(int id) async {
    final db = await database;
    final maps = await db.query(
      AppConstants.tableCards,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return CardModel.fromDb(maps.first);
  }

  Future<CardModel?> getCardByUuid(String uuid) async {
    final db = await database;
    final maps = await db.query(
      AppConstants.tableCards,
      where: 'uuid = ?',
      whereArgs: [uuid],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return CardModel.fromDb(maps.first);
  }

  Future<int> updateCard(CardModel card) async {
    final db = await database;
    final map = card.toDb();
    map.remove('id'); // id는 WHERE 절에서 사용하므로 SET 절에서 제외
    return await db.update(
      AppConstants.tableCards,
      map,
      where: 'id = ?',
      whereArgs: [card.id],
    );
  }

  Future<int> deleteCard(int id) async {
    final db = await database;
    return await db.delete(
      AppConstants.tableCards,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> countCardsByFolderId(int folderId, {int? finished}) async {
    final db = await database;
    String where = 'folder_id = ?';
    List<dynamic> whereArgs = [folderId];
    if (finished != null) {
      where += ' AND finished = ?';
      whereArgs.add(finished);
    }
    return Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM ${AppConstants.tableCards} WHERE $where',
      whereArgs,
    )) ?? 0;
  }

  /// 여러 폴더의 카드 수를 한번에 조회 (N+1 방지)
  Future<int> countCardsByFolderIds(List<int> folderIds) async {
    if (folderIds.isEmpty) return 0;
    final db = await database;
    final placeholders = List.filled(folderIds.length, '?').join(',');
    return Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM ${AppConstants.tableCards} WHERE folder_id IN ($placeholders)',
      folderIds,
    )) ?? 0;
  }

  Future<int> moveCard(int cardId, int newFolderId) async {
    final db = await database;
    int result = 0;
    await db.transaction((txn) async {
      // 이동 전 원래 폴더 ID 조회
      final card = await txn.query(
        AppConstants.tableCards,
        columns: ['folder_id'],
        where: 'id = ?',
        whereArgs: [cardId],
        limit: 1,
      );
      final oldFolderId = card.isNotEmpty ? card.first['folder_id'] as int? : null;

      result = await txn.update(
        AppConstants.tableCards,
        {'folder_id': newFolderId},
        where: 'id = ?',
        whereArgs: [cardId],
      );

      // 원본/대상 폴더의 card_count 갱신 (트랜잭션 내 원자적 실행)
      if (result > 0) {
        if (oldFolderId != null && oldFolderId != newFolderId) {
          final oldCount = Sqflite.firstIntValue(await txn.rawQuery(
            'SELECT COUNT(*) FROM ${AppConstants.tableCards} WHERE folder_id = ?',
            [oldFolderId],
          )) ?? 0;
          await txn.update(AppConstants.tableFolders, {'card_count': oldCount},
              where: 'id = ?', whereArgs: [oldFolderId]);
        }
        final newCount = Sqflite.firstIntValue(await txn.rawQuery(
          'SELECT COUNT(*) FROM ${AppConstants.tableCards} WHERE folder_id = ?',
          [newFolderId],
        )) ?? 0;
        await txn.update(AppConstants.tableFolders, {'card_count': newCount},
            where: 'id = ?', whereArgs: [newFolderId]);
      }
    });
    return result;
  }

  Future<int> getMaxSequence(int folderId) async {
    final db = await database;
    return Sqflite.firstIntValue(await db.rawQuery(
      'SELECT MAX(sequence) FROM ${AppConstants.tableCards} WHERE folder_id = ?',
      [folderId],
    )) ?? 0;
  }

  /// 이미지/음성 경로 컬럼 목록 (import 시 복구용)
  static const _pathColumns = [
    'question_image_path', 'question_image_path_2', 'question_image_path_3',
    'question_image_path_4', 'question_image_path_5',
    'answer_image_path', 'answer_image_path_2', 'answer_image_path_3',
    'answer_image_path_4', 'answer_image_path_5',
    'question_hand_image_path', 'question_hand_image_path_2',
    'question_hand_image_path_3', 'question_hand_image_path_4',
    'question_hand_image_path_5',
    'answer_hand_image_path', 'answer_hand_image_path_2',
    'answer_hand_image_path_3', 'answer_hand_image_path_4',
    'answer_hand_image_path_5',
    'question_voice_record_path', 'question_voice_record_path_2',
    'question_voice_record_path_3', 'question_voice_record_path_4',
    'question_voice_record_path_5', 'question_voice_record_path_6',
    'question_voice_record_path_7', 'question_voice_record_path_8',
    'question_voice_record_path_9', 'question_voice_record_path_10',
    'answer_voice_record_path', 'answer_voice_record_path_2',
    'answer_voice_record_path_3', 'answer_voice_record_path_4',
    'answer_voice_record_path_5', 'answer_voice_record_path_6',
    'answer_voice_record_path_7', 'answer_voice_record_path_8',
    'answer_voice_record_path_9', 'answer_voice_record_path_10',
  ];

  /// 카드 배치 insert (transaction) — Import 시 사용
  /// UUID 중복 카드는 비어있는 이미지 경로를 복구 (재import 시 깨진 이미지 수정)
  /// 반환: (inserted: 실제 삽입 수, skipped: UUID 중복으로 건너뜀 수)
  Future<({int inserted, int skipped})> insertCardsBatch(List<CardModel> cards,
      {ConflictAlgorithm conflictAlgorithm = ConflictAlgorithm.ignore}) async {
    final db = await database;
    int inserted = 0;
    int skipped = 0;
    await db.transaction((txn) async {
      for (final card in cards) {
        final dbMap = card.toDb();
        final result = await txn.insert(AppConstants.tableCards, dbMap,
            conflictAlgorithm: conflictAlgorithm);
        if (result > 0) {
          inserted++;
        } else {
          skipped++;
          // UUID 중복 — 비어있는 이미지 경로 복구
          final uuid = dbMap['uuid'] as String?;
          if (uuid == null || uuid.isEmpty) continue;
          final existing = await txn.query(
            AppConstants.tableCards,
            columns: ['id', ..._pathColumns],
            where: 'uuid = ?',
            whereArgs: [uuid],
            limit: 1,
          );
          if (existing.isEmpty) continue;
          final updates = <String, dynamic>{};
          for (final col in _pathColumns) {
            final existingVal = existing.first[col] as String? ?? '';
            final newVal = dbMap[col] as String? ?? '';
            if (existingVal.isEmpty && newVal.isNotEmpty) {
              updates[col] = newVal;
            }
          }
          if (updates.isNotEmpty) {
            await txn.update(
              AppConstants.tableCards,
              updates,
              where: 'id = ?',
              whereArgs: [existing.first['id']],
            );
          }
        }
      }
    });
    return (inserted: inserted, skipped: skipped);
  }

  /// 모든 카드 조회 (export용 — 페이지네이션)
  Future<List<CardModel>> getAllCards({int? limit, int? offset, String? sortBy}) async {
    final db = await database;
    String orderBy;
    switch (sortBy) {
      case 'newest':
        orderBy = 'id DESC';
      case 'oldest':
        orderBy = 'id ASC';
      case 'name_asc':
        orderBy = 'question ASC';
      case 'random':
        orderBy = 'RANDOM()';
      default:
        orderBy = 'folder_id, sequence';
    }
    final maps = await db.query(
      AppConstants.tableCards,
      limit: limit,
      offset: offset,
      orderBy: orderBy,
    );
    return maps.map((m) => CardModel.fromDb(m)).toList();
  }

  /// 모든 카드의 id만 정렬 옵션으로 조회. allCards 모드 알림용 indexOf 계산.
  Future<List<int>> getAllCardIds({String? sortBy}) async {
    final db = await database;
    String orderBy;
    switch (sortBy) {
      case 'newest':
        orderBy = 'id DESC';
      case 'oldest':
        orderBy = 'id ASC';
      case 'name_asc':
        orderBy = 'question ASC';
      case 'random':
        orderBy = 'RANDOM()';
      default:
        orderBy = 'folder_id, sequence';
    }
    final maps = await db.query(
      AppConstants.tableCards,
      columns: ['id'],
      orderBy: orderBy,
    );
    return maps.map((m) => m['id'] as int).toList();
  }

  /// 랜덤 카드 1개 조회 (알림용, 미완료 카드 우선)
  Future<CardModel?> getRandomCard({int? folderId}) async {
    final db = await database;
    // 미완료 카드 우선 선택, 없으면 전체에서 선택
    final folderClause = folderId != null ? 'folder_id = ? AND ' : '';
    final baseArgs = folderId != null ? [folderId] : <Object>[];
    var maps = await db.query(
      AppConstants.tableCards,
      where: '${folderClause}finished = 0',
      whereArgs: baseArgs,
      orderBy: 'RANDOM()',
      limit: 1,
    );
    if (maps.isEmpty) {
      // 미완료 카드 없으면 전체에서 선택
      maps = await db.query(
        AppConstants.tableCards,
        where: folderId != null ? 'folder_id = ?' : null,
        whereArgs: folderId != null ? [folderId] : null,
        orderBy: 'RANDOM()',
        limit: 1,
      );
    }
    if (maps.isEmpty) return null;
    return CardModel.fromDb(maps.first);
  }

  /// 전체 카드 수
  Future<int> getTotalCardCount() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM ${AppConstants.tableCards}',
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Settings 테이블: 전체 조회
  Future<Map<String, String>> getAllSettings() async {
    final db = await database;
    final maps = await db.query(AppConstants.tableSettings);
    final result = <String, String>{};
    for (final m in maps) {
      final key = m['key'];
      final value = m['value'];
      if (key is String && value is String) {
        result[key] = value;
      }
    }
    return result;
  }

  /// Settings 테이블: upsert
  Future<void> upsertSetting(String key, String value) async {
    final db = await database;
    await db.insert(
      AppConstants.tableSettings,
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ─── Card Search & Batch ───

  /// LIKE 메타문자 이스케이프
  String _escapeLike(String q) => q
      .replaceAll('\\', '\\\\')
      .replaceAll('%', '\\%')
      .replaceAll('_', '\\_');

  /// 검색 (Question 매치 우선, 단일 쿼리, 대소문자 무시)
  Future<List<CardModel>> searchCards(int folderId, String query) async {
    final db = await database;
    final escaped = _escapeLike(query);
    final pattern = '%$escaped%';
    final results = await db.rawQuery(
      "SELECT * FROM ${AppConstants.tableCards} "
      "WHERE folder_id = ? AND (question LIKE ? ESCAPE '\\' COLLATE NOCASE OR answer LIKE ? ESCAPE '\\' COLLATE NOCASE) "
      "ORDER BY CASE WHEN question LIKE ? ESCAPE '\\' COLLATE NOCASE THEN 0 ELSE 1 END, sequence ASC",
      [folderId, pattern, pattern, pattern],
    );
    return results.map((m) => CardModel.fromDb(m)).toList();
  }

  /// 전체 카드 검색 (allCards 모드, 단일 쿼리, 대소문자 무시)
  /// 결과를 1000개로 제한하여 대량 카드에서 OOM 방지
  Future<List<CardModel>> searchAllCards(String query) async {
    final db = await database;
    final escaped = _escapeLike(query);
    final pattern = '%$escaped%';
    final results = await db.rawQuery(
      "SELECT * FROM ${AppConstants.tableCards} "
      "WHERE question LIKE ? ESCAPE '\\' COLLATE NOCASE OR answer LIKE ? ESCAPE '\\' COLLATE NOCASE "
      "ORDER BY CASE WHEN question LIKE ? ESCAPE '\\' COLLATE NOCASE THEN 0 ELSE 1 END, folder_id, sequence ASC "
      "LIMIT 1000",
      [pattern, pattern, pattern],
    );
    return results.map((m) => CardModel.fromDb(m)).toList();
  }

  /// 배치 삭제 (영향받는 폴더 card_count 자동 갱신)
  Future<int> deleteCardsBatch(List<int> cardIds) async {
    if (cardIds.isEmpty) return 0;
    final db = await database;
    final placeholders = List.filled(cardIds.length, '?').join(',');
    int deleted = 0;
    await db.transaction((txn) async {
      // 삭제 전 영향받는 폴더 ID 수집
      final affected = await txn.rawQuery(
        'SELECT DISTINCT folder_id FROM ${AppConstants.tableCards} WHERE id IN ($placeholders)',
        cardIds,
      );
      final folderIds = affected.map((r) => r['folder_id'] as int).toSet();

      deleted = await txn.rawDelete(
        'DELETE FROM ${AppConstants.tableCards} WHERE id IN ($placeholders)',
        cardIds,
      );

      // 영향받는 폴더 card_count 갱신
      for (final fid in folderIds) {
        final count = Sqflite.firstIntValue(await txn.rawQuery(
          'SELECT COUNT(*) FROM ${AppConstants.tableCards} WHERE folder_id = ?',
          [fid],
        )) ?? 0;
        await txn.update(AppConstants.tableFolders, {'card_count': count},
            where: 'id = ?', whereArgs: [fid]);
      }
    });
    return deleted;
  }

  /// SQLite IN 절 placeholder 한도(기본 999) 우회용 청크 사이즈
  static const int _sqlInChunkSize = 800;

  /// 배치 이동 (원본/대상 폴더 card_count 자동 갱신).
  /// cardIds 개수에 제한 없음 — IN 절은 청크 단위로 분할 실행.
  Future<void> moveCardsBatch(List<int> cardIds, int newFolderId) async {
    if (cardIds.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final oldFolderIds = <int>{};

      for (var i = 0; i < cardIds.length; i += _sqlInChunkSize) {
        final chunk = cardIds.sublist(
            i,
            i + _sqlInChunkSize > cardIds.length
                ? cardIds.length
                : i + _sqlInChunkSize);
        final placeholders = List.filled(chunk.length, '?').join(',');

        // 이동 전 원본 폴더 ID 수집 (청크별)
        final affected = await txn.rawQuery(
          'SELECT DISTINCT folder_id FROM ${AppConstants.tableCards} WHERE id IN ($placeholders)',
          chunk,
        );
        oldFolderIds.addAll(affected.map((r) => r['folder_id'] as int));

        // 청크별 UPDATE
        await txn.rawUpdate(
          'UPDATE ${AppConstants.tableCards} SET folder_id = ? WHERE id IN ($placeholders)',
          [newFolderId, ...chunk],
        );
      }

      // 원본 + 대상 폴더 card_count 갱신
      final allFolderIds = {...oldFolderIds, newFolderId};
      for (final fid in allFolderIds) {
        final count = Sqflite.firstIntValue(await txn.rawQuery(
          'SELECT COUNT(*) FROM ${AppConstants.tableCards} WHERE folder_id = ?',
          [fid],
        )) ?? 0;
        await txn.update(AppConstants.tableFolders, {'card_count': count},
            where: 'id = ?', whereArgs: [fid]);
      }
    });
  }

  /// 대상 폴더에 question이 같은 카드가 이미 있는 cardId들 반환.
  /// 빈 question은 매칭 대상에서 제외 (false positive 방지).
  /// cardIds 개수에 제한 없음 — IN 절은 청크 단위로 분할 실행.
  Future<Set<int>> findDuplicateCardIdsInFolder(
      List<int> cardIds, int targetFolderId) async {
    if (cardIds.isEmpty) return {};
    final db = await database;

    // 대상 폴더의 기존 question은 folder_id 단일 조건이라 한 번에 조회
    final existingCards = await db.rawQuery(
      "SELECT question FROM ${AppConstants.tableCards} WHERE folder_id = ? AND question != ''",
      [targetFolderId],
    );
    final existingQuestions =
        existingCards.map((r) => r['question'] as String).toSet();

    final duplicateIds = <int>{};
    for (var i = 0; i < cardIds.length; i += _sqlInChunkSize) {
      final chunk = cardIds.sublist(
          i,
          i + _sqlInChunkSize > cardIds.length
              ? cardIds.length
              : i + _sqlInChunkSize);
      final placeholders = List.filled(chunk.length, '?').join(',');
      final movingCards = await db.rawQuery(
        'SELECT id, question FROM ${AppConstants.tableCards} WHERE id IN ($placeholders)',
        chunk,
      );
      for (final c in movingCards) {
        final q = (c['question'] as String?) ?? '';
        if (q.isEmpty) continue;
        if (existingQuestions.contains(q)) {
          duplicateIds.add(c['id'] as int);
        }
      }
    }
    return duplicateIds;
  }

  /// 카드 복제
  Future<int> duplicateCard(int cardId) async {
    final db = await database;
    final card = await getCardById(cardId);
    if (card == null) return -1;
    final maxSeq = await getMaxSequence(card.folderId);
    final newUuid =
        '${card.uuid}-copy-${DateTime.now().microsecondsSinceEpoch}';
    final newCard = card.copyWith(
      uuid: newUuid,
      sequence: maxSeq + 1,
    );
    final dbMap = newCard.toDb();
    dbMap.remove('id'); // id를 제거하여 autoincrement 사용

    // 이미지/음성 파일을 새 파일로 복사하여 참조 분리
    await _duplicateFiles(dbMap);

    final newId = await db.insert(AppConstants.tableCards, dbMap);
    await updateFolderCardCount(card.folderId);
    return newId;
  }

  /// DB 맵의 파일 경로 컬럼들을 새 파일로 복사
  /// 복사 실패 시 해당 경로를 null로 설정하여 원본과 파일 공유 방지
  Future<void> _duplicateFiles(Map<String, dynamic> dbMap) async {
    final pathKeys = dbMap.keys
        .where((k) => k.contains('_path') || k.contains('_record_path'))
        .toList();
    var counter = 0;
    for (final key in pathKeys) {
      final path = dbMap[key];
      if (path is! String || path.isEmpty) continue;
      try {
        final file = File(path);
        if (!await file.exists()) continue;
        final dir = file.parent.path;
        final ext = p.extension(path);
        final ts = DateTime.now().microsecondsSinceEpoch;
        final newPath = p.join(dir, 'copy_${ts}_${counter++}$ext');
        await file.copy(newPath);
        dbMap[key] = newPath;
      } catch (e) {
        // 복사 실패 시 null로 설정 — 원본과 파일 공유 시 삭제 연쇄 문제 방지
        debugPrint('[DB] _duplicateFiles copy failed for $key: $e');
        dbMap[key] = null;
      }
    }
  }

  /// 정렬 옵션으로 카드 조회
  Future<List<CardModel>> getCardsByFolderIdSorted(
    int folderId,
    String sortBy, {
    int? limit,
    int? offset,
  }) async {
    final db = await database;
    String orderBy;
    switch (sortBy) {
      case 'newest':
        orderBy = 'id DESC';
      case 'oldest':
        orderBy = 'id ASC';
      case 'name_asc':
        orderBy = 'question ASC';
      case 'random':
        orderBy = 'RANDOM()';
      default:
        orderBy = 'sequence ASC';
    }
    final maps = await db.query(
      AppConstants.tableCards,
      where: 'folder_id = ?',
      whereArgs: [folderId],
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );
    return maps.map((m) => CardModel.fromDb(m)).toList();
  }

  /// id만 정렬 옵션으로 조회. 알림 진입 시 정확한 indexOf 계산용.
  /// (large query에서 row corruption이 발생해도 id 컬럼만이라면 transaction
  /// 한계를 충분히 회피한다)
  Future<List<int>> getCardIdsByFolderIdSorted(
    int folderId,
    String sortBy,
  ) async {
    final db = await database;
    String orderBy;
    switch (sortBy) {
      case 'newest':
        orderBy = 'id DESC';
      case 'oldest':
        orderBy = 'id ASC';
      case 'name_asc':
        orderBy = 'question ASC';
      case 'random':
        orderBy = 'RANDOM()';
      default:
        orderBy = 'sequence ASC';
    }
    final maps = await db.query(
      AppConstants.tableCards,
      columns: ['id'],
      where: 'folder_id = ?',
      whereArgs: [folderId],
      orderBy: orderBy,
    );
    return maps.map((m) => m['id'] as int).toList();
  }

  /// id 리스트로 카드를 chunk 단위로 조회.
  /// CardModel은 100+ 컬럼이라 13988장을 한 번에 SELECT * 하면
  /// Android Binder transaction(1MB) 한계로 일부 row의 컬럼 데이터가
  /// silently corrupt된다. chunk 단위(500개)로 나누면 회피된다.
  Future<Map<int, CardModel>> getCardsByIdsBatch(List<int> ids) async {
    if (ids.isEmpty) return <int, CardModel>{};
    final db = await database;
    final result = <int, CardModel>{};
    const chunkSize = 500; // SQLite SQLITE_MAX_VARIABLE_NUMBER 기본 999 안전
    for (int i = 0; i < ids.length; i += chunkSize) {
      final end =
          (i + chunkSize < ids.length) ? i + chunkSize : ids.length;
      final chunk = ids.sublist(i, end);
      final placeholders = List.filled(chunk.length, '?').join(',');
      final maps = await db.rawQuery(
        'SELECT * FROM ${AppConstants.tableCards} WHERE id IN ($placeholders)',
        chunk,
      );
      for (final m in maps) {
        try {
          final card = CardModel.fromDb(m);
          if (card.id != null) result[card.id!] = card;
        } catch (e) {
          debugPrint('[DB] getCardsByIdsBatch fromDb fail: $e');
        }
      }
    }
    return result;
  }

  // ─── Counter CRUD ───

  Future<Map<String, dynamic>?> getCounter() async {
    final db = await database;
    final maps = await db.query(AppConstants.tableCounters, limit: 1);
    if (maps.isEmpty) {
      // 카운터 row가 없으면 자동 생성
      await db.insert(AppConstants.tableCounters, {
        'id': 1,
        'card_sequence': 0,
        'card_minus_sequence': 0,
        'folder_sequence': 0,
        'folder_minus_sequence': 0,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      final retry = await db.query(AppConstants.tableCounters, limit: 1);
      if (retry.isEmpty) return null;
      return retry.first;
    }
    return maps.first;
  }

  Future<void> updateCounter(Map<String, dynamic> counter) async {
    final db = await database;
    await db.update(
      AppConstants.tableCounters,
      counter,
      where: 'id = 1',
    );
  }

  // ─── Exported Files CRUD ───

  Future<int> insertExportedFile({
    required String fileName,
    required String filePath,
    int? fileSize,
    String? fileType,
  }) async {
    final db = await database;
    return await db.insert(AppConstants.tableExportedFiles, {
      'file_name': fileName,
      'file_path': filePath,
      'file_size': fileSize,
      'file_type': fileType,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<List<Map<String, dynamic>>> getAllExportedFiles() async {
    final db = await database;
    return await db.query(
      AppConstants.tableExportedFiles,
      orderBy: 'created_at DESC',
    );
  }

  Future<void> renameExportedFile(int id, String newFileName, String newFilePath) async {
    final db = await database;
    await db.update(
      AppConstants.tableExportedFiles,
      {'file_name': newFileName, 'file_path': newFilePath},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> deleteExportedFile(int id) async {
    final db = await database;
    return await db.delete(
      AppConstants.tableExportedFiles,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> deleteExportedFileByPath(String filePath) async {
    final db = await database;
    return await db.delete(
      AppConstants.tableExportedFiles,
      where: 'file_path = ?',
      whereArgs: [filePath],
    );
  }

  Future<Map<String, dynamic>?> getExportedFileByPath(String filePath) async {
    final db = await database;
    final maps = await db.query(
      AppConstants.tableExportedFiles,
      where: 'file_path = ?',
      whereArgs: [filePath],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return maps.first;
  }

  // ─── Push Alarms CRUD ───

  Future<int> insertPushAlarm({
    required String time,
    int enabled = 1,
    int? folderId,
    String? days,
    int soundEnabled = 1,
    String mode = 'fixed',
    String? startTime,
    String? endTime,
    int? intervalMin,
  }) async {
    final db = await database;
    return await db.insert(AppConstants.tablePushAlarms, {
      'time': time,
      'enabled': enabled,
      'folder_id': folderId,
      'days': days,
      'sound_enabled': soundEnabled,
      'mode': mode,
      'start_time': startTime,
      'end_time': endTime,
      'interval_min': intervalMin,
    });
  }

  Future<List<Map<String, dynamic>>> getAllPushAlarms() async {
    final db = await database;
    return await db.query(AppConstants.tablePushAlarms);
  }

  Future<int> updatePushAlarm(int id, Map<String, dynamic> values) async {
    final db = await database;
    return await db.update(
      AppConstants.tablePushAlarms,
      values,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> deletePushAlarm(int id) async {
    final db = await database;
    return await db.delete(
      AppConstants.tablePushAlarms,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 존재하지 않는 이미지/음성 파일 경로를 DB에서 일괄 제거
  /// 앱 시작 시 1회 실행하여 깨진 이미지 참조를 정리
  /// 배치 처리로 OOM 방지 (대량 카드 대응)
  Future<int> cleanupBrokenImagePaths() async {
    final db = await database;

    // 이미지/음성 경로를 포함하는 모든 컬럼
    const pathColumns = [
      'question_image_path', 'question_image_path_2', 'question_image_path_3',
      'question_image_path_4', 'question_image_path_5',
      'answer_image_path', 'answer_image_path_2', 'answer_image_path_3',
      'answer_image_path_4', 'answer_image_path_5',
      'question_hand_image_path', 'question_hand_image_path_2',
      'question_hand_image_path_3', 'question_hand_image_path_4',
      'question_hand_image_path_5',
      'answer_hand_image_path', 'answer_hand_image_path_2',
      'answer_hand_image_path_3', 'answer_hand_image_path_4',
      'answer_hand_image_path_5',
      'question_voice_record_path', 'question_voice_record_path_2',
      'question_voice_record_path_3', 'question_voice_record_path_4',
      'question_voice_record_path_5', 'question_voice_record_path_6',
      'question_voice_record_path_7', 'question_voice_record_path_8',
      'question_voice_record_path_9', 'question_voice_record_path_10',
      'answer_voice_record_path', 'answer_voice_record_path_2',
      'answer_voice_record_path_3', 'answer_voice_record_path_4',
      'answer_voice_record_path_5', 'answer_voice_record_path_6',
      'answer_voice_record_path_7', 'answer_voice_record_path_8',
      'answer_voice_record_path_9', 'answer_voice_record_path_10',
    ];

    final whereClauses =
        pathColumns.map((c) => "($c IS NOT NULL AND $c != '')").join(' OR ');

    int cleaned = 0;
    const batchSize = 500;

    // ID 기반 페이지네이션: offset 드리프트 방지
    // 처리된 ID를 추적하여 무한 루프 방지
    int lastMaxId = 0;

    while (true) {
      // ID 기반 페이지네이션으로 offset 드리프트 문제 해결
      final rows = await db.query(
        AppConstants.tableCards,
        columns: ['id', ...pathColumns],
        where: 'id > ? AND ($whereClauses)',
        whereArgs: [lastMaxId],
        orderBy: 'id ASC',
        limit: batchSize,
      );
      if (rows.isEmpty) break;

      // 이 배치의 최대 ID 기록 (다음 배치의 시작점)
      lastMaxId = rows.last['id'] as int;

      // 파일 존재 확인은 비동기로 (UI 스레드 블로킹 방지)
      final batchUpdates = <int, Map<String, dynamic>>{};
      for (final row in rows) {
        final updates = <String, dynamic>{};
        for (final col in pathColumns) {
          final path = row[col] as String?;
          if (path == null || path.isEmpty) continue;
          if (!await File(path).exists()) {
            updates[col] = '';
            cleaned++;
          }
        }
        if (updates.isNotEmpty) {
          batchUpdates[row['id'] as int] = updates;
        }
      }
      // 트랜잭션으로 배치 업데이트 (성능 + 원자성)
      if (batchUpdates.isNotEmpty) {
        await db.transaction((txn) async {
          for (final entry in batchUpdates.entries) {
            await txn.update(
              AppConstants.tableCards,
              entry.value,
              where: 'id = ?',
              whereArgs: [entry.key],
            );
          }
        });
      }

      if (rows.length < batchSize) break;
    }
    return cleaned;
  }
}
