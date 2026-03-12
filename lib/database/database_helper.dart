import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../models/card.dart';
import '../models/folder.dart';
import '../utils/constants.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    _database ??= await _initDB();
    return _database!;
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
    return await db.update(
      AppConstants.tableFolders,
      folder.toDb(),
      where: 'id = ?',
      whereArgs: [folder.id],
    );
  }

  Future<int> deleteFolder(int id) async {
    final db = await database;
    return await db.delete(
      AppConstants.tableFolders,
      where: 'id = ?',
      whereArgs: [id],
    );
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
    return await db.update(
      AppConstants.tableCards,
      card.toDb(),
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

  Future<int> moveCard(int cardId, int newFolderId) async {
    final db = await database;
    return await db.update(
      AppConstants.tableCards,
      {'folder_id': newFolderId},
      where: 'id = ?',
      whereArgs: [cardId],
    );
  }

  Future<int> getMaxSequence(int folderId) async {
    final db = await database;
    return Sqflite.firstIntValue(await db.rawQuery(
      'SELECT MAX(sequence) FROM ${AppConstants.tableCards} WHERE folder_id = ?',
      [folderId],
    )) ?? 0;
  }

  /// 카드 배치 insert (transaction) — Import 시 사용
  Future<int> insertCardsBatch(List<CardModel> cards,
      {ConflictAlgorithm conflictAlgorithm = ConflictAlgorithm.abort}) async {
    final db = await database;
    int count = 0;
    await db.transaction((txn) async {
      for (final card in cards) {
        await txn.insert(AppConstants.tableCards, card.toDb(),
            conflictAlgorithm: conflictAlgorithm);
        count++;
      }
    });
    return count;
  }

  /// 모든 카드 조회 (export용 — 페이지네이션)
  Future<List<CardModel>> getAllCards({int? limit, int? offset}) async {
    final db = await database;
    final maps = await db.query(
      AppConstants.tableCards,
      limit: limit,
      offset: offset,
      orderBy: 'folder_id, sequence',
    );
    return maps.map((m) => CardModel.fromDb(m)).toList();
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
    return {
      for (var m in maps) m['key'] as String: m['value'] as String,
    };
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

  /// 검색 (Question 우선순위)
  Future<List<CardModel>> searchCards(int folderId, String query) async {
    final db = await database;
    final questionMatches = await db.query(
      AppConstants.tableCards,
      where: 'folder_id = ? AND question LIKE ?',
      whereArgs: [folderId, '%$query%'],
      orderBy: 'sequence ASC',
    );
    final answerMatches = await db.query(
      AppConstants.tableCards,
      where: 'folder_id = ? AND answer LIKE ? AND question NOT LIKE ?',
      whereArgs: [folderId, '%$query%', '%$query%'],
      orderBy: 'sequence ASC',
    );
    return [
      ...questionMatches.map((m) => CardModel.fromDb(m)),
      ...answerMatches.map((m) => CardModel.fromDb(m)),
    ];
  }

  /// 전체 카드 검색 (allCards 모드)
  Future<List<CardModel>> searchAllCards(String query) async {
    final db = await database;
    final questionMatches = await db.query(
      AppConstants.tableCards,
      where: 'question LIKE ?',
      whereArgs: ['%$query%'],
      orderBy: 'folder_id, sequence ASC',
    );
    final answerMatches = await db.query(
      AppConstants.tableCards,
      where: 'answer LIKE ? AND question NOT LIKE ?',
      whereArgs: ['%$query%', '%$query%'],
      orderBy: 'folder_id, sequence ASC',
    );
    return [
      ...questionMatches.map((m) => CardModel.fromDb(m)),
      ...answerMatches.map((m) => CardModel.fromDb(m)),
    ];
  }

  /// 배치 삭제
  Future<int> deleteCardsBatch(List<int> cardIds) async {
    if (cardIds.isEmpty) return 0;
    final db = await database;
    final placeholders = List.filled(cardIds.length, '?').join(',');
    return await db.rawDelete(
      'DELETE FROM ${AppConstants.tableCards} WHERE id IN ($placeholders)',
      cardIds,
    );
  }

  /// 배치 이동
  Future<void> moveCardsBatch(List<int> cardIds, int newFolderId) async {
    if (cardIds.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(cardIds.length, '?').join(',');
    await db.rawUpdate(
      'UPDATE ${AppConstants.tableCards} SET folder_id = ? WHERE id IN ($placeholders)',
      [newFolderId, ...cardIds],
    );
  }

  /// 카드 복제
  Future<int> duplicateCard(int cardId) async {
    final db = await database;
    final card = await getCardById(cardId);
    if (card == null) return -1;
    final maxSeq = await getMaxSequence(card.folderId);
    final newUuid =
        '${card.uuid}-copy-${DateTime.now().millisecondsSinceEpoch}';
    final newCard = card.copyWith(
      id: null,
      uuid: newUuid,
      sequence: maxSeq + 1,
    );
    final newId = await db.insert(AppConstants.tableCards, newCard.toDb());
    await updateFolderCardCount(card.folderId);
    return newId;
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

  // ─── Counter CRUD ───

  Future<Map<String, dynamic>?> getCounter() async {
    final db = await database;
    final maps = await db.query(AppConstants.tableCounters, limit: 1);
    if (maps.isEmpty) return null;
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

  Future<int> deleteExportedFile(int id) async {
    final db = await database;
    return await db.delete(
      AppConstants.tableExportedFiles,
      where: 'id = ?',
      whereArgs: [id],
    );
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
}
