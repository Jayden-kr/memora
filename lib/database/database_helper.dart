import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../models/card.dart';
import '../models/folder.dart';
import '../utils/constants.dart';
import '../services/audio_playback_controller.dart';

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

  /// 테스트 전용. 열려 있는 DB 핸들을 닫고 다음 [database] 접근이 새로 열게 한다.
  /// 프로덕션 코드에서 부르는 곳은 없다 — 런타임 경로는 그대로다.
  @visibleForTesting
  static Future<void> resetForTesting() async {
    final c = _dbCompleter;
    _dbCompleter = null;
    if (c == null) return;
    try {
      await (await c.future).close();
    } catch (_) {}
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
    // 병합 가져오기가 배치마다 `MAX(sequence) WHERE folder_id = ?`를 돈다. folder_id
    // 단독 인덱스로는 해당 폴더의 행을 전부 훑어야 해서, 큰 폴더에 4만 장을 병합하면
    // 전수 스캔이 수백 번 반복된다. (folder_id, sequence) 복합 인덱스면 그 집계가
    // 인덱스 끝 한 번 읽기로 끝난다(리뷰 R-03).
    await db.execute('''
      CREATE INDEX idx_cards_folder_seq ON ${AppConstants.tableCards}(folder_id, sequence)
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
    if (oldVersion < 4) {
      // 인덱스 추가는 데이터를 건드리지 않는다 — 실패해도 기능은 그대로 돌아가므로
      // (느려질 뿐) 업그레이드 전체를 실패시키지 않는다.
      try {
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_cards_folder_seq ON ${AppConstants.tableCards}(folder_id, sequence)');
      } catch (e) {
        debugPrint('[DB] idx_cards_folder_seq 생성 실패(무시): $e');
      }
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

  /// 폴더 목록을 읽을 때 소속 묶음 이름을 함께 채우기 위한 컬럼 목록.
  /// `parent_folder_name` 컬럼 자체는 신뢰할 수 없다 — 묶음 편집은 `parent_folder_id`만
  /// UPDATE하므로 이름 컬럼은 묶음 이름이 바뀌어도 낡은 채로 남는다. 그래서 f.*를 쓰지
  /// 않고 컬럼을 하나하나 적은 뒤 묶음 행에서 이름을 다시 읽어 덮어쓴다.
  static const _folderSelectWithBundleName = '''
    SELECT f.id, f.name, f.card_count, f.folder_count, f.sequence,
           f.original_sequence, f.modified, f.parent, f.parent_folder_id,
           f.is_special_folder, f.is_bundle, p.name AS parent_folder_name
    FROM %t f
    LEFT JOIN %t p ON p.id = f.parent_folder_id AND p.is_bundle = 1
  ''';

  /// 정렬 규칙: 먼저 "홈에서 보이는 것"의 순서로 묶고, 그 안에서 자식 순서를 쓴다.
  ///
  /// sequence는 하나의 컬럼인데 이제 두 화면이 각자 0..n-1로 다시 매긴다(홈은 최상위
  /// 항목만, 묶음 화면은 그 묶음의 자식만). 그래서 `ORDER BY f.sequence` 하나로는
  /// 최상위 폴더와 남의 묶음 자식이 같은 번호로 뒤엉킨다 — 폴더 선택 목록의 순서가
  /// 사용자가 정한 어떤 순서와도 무관해진다(리뷰 B-02).
  ///
  /// 자식은 자기 묶음의 sequence를 1차 키로 써서 그 묶음이 홈에서 있던 자리에 붙고,
  /// 그 안에서만 자기 sequence로 줄을 선다. 마지막 id는 동률을 없애는 못이다.
  static String _folderSelect(String where) =>
      '${_folderSelectWithBundleName.replaceAll('%t', AppConstants.tableFolders)}'
      ' WHERE $where'
      ' ORDER BY COALESCE(p.sequence, f.sequence) ASC,'
      ' CASE WHEN f.parent_folder_id IS NULL THEN 0 ELSE 1 END ASC,'
      ' f.sequence ASC, f.id ASC';

  /// 묶음이 아닌 폴더 전부. 묶음에 속한 폴더는 [Folder.parentFolderName]에 그 묶음
  /// 이름이 채워져 온다(폴더 선택 화면들이 `묶음 > 폴더`로 표시하는 데 쓴다).
  Future<List<Folder>> getNonBundleFolders() async {
    final db = await database;
    final maps = await db.rawQuery(_folderSelect('f.is_bundle = 0'));
    return maps.map((m) => Folder.fromDb(m)).toList();
  }

  Future<List<Folder>> getChildFolders(int parentId) async {
    final db = await database;
    final maps =
        await db.rawQuery(_folderSelect('f.parent_folder_id = ?'), [parentId]);
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

  /// [getFolderByName]의 비번들 변형 — import 병합 대상은 카드를 직접 갖는 일반 폴더만.
  /// 이름이 같은 '묶음(bundle)'은 병합 대상이 아니다(묶음에 들어간 카드는 홈에 안 보이고,
  /// 묶음 화면에서 도달 불가, export 불가, 묶음 삭제 시 CASCADE로 경고 없이 전멸).
  Future<Folder?> getNonBundleFolderByName(String name) async {
    final db = await database;
    final maps = await db.query(
      AppConstants.tableFolders,
      where: 'name = ? AND is_bundle = 0',
      whereArgs: [name],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return Folder.fromDb(maps.first);
  }

  /// 이름만 바꾼다. 폴더 스냅샷 전체를 되쓰는 방식(예전의 updateFolder, 부르는 곳이
  /// 없어 삭제)은 화면이 들고 있던 옛 card_count/parent_folder_id를 DB에 덮어써
  /// 카드 수가 옛 값으로 굳고 묶음 소속이 풀렸다(D1-03/D8-09). 되살리지 말 것.
  Future<int> renameFolder(int id, String newName) async {
    final db = await database;
    return await db.update(
      AppConstants.tableFolders,
      {'name': newName},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 묶음에서 빠져나오는 폴더들의 parent를 풀고, **최상위 순번을 새로 준다.**
  ///
  /// 묶음 화면과 홈 화면은 같은 `sequence` 컬럼을 각자 0..n-1로 다시 매긴다. 그래서
  /// 묶음 안에서 순서를 바꾼 폴더는 0,1,2… 같은 작은 값을 들고 있는데, 그대로 최상위로
  /// 올라오면 기존 최상위 폴더의 번호와 정면으로 부딪힌다(스윕 D-02). 조회 쪽 정렬은
  /// 부모가 있을 때만 묶음 자리로 보정해 주므로, 부모가 사라지는 이 순간에 번호를
  /// 바로잡아야 한다. 목록 맨 뒤로 보낸다 — 사용자가 정한 최상위 순서를 흔들지 않는다.
  static Future<void> _unlinkFromBundle(
      DatabaseExecutor txn, List<int> folderIds) async {
    if (folderIds.isEmpty) return;
    var nextSeq = Sqflite.firstIntValue(await txn.rawQuery(
            'SELECT MAX(sequence) FROM ${AppConstants.tableFolders} WHERE parent_folder_id IS NULL')) ??
        0;
    // 호출부(삭제 시의 SELECT, 편집 시의 Set.difference)가 묶음 안 순서를 보장 안
    // 하므로, 여기서 현재 sequence로 다시 정렬해 승격 순서를 고정한다 — 안 그러면
    // 최상위로 올라온 폴더들이 사용자가 묶음 안에서 정해둔 순서와 무관하게 임의
    // 순서로 뒤에 붙는다(리뷰 발견, 데이터 유실은 아니고 순서만 흐트러짐).
    //
    // ⚠️ 이 파일의 다른 배치 쿼리들과 똑같이 _sqlInChunkSize로 나눠서 부른다 —
    // 안 나누면 큰 묶음(자식이 수백~수천) 하나를 지우거나 편집할 때 IN 절
    // 플레이스홀더가 안드로이드 SQLite 기본 한도(999)를 넘겨 트랜잭션 전체가
    // 예외로 죽는다(2차 리뷰 발견, R6-E).
    final rows = <Map<String, Object?>>[];
    for (var i = 0; i < folderIds.length; i += _sqlInChunkSize) {
      final chunk = folderIds.sublist(
          i,
          i + _sqlInChunkSize > folderIds.length
              ? folderIds.length
              : i + _sqlInChunkSize);
      final ph = List.filled(chunk.length, '?').join(',');
      rows.addAll(await txn.rawQuery(
        'SELECT id, sequence FROM ${AppConstants.tableFolders} WHERE id IN ($ph)',
        chunk,
      ));
    }
    final orderedIds = rows.toList()
      ..sort((a, b) =>
          (a['sequence'] as int? ?? 0).compareTo(b['sequence'] as int? ?? 0));
    for (final row in orderedIds) {
      nextSeq++;
      await txn.update(
        AppConstants.tableFolders,
        {'parent_folder_id': null, 'sequence': nextSeq},
        where: 'id = ?',
        whereArgs: [row['id'] as int],
      );
    }
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

  /// 여러 폴더를 한 트랜잭션으로 원자적 삭제. IN 절은 청크 단위로 분할 실행.
  /// 5 폴더 + 수만 카드라도 보통 수백 ms 안에 commit 완료 → 사용자가 swipe할 틈 없음.
  /// 삭제되는 카드들의 이미지/음성 파일 경로를 삭제 전에 수집해 반환 — 실제 파일
  /// 삭제(디스크 I/O)와 잠금화면 prefs 정리는 호출자가 transaction 밖에서 처리.
  /// pushReschedNeeded: push_alarms.folder_id를 NULL로 바꾼 행이 있는지(=재스케줄 필요 여부).
  /// filePaths: 삭제된 카드들의 non-empty 이미지/음성 경로 전체 (orphan 파일 방지용).
  Future<({bool pushReschedNeeded, List<String> filePaths})> deleteFoldersBatch({
    required List<int> regularFolderIds,
    required List<int> bundleFolderIds,
  }) async {
    if (regularFolderIds.isEmpty && bundleFolderIds.isEmpty) {
      return (pushReschedNeeded: false, filePaths: <String>[]);
    }
    final db = await database;
    bool pushReschedNeeded = false;
    final filePaths = <String>[];
    await db.transaction((txn) async {
      // Bundle 폴더: 자식 unset + bundle 삭제 (청크별)
      if (bundleFolderIds.isNotEmpty) {
        for (var i = 0; i < bundleFolderIds.length; i += _sqlInChunkSize) {
          final chunk = bundleFolderIds.sublist(
              i,
              i + _sqlInChunkSize > bundleFolderIds.length
                  ? bundleFolderIds.length
                  : i + _sqlInChunkSize);
          final ph = List.filled(chunk.length, '?').join(',');
          final children = await txn.rawQuery(
            'SELECT id FROM ${AppConstants.tableFolders} WHERE parent_folder_id IN ($ph)',
            chunk,
          );
          await _unlinkFromBundle(
              txn, children.map((r) => r['id'] as int).toList());
          await txn.rawDelete(
            'DELETE FROM ${AppConstants.tableFolders} WHERE id IN ($ph)',
            chunk,
          );
        }
      }
      // 일반 폴더: cards / folders / push_alarms 단일 statement씩 (청크별)
      if (regularFolderIds.isNotEmpty) {
        for (var i = 0; i < regularFolderIds.length; i += _sqlInChunkSize) {
          final chunk = regularFolderIds.sublist(
              i,
              i + _sqlInChunkSize > regularFolderIds.length
                  ? regularFolderIds.length
                  : i + _sqlInChunkSize);
          final ph = List.filled(chunk.length, '?').join(',');
          // 삭제 전 미디어 경로 수집. 대형 폴더를 한 번에 SELECT하면 getCardsByIdsBatch와
          // 같은 Android Binder transaction(1MB) 한계에 걸릴 수 있어 500행씩 페이징한다.
          // transaction 내부라 동시 쓰기가 없어 LIMIT/OFFSET 페이징이 안전하다.
          var offset = 0;
          while (true) {
            final rows = await txn.rawQuery(
              'SELECT ${_pathColumns.join(', ')} FROM ${AppConstants.tableCards} '
              'WHERE folder_id IN ($ph) LIMIT ? OFFSET ?',
              [...chunk, 500, offset],
            );
            for (final row in rows) {
              for (final col in _pathColumns) {
                final path = row[col] as String?;
                if (path != null && path.isNotEmpty) filePaths.add(path);
              }
            }
            if (rows.length < 500) break;
            offset += 500;
          }
          await txn.rawDelete(
            'DELETE FROM ${AppConstants.tableCards} WHERE folder_id IN ($ph)',
            chunk,
          );
          await txn.rawDelete(
            'DELETE FROM ${AppConstants.tableFolders} WHERE id IN ($ph)',
            chunk,
          );
          final cleared = await txn.rawUpdate(
            'UPDATE ${AppConstants.tablePushAlarms} SET folder_id = NULL WHERE folder_id IN ($ph)',
            chunk,
          );
          if (cleared > 0) pushReschedNeeded = true;
        }
        // 삭제된 일반 폴더가 어느 묶음의 자식이었을 수 있음. parent_folder_id는 FK/trigger가
        // 없어 saveBundleFolder 밖에서 폴더가 사라지면 folder_count가 자동 갱신되지 않는다 →
        // 모든 묶음의 folder_count를 실제 자식 수 기준으로 재계산해 stale 값을 방지한다.
        await txn.rawUpdate(
          'UPDATE ${AppConstants.tableFolders} SET folder_count = '
          '(SELECT COUNT(*) FROM ${AppConstants.tableFolders} c WHERE c.parent_folder_id = ${AppConstants.tableFolders}.id) '
          'WHERE is_bundle = 1',
        );
      }
    });
    return (pushReschedNeeded: pushReschedNeeded, filePaths: filePaths);
  }

  /// 묶음 폴더 생성/편집을 단일 transaction으로 처리. swipe 도중에도 atomic.
  /// - [bundleId]: null이면 생성 모드, non-null이면 편집 모드
  /// - [selectedChildIds]: 묶음에 속하게 할 child folder id 집합
  /// - [oldChildIds]: 편집 모드일 때 이전 child id 집합 (deselected → parent unset)
  /// 리턴: bundle folder id
  Future<int> saveBundleFolder({
    required int? bundleId,
    required String bundleName,
    required Set<int> selectedChildIds,
    Set<int>? oldChildIds,
  }) async {
    final db = await database;
    late int resultId;
    await db.transaction((txn) async {
      // 1. bundle row 생성 또는 name update
      if (bundleId == null) {
        final maxSeqRow = await txn.rawQuery(
          'SELECT MAX(sequence) FROM ${AppConstants.tableFolders}');
        final maxSeq = Sqflite.firstIntValue(maxSeqRow) ?? 0;
        resultId = await txn.insert(
          AppConstants.tableFolders,
          Folder(
            name: bundleName,
            isBundle: true,
            folderCount: 0, // 아래에서 actualLinked로 보정
            sequence: maxSeq + 1,
          ).toDb(),
        );
      } else {
        resultId = bundleId;
        await txn.update(
          AppConstants.tableFolders,
          {'name': bundleName},
          where: 'id = ?',
          whereArgs: [bundleId],
        );
        // 편집 모드: 이전 child 중 deselected 된 것들 parent unset
        if (oldChildIds != null) {
          final toUnset = oldChildIds.difference(selectedChildIds).toList();
          if (toUnset.isNotEmpty) {
            await _unlinkFromBundle(txn, toUnset);
          }
        }
      }

      // 2. selectedChildIds 중 실제 존재하는 non-bundle 폴더만 parent set
      int actualLinked = 0;
      if (selectedChildIds.isNotEmpty) {
        final ids = selectedChildIds.toList();
        final ph = List.filled(ids.length, '?').join(',');
        final existing = await txn.rawQuery(
          'SELECT id FROM ${AppConstants.tableFolders} WHERE id IN ($ph) AND is_bundle = 0',
          ids,
        );
        actualLinked = existing.length;
        if (existing.isNotEmpty) {
          final existingIds = existing.map((r) => r['id'] as int).toList();
          final eph = List.filled(existingIds.length, '?').join(',');
          await txn.rawUpdate(
            'UPDATE ${AppConstants.tableFolders} SET parent_folder_id = ? WHERE id IN ($eph)',
            [resultId, ...existingIds],
          );
        }
      }

      // 3. bundle의 folder_count 최종 보정
      await txn.update(
        AppConstants.tableFolders,
        {'folder_count': actualLinked},
        where: 'id = ?',
        whereArgs: [resultId],
      );
    });
    return resultId;
  }

  /// 일반 폴더의 card_count 캐시를 실제 COUNT(*)로 맞춘다 — 앱 시작 시 1회. 홈 타일은
  /// 캐시, 카드 목록 앱바는 실시간 COUNT라 캐시가 어긋나면 두 화면의 숫자가 달랐고 잠금화면/
  /// 푸시 설정이 멀쩡한 폴더를 "카드 없음"으로 표시했다(X3-06). 어긋난 행만 UPDATE한다.
  Future<int> resyncFolderCardCounts() async {
    final db = await database;
    const actual =
        '(SELECT COUNT(*) FROM ${AppConstants.tableCards} c '
        'WHERE c.folder_id = ${AppConstants.tableFolders}.id)';
    return await db.rawUpdate(
      'UPDATE ${AppConstants.tableFolders} SET card_count = $actual '
      'WHERE is_bundle = 0 AND card_count != $actual',
    );
  }

  Future<void> updateFolderCardCount(int folderId) async {
    final db = await database;
    // COUNT와 UPDATE를 한 문장으로 — 두 문장 사이에 다른 쓰기(import 마무리 vs 카드 추가/삭제)가
    // 끼면 틀린 값이 굳었다(X2-06). 다른 카운트 갱신 경로는 전부 트랜잭션 안이었다.
    await db.rawUpdate(
      'UPDATE ${AppConstants.tableFolders} SET card_count = '
      '(SELECT COUNT(*) FROM ${AppConstants.tableCards} WHERE folder_id = ?) '
      'WHERE id = ?',
      [folderId, folderId],
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

  /// 지정한 컬럼만 UPDATE. 편집 저장이 쓴다 — 전체 컬럼 되쓰기는 동시에 도는 import의
  /// 복구 결과를 덮었다(X3-02). 바꿀 게 없으면 0.
  Future<int> updateCardFields(int id, Map<String, Object?> fields) async {
    final map = Map<String, Object?>.from(fields)..remove('id');
    if (map.isEmpty) return 0;
    final db = await database;
    return await db.update(
      AppConstants.tableCards,
      map,
      where: 'id = ?',
      whereArgs: [id],
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
    // 다른 배치 헬퍼와 같이 IN 절을 청크로 나눈다 — 폴더가 극단적으로 많으면 SQLite 변수
    // 한도에 걸려 전체 export가 예외로 죽었다(D8-07).
    var total = 0;
    for (var i = 0; i < folderIds.length; i += _sqlInChunkSize) {
      final end = (i + _sqlInChunkSize < folderIds.length)
          ? i + _sqlInChunkSize
          : folderIds.length;
      final chunk = folderIds.sublist(i, end);
      final placeholders = List.filled(chunk.length, '?').join(',');
      total += Sqflite.firstIntValue(await db.rawQuery(
        'SELECT COUNT(*) FROM ${AppConstants.tableCards} WHERE folder_id IN ($placeholders)',
        chunk,
      )) ?? 0;
    }
    return total;
  }

  /// [fields]가 있으면 같은 트랜잭션에서 그 컬럼도 함께 UPDATE한다 — 편집 저장이 폴더 이동과
  /// 내용 저장을 따로 하면 이동만 커밋된 채 '저장 실패'가 떠 카드가 옛 내용으로 딴 폴더에
  /// 가 있었다(D3-11).
  Future<int> moveCard(int cardId, int newFolderId,
      {Map<String, Object?>? fields}) async {
    final db = await database;
    int result = 0;
    final extra = fields == null ? null : (Map<String, Object?>.from(fields)
      ..remove('id')
      ..remove('folder_id'));
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

      // 배치 이동과 같은 규칙: 대상 폴더 맨 뒤로 새 번호를 준다(감사 D3-03).
      // 호출자가 sequence를 명시했으면 그 값을 존중한다.
      //
      // 같은 폴더로의 "이동"은 번호를 건드리지 않는다: MAX(sequence)가 아직 옮기지 않은
      // 자기 자신을 포함하므로, 그대로 두면 아무것도 안 바뀌어야 할 호출이 카드를 맨 뒤로
      // 밀어버린다. 지금은 두 호출부 모두 현재 폴더를 대상에서 빼지만, 그 가드가 빠지면
      // 바로 새는 자리다(리뷰 B-02).
      final skipRenumber = (extra != null && extra.containsKey('sequence')) ||
          oldFolderId == newFolderId;
      final nextSeq = skipRenumber
          ? null
          : (Sqflite.firstIntValue(await txn.rawQuery(
                    'SELECT MAX(sequence) FROM ${AppConstants.tableCards} WHERE folder_id = ?',
                    [newFolderId],
                  )) ??
                  0) +
              1;
      final values = <String, Object?>{'folder_id': newFolderId};
      if (nextSeq != null) values['sequence'] = nextSeq;
      if (extra != null) values.addAll(extra);
      result = await txn.update(
        AppConstants.tableCards,
        values,
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

  /// referencedMediaPaths의 컬럼-동시조회 청크 크기(카드 행 수). 40개 컬럼과 곱해
  /// 바인딩 변수 수가 되므로 Android SQLite 변수 한도(999) 안에 있어야 한다
  /// (40 × 20 = 800 < 999).
  static const int _mediaPathChunkRows = 20;

  /// 테스트 전용 — [_mediaPathChunkRows] 노출.
  @visibleForTesting
  static int get mediaPathChunkRows => _mediaPathChunkRows;

  /// [paths] 중 아직 어떤 카드가 참조하는 경로. 카드/이미지 삭제 뒤 파일을 지우기 전에 불러,
  /// 여러 카드가 공유하는 파일(레거시 .memk가 같은 파일을 여러 카드에 심는다)을 남의 카드에서
  /// 뺏지 않게 한다(D8-04/Y4-01). 호출 시점엔 삭제/수정이 이미 커밋돼 있어야 한다.
  Future<Set<String>> referencedMediaPaths(Iterable<String> paths) async {
    final unique = paths.where((p) => p.isNotEmpty).toSet().toList();
    if (unique.isEmpty) return {};
    final db = await database;
    final found = <String>{};
    final uniqueSet = unique.toSet();
    // 경로가 많으면(카드 수백 장 일괄 삭제) 청크마다 스캔하는 것보다 테이블을 한 번만 훑는 게
    // 싸다 — 청크 방식은 스캔 횟수가 경로 수에 비례한다. 한 번에 다 읽으면 Binder 1MB 한계에
    // 걸리므로 id 기준 keyset 페이징으로 500행씩 읽는다(LIMIT/OFFSET은 동시 삽입에 밀린다).
    if (uniqueSet.length > 100) {
      var lastId = 0;
      while (true) {
        final rows = await db.rawQuery(
          'SELECT id, ${_pathColumns.join(', ')} FROM ${AppConstants.tableCards} '
          'WHERE id > ? ORDER BY id LIMIT 500',
          [lastId],
        );
        if (rows.isEmpty) break;
        for (final r in rows) {
          for (final col in _pathColumns) {
            final p = r[col] as String?;
            if (p != null && uniqueSet.contains(p)) found.add(p);
          }
        }
        lastId = rows.last['id'] as int;
        if (rows.length < 500) break;
      }
      return found;
    }
    // 40개 컬럼을 컬럼마다 따로 조회하면(인덱스가 없어 전부 풀스캔) 카드 한 장 지울 때마다
    // 스캔이 40번 돈다 — 1만 장대 라이브러리에서 눈에 띄게 느리고 쓰기 락도 오래 문다
    // (리뷰 P-01). 한 번의 스캔으로 40컬럼을 동시에 본다. 대신 바인딩 변수가
    // 40 × _mediaPathChunkRows개라 SQLite 변수 상한에 걸리지 않게 작게 잡는다.
    final where = _pathColumns
        .map((c) => '$c IN (${List.filled(_mediaPathChunkRows, '?').join(',')})')
        .join(' OR ');
    for (var i = 0; i < unique.length; i += _mediaPathChunkRows) {
      final end = (i + _mediaPathChunkRows < unique.length)
          ? i + _mediaPathChunkRows
          : unique.length;
      final chunk = unique.sublist(i, end);
      // 마지막 청크가 짧으면 자리표시자 수가 안 맞는다 — 중복 값으로 채워 길이를 맞춘다
      // (IN 절이라 같은 값이 여러 번 있어도 결과가 달라지지 않는다).
      final padded = List<String>.from(chunk);
      while (padded.length < _mediaPathChunkRows) {
        padded.add(chunk.first);
      }
      final args = <String>[for (var c = 0; c < _pathColumns.length; c++) ...padded];
      final rows = await db.rawQuery(
        'SELECT ${_pathColumns.join(', ')} FROM ${AppConstants.tableCards} WHERE $where',
        args,
      );
      final wanted = chunk.toSet();
      for (final r in rows) {
        for (final col in _pathColumns) {
          final p = r[col] as String?;
          if (p != null && wanted.contains(p)) found.add(p);
        }
      }
    }
    return found;
  }

  /// 카드 삭제/편집 뒤 미디어 파일 정리 — 다른 카드가 여전히 참조하는 파일은 남긴다.
  Future<void> deleteUnreferencedMediaFiles(Iterable<String> paths) async {
    final wanted = paths.where((p) => p.isNotEmpty).toSet();
    if (wanted.isEmpty) return;
    Set<String> keep;
    try {
      keep = await referencedMediaPaths(wanted);
    } catch (e) {
      // 참조 검사가 실패하면 지우지 않는다 — 고아 파일은 시작 GC가 회수하지만 남의 카드
      // 이미지를 지우면 되돌릴 수 없다.
      debugPrint('[DB] referencedMediaPaths failed, keeping files: $e');
      return;
    }
    for (final path in wanted.difference(keep)) {
      // 감사 D2-07: 재생 중인 파일을 지우기 전에 재생기를 놓아준다.
      await AudioPlaybackController.instance.stopIfPlaying(path);
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  /// 이미지/음성 경로 컬럼의 canonical 목록 — 삭제, 시작 시 GC, 깨진 경로 자가치유,
  /// 배치 insert의 UUID 중복 복구가 전부 이 목록을 통해 컬럼을 순회한다. cards
  /// 스키마의 경로 컬럼 40개와 정확히 일치해야 한다(하나라도 빠지면 그 컬럼은 삭제 시
  /// 파일이 안 지워지거나 깨진 경로가 안 고쳐진다).
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

  /// 테스트 전용 — [_pathColumns]의 컬럼 수. referencedMediaPaths의 청크 크기가
  /// Android SQLite 변수 한도(999) 안에 있는지 검증하는 데 쓴다.
  @visibleForTesting
  static int get pathColumnCount => _pathColumns.length;

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
        // 대소문자를 접어 비교한다 — 잠금화면의 Collator(SECONDARY)와 같은 규칙.
        // 두 번째 키는 접었을 때 같은 문자열의 순서를 고정하기 위한 것이다.
        // (lib/utils/name_sort.dart 참고)
        orderBy = 'question COLLATE NOCASE ASC, question ASC';
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
    // 실제 푸시(PushNotificationService.queryRandomCard)와 같은 모집단 — 폴더 안 전체 카드에서
    // 무작위, 폴더에 카드가 없으면 전체 폴더로 1회 폴백. 예전엔 여기만 '미완료 우선'이라
    // 테스트 알림과 실제 알림이 다른 카드를 뽑았다(D8-11).
    var maps = await db.query(
      AppConstants.tableCards,
      where: folderId != null ? 'folder_id = ?' : null,
      whereArgs: folderId != null ? [folderId] : null,
      orderBy: 'RANDOM()',
      limit: 1,
    );
    if (maps.isEmpty && folderId != null) {
      maps = await db.query(
        AppConstants.tableCards,
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

  /// 트랜잭션 콜백 안에서 다시 트랜잭션을 열면 sqflite는 예외가 아니라 **영구 교착**에
  /// 빠진다(같은 Database의 비재진입 Lock에 자기 자신이 매달린다). 디버그 빌드에서
  /// 즉시 터지게 해 두면 릴리스에서 조용히 멈추는 대신 테스트에서 잡힌다.
  static bool _inSettingsTxn = false;

  /// 설정 **여러 키를 한 트랜잭션 안에서** 읽고 쓴다.
  ///
  /// 여러 화면이 같은 설정을 "읽고 → 고치고 → 되쓰기" 하면, 늦게 끝난 쪽이 옛
  /// 스냅샷으로 먼저 끝난 쪽의 쓰기를 덮는다. 화면 쪽에서 호출을 줄 세우고 있지만
  /// (home_screen.cleanupAfterFolderDelete) 그 줄은 두 번이나 무너졌다. 여기가
  /// 마지막 방어선이다.
  ///
  /// **키 하나씩 따로 부르면 안 된다.** 두 키가 하나의 불변식을 이루면(예: "규칙이
  /// 0개면 스위치는 꺼져 있어야 한다") 호출 사이의 틈에 다른 쓰기가 끼어들어,
  /// 첫 트랜잭션에서 내린 판단이 두 번째를 실행할 때는 이미 거짓이 된다(리뷰 R4-C).
  /// 판단과 쓰기를 같은 트랜잭션 안에 둘 것.
  ///
  /// [transform]은 요청한 키들의 현재 값을 받아, **쓸 키만** 담은 맵을 돌려준다.
  /// 빈 맵이나 null이면 아무것도 쓰지 않는다.
  /// ⚠️ 트랜잭션 안에서 동기로 불리므로 DB를 다시 건드리면 안 된다. 어기면
  /// [StateError]로 즉시 터진다(아래 재진입 가드 참고).
  Future<void> updateSettingsAtomically(
    List<String> keys,
    Map<String, String>? Function(Map<String, String> current) transform,
  ) async {
    // ⚠️ 재진입 검사는 **트랜잭션을 열기 전에** 해야 한다. 안에 두면 아무 소용이
    // 없다: 중첩 호출은 sqflite의 비재진입 락에서 먼저 막혀 콜백 본문이 시작조차
    // 못 하므로, 안에 있는 assert는 영영 실행되지 않고 앱은 조용히 영구 교착한다
    // (실측 확인). 그리고 assert는 릴리스에서 제거되므로 assert 자체로도 부족하다.
    //
    // 플래그는 **동기인 [transform] 실행 구간에만** 세운다. Dart는 단일 스레드라
    // 그 구간에는 [transform]이 직접 부른 코드만 돌 수 있다 — 그래서 이 검사는
    // "중첩"만 잡고, 단순히 동시에 들어온 별개 호출은 잡지 않는다.
    if (_inSettingsTxn) {
      throw StateError(
          'updateSettingsAtomically는 transform 안에서 다시 부를 수 없다 '
          '(sqflite 트랜잭션은 비재진입이라 영구 교착한다)');
    }
    final db = await database;
    await db.transaction((txn) async {
      try {
        final ph = List.filled(keys.length, '?').join(',');
        final rows = await txn.query(
          AppConstants.tableSettings,
          where: 'key IN ($ph)',
          whereArgs: keys,
        );
        final current = <String, String>{};
        for (final r in rows) {
          final k = r['key'];
          final v = r['value'];
          if (k is String && v is String) current[k] = v;
        }
        // 동기 구간에만 깃발을 세운다 — 여기서 부른 코드가 다시 들어오면 위 검사가 잡는다.
        _inSettingsTxn = true;
        final Map<String, String>? next;
        try {
          next = transform(current);
        } finally {
          _inSettingsTxn = false;
        }
        if (next == null || next.isEmpty) return;
        // 요청하지 않은 키를 조용히 새로 만들지 않는다 — 오타 하나가 설정 테이블에
        // 유령 행을 남긴다(리뷰 R5-A).
        assert(next.keys.every(keys.contains),
            'transform이 요청하지 않은 키를 돌려줬다: ${next.keys.where((k) => !keys.contains(k))}');
        for (final entry in next.entries) {
          await txn.insert(
            AppConstants.tableSettings,
            {'key': entry.key, 'value': entry.value},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      } finally {
        // transform 구간을 벗어나면 이미 내려가 있다. 예외로 빠져나온 경우를 위해 한 번 더.
        _inSettingsTxn = false;
      }
    });
  }

  /// Settings 테이블: 단일 key 삭제
  Future<void> deleteSetting(String key) async {
    final db = await database;
    await db.delete(
      AppConstants.tableSettings,
      where: 'key = ?',
      whereArgs: [key],
    );
  }

  // ─── Card Search & Batch ───

  /// LIKE 메타문자 이스케이프
  String _escapeLike(String q) => q
      .replaceAll('\\', '\\\\')
      .replaceAll('%', '\\%')
      .replaceAll('_', '\\_');

  /// 검색 (Question 매치 우선, 단일 쿼리, 대소문자 무시)
  /// 폴더 내 검색. id만 먼저 고른 뒤 [getCardsByIdsBatch]로 청크 로드한다 — 100+ 컬럼
  /// SELECT *를 무제한으로 하면 Android Binder(1MB) 한계에 row가 조용히 손상된다(이 파일의
  /// 다른 모든 카드 로드 경로가 청크를 쓰는 이유). 검색만 그 규약의 유일한 구멍이었다.
  Future<List<CardModel>> searchCards(int folderId, String query) async {
    final db = await database;
    final escaped = _escapeLike(query);
    final pattern = '%$escaped%';
    final idRows = await db.rawQuery(
      "SELECT id FROM ${AppConstants.tableCards} "
      "WHERE folder_id = ? AND (question LIKE ? ESCAPE '\\' COLLATE NOCASE OR answer LIKE ? ESCAPE '\\' COLLATE NOCASE) "
      "ORDER BY CASE WHEN question LIKE ? ESCAPE '\\' COLLATE NOCASE THEN 0 ELSE 1 END, sequence ASC",
      [folderId, pattern, pattern, pattern],
    );
    return _loadCardsInOrder(idRows.map((r) => r['id'] as int).toList());
  }

  /// 전체 카드 검색 (allCards 모드, 대소문자 무시). 결과를 1000개로 제한하여 대량 카드에서
  /// OOM 방지. 로드는 [searchCards]와 같은 id-only + 청크 규약.
  Future<List<CardModel>> searchAllCards(String query) async {
    final db = await database;
    final escaped = _escapeLike(query);
    final pattern = '%$escaped%';
    final idRows = await db.rawQuery(
      "SELECT id FROM ${AppConstants.tableCards} "
      "WHERE question LIKE ? ESCAPE '\\' COLLATE NOCASE OR answer LIKE ? ESCAPE '\\' COLLATE NOCASE "
      "ORDER BY CASE WHEN question LIKE ? ESCAPE '\\' COLLATE NOCASE THEN 0 ELSE 1 END, folder_id, sequence ASC "
      "LIMIT 1000",
      [pattern, pattern, pattern],
    );
    return _loadCardsInOrder(idRows.map((r) => r['id'] as int).toList());
  }

  /// id 순서를 보존하며 청크 로드. 조회 사이에 삭제된 id는 조용히 빠진다.
  Future<List<CardModel>> _loadCardsInOrder(List<int> orderedIds) async {
    if (orderedIds.isEmpty) return const [];
    final byId = await getCardsByIdsBatch(orderedIds);
    return orderedIds.map((id) => byId[id]).whereType<CardModel>().toList();
  }

  /// 배치 삭제 (영향받는 폴더 card_count 자동 갱신)
  /// cardIds 개수에 제한 없음 — IN 절은 청크 단위로 분할 실행.
  Future<int> deleteCardsBatch(List<int> cardIds) async {
    if (cardIds.isEmpty) return 0;
    final db = await database;
    int deleted = 0;
    await db.transaction((txn) async {
      final folderIds = <int>{};

      for (var i = 0; i < cardIds.length; i += _sqlInChunkSize) {
        final chunk = cardIds.sublist(
            i,
            i + _sqlInChunkSize > cardIds.length
                ? cardIds.length
                : i + _sqlInChunkSize);
        final placeholders = List.filled(chunk.length, '?').join(',');

        // 삭제 전 영향받는 폴더 ID 수집 (청크별)
        final affected = await txn.rawQuery(
          'SELECT DISTINCT folder_id FROM ${AppConstants.tableCards} WHERE id IN ($placeholders)',
          chunk,
        );
        folderIds.addAll(affected.map((r) => r['folder_id'] as int));

        // 청크별 DELETE
        deleted += await txn.rawDelete(
          'DELETE FROM ${AppConstants.tableCards} WHERE id IN ($placeholders)',
          chunk,
        );
      }

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

  /// 테스트 전용 — [_sqlInChunkSize] 노출. ffi 테스트 백엔드는 SQLite 변수 한도가
  /// 32,766이라 청크 동작 자체를 관찰 못 한다 — 이 값이 Android 한도(999) 안에
  /// 있는지는 이 getter로 직접 확인해야 한다.
  @visibleForTesting
  static int get sqlInChunkSize => _sqlInChunkSize;

  /// 배치 이동 (원본/대상 폴더 card_count 자동 갱신).
  /// cardIds 개수에 제한 없음 — IN 절은 청크 단위로 분할 실행.
  Future<void> moveCardsBatch(List<int> cardIds, int newFolderId) async {
    if (cardIds.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final oldFolderIds = <int>{};
      // 대상 폴더의 현재 최대 sequence — 여기서부터 이어 붙인다.
      var nextSeq = Sqflite.firstIntValue(await txn.rawQuery(
            'SELECT MAX(sequence) FROM ${AppConstants.tableCards} WHERE folder_id = ?',
            [newFolderId],
          )) ??
          0;

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

        // 청크별 UPDATE. sequence도 대상 폴더 맨 뒤로 새로 매긴다 — 원래 번호를 그대로
        // 들고 가면 기존 카드 사이에 흩어져 끼고 번호가 겹친다(감사 D2-03/D8-01).
        // 새 카드 생성이 쓰는 규칙(getMaxSequence+1)과 같게 맞춘다.
        for (final id in chunk) {
          await txn.rawUpdate(
            'UPDATE ${AppConstants.tableCards} SET folder_id = ?, sequence = ? WHERE id = ?',
            [newFolderId, ++nextSeq, id],
          );
        }
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
        if (!await file.exists()) {
          // 파일이 아직 없어도 경로는 그대로 둔다. 예전엔 비웠는데(X4-04), 그건 "두 카드가
          // 같은 경로를 가리키면 한쪽 삭제가 다른 쪽 파일을 지운다"는 이유였다. 지금은 삭제가
          // [deleteUnreferencedMediaFiles]로 **살아있는 DB 참조**를 먼저 확인하므로 공유 자체가
          // 위험하지 않다. 경로를 살려 두면 재import(uuid 복구)로 파일이 돌아왔을 때 원본과
          // 복제본이 함께 되살아난다 — 비워 두면 복제본만 영영 빈 슬롯으로 남았다(리뷰 P-04).
          continue;
        }
        final dir = file.parent.path;
        final ext = p.extension(path);
        final ts = DateTime.now().microsecondsSinceEpoch;
        final newPath = p.join(dir, 'copy_${ts}_${counter++}$ext');
        await file.copy(newPath);
        dbMap[key] = newPath;
      } catch (e) {
        // 복사 실패 시에도 원본 경로를 유지한다 — 위와 같은 이유로 공유는 이제 안전하고,
        // 비우면 복제본이 이미지 없는 카드가 된다(리뷰 P-04).
        debugPrint('[DB] _duplicateFiles copy failed for $key: $e');
      }
    }
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
        // 대소문자를 접어 비교한다 — 잠금화면의 Collator(SECONDARY)와 같은 규칙.
        // 두 번째 키는 접었을 때 같은 문자열의 순서를 고정하기 위한 것이다.
        // (lib/utils/name_sort.dart 참고)
        orderBy = 'question COLLATE NOCASE ASC, question ASC';
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

  /// .mra 파일 row 여러개를 단일 transaction으로 삭제.
  /// ids 개수에 제한 없음 — IN 절은 청크 단위로 분할 실행.
  Future<int> deleteExportedFilesBatch(List<int> ids) async {
    if (ids.isEmpty) return 0;
    final db = await database;
    int deleted = 0;
    await db.transaction((txn) async {
      for (var i = 0; i < ids.length; i += _sqlInChunkSize) {
        final chunk = ids.sublist(
            i,
            i + _sqlInChunkSize > ids.length
                ? ids.length
                : i + _sqlInChunkSize);
        final ph = List.filled(chunk.length, '?').join(',');
        deleted += await txn.rawDelete(
          'DELETE FROM ${AppConstants.tableExportedFiles} WHERE id IN ($ph)',
          chunk,
        );
      }
    });
    return deleted;
  }

  Future<int> deleteExportedFileByPath(String filePath) async {
    final db = await database;
    return await db.delete(
      AppConstants.tableExportedFiles,
      where: 'file_path = ?',
      whereArgs: [filePath],
    );
  }

  // ─── Push Alarms CRUD ───

  Future<List<Map<String, dynamic>>> getAllPushAlarms() async {
    final db = await database;
    return await db.query(AppConstants.tablePushAlarms);
  }

  /// 존재하지 않는 이미지/음성 파일 경로를 DB에서 일괄 제거
  /// 앱 시작 시 1회 실행하여 깨진 이미지 참조를 정리
  /// 배치 처리로 OOM 방지 (대량 카드 대응)
  /// 어느 카드도 참조하지 않는 images/ 디렉토리의 고아 미디어 파일을 삭제한다.
  /// 일괄/폴더 삭제의 fire-and-forget 파일정리가 앱 강제종료·개별 실패로 놓친
  /// 잔여물을 청소해 "흔적 0"을 보장한다. 반환: 삭제한 파일 수.
  ///
  /// ⚠️ 파일을 영구 삭제하므로 참조 집합은 반드시 canonical [_pathColumns] 전체로
  ///    정확히 구성한다(누락 시 실제 참조 파일이 지워질 수 있음). 호출자는 import
  ///    진행 중이면 이 메서드를 건너뛴다(복사됐지만 카드 insert 전인 파일 보호).
  ///    앱 시작 시점에만 호출해 카드 생성/편집과의 경합을 피한다.
  Future<int> cleanupOrphanMediaFiles() async {
    final db = await database;

    // 1) 모든 카드가 참조하는 미디어 파일 basename 집합.
    //    대형 라이브러리의 Android Binder(1MB) 커서 한계를 피해 id 기반 페이징
    //    (offset 드리프트도 방지). 앱 시작 시점이라 동시 쓰기가 없다.
    final referenced = <String>{};
    const batchSize = 500;
    int lastMaxId = 0;
    while (true) {
      final rows = await db.query(
        AppConstants.tableCards,
        columns: ['id', ..._pathColumns],
        where: 'id > ?',
        whereArgs: [lastMaxId],
        orderBy: 'id ASC',
        limit: batchSize,
      );
      if (rows.isEmpty) break;
      // 스캔은 수천 장이면 수 초짜리다 — 그 사이 import가 시작됐으면 여기서 물러난다.
      if (await _importInProgress()) {
        debugPrint('[GC] import 시작 감지 — 고아 정리 중단');
        return 0;
      }
      lastMaxId = rows.last['id'] as int;
      for (final row in rows) {
        for (final col in _pathColumns) {
          final path = row[col] as String?;
          if (path != null && path.isNotEmpty) referenced.add(p.basename(path));
        }
      }
      if (rows.length < batchSize) break;
    }

    // 2) images/ 스캔 → 어느 카드도 참조하지 않는 파일 삭제.
    final docDir = await getApplicationDocumentsDirectory();
    final mediaDir = Directory(p.join(docDir.path, AppConstants.imageDir));
    if (!await mediaDir.exists()) return 0;

    final candidates = <File>[];
    await for (final entity in mediaDir.list(followLinks: false)) {
      if (entity is! File) continue;
      final base = p.basename(entity.path);
      if (base.startsWith('.')) continue; // .nomedia 등 숨김/시스템 파일 보호
      if (referenced.contains(base)) continue; // 참조됨 → 보존
      candidates.add(entity);
    }
    // 안전장치 ①: 참조가 0건인데 지울 파일이 많다 = 경로 접두사 변화·DB 손상 등으로
    //   "전부 고아"로 보이는 상황일 가능성이 크다(cleanupBrokenImagePaths가 참조를 전부
    //   비운 직후가 전형). 그럴 땐 이번 실행을 건너뛴다 — 지우는 건 되돌릴 수 없다.
    if (referenced.isEmpty && candidates.length >= 20) {
      debugPrint('[GC] 참조 0건인데 후보 ${candidates.length}개 — 안전장치로 건너뜀');
      return 0;
    }
    if (await _importInProgress()) return 0;

    // 안전장치 ②: 최근 10분 내 생성/수정된 파일은 보호 — 편집 중 복사본, 녹음 진행 중
    //   파일, import가 방금 추출한 파일은 아직 DB 참조가 없을 수 있다. 이 GC는 runApp과
    //   동시에 돌므로 "시작 시점이라 동시 쓰기가 없다"는 가정은 성립하지 않는다.
    final now = DateTime.now();
    int deleted = 0;
    for (final f in candidates) {
      try {
        final modified = (await f.stat()).modified;
        if (now.difference(modified) < const Duration(minutes: 10)) continue;
        await f.delete();
        deleted++;
      } catch (_) {
        // 잠금·권한 등 — 다음 시작 때 재시도
      }
    }
    return deleted;
  }

  /// import가 진행 중인가(`import_in_progress` 마커). 시작 GC가 배치마다 다시 묻는다.
  Future<bool> _importInProgress() async {
    final db = await database;
    final rows = await db.query(
      AppConstants.tableSettings,
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['import_in_progress'],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    final v = rows.first['value'] as String?;
    return v != null && v.isNotEmpty;
  }

  Future<int> cleanupBrokenImagePaths() async {
    final db = await database;
    // 스캔 시작 시점의 최대 id — 스캔 도중 import된 카드(더 큰 id)는 건드리지 않는다.
    // import는 카드 insert 뒤에 이미지를 추출하므로 그 사이에 보면 "파일 없음"처럼 보인다.
    final maxRow = await db.rawQuery(
        'SELECT MAX(id) AS m FROM ${AppConstants.tableCards}');
    final maxIdAtStart = (maxRow.first['m'] as int?) ?? 0;
    final docDir = await getApplicationDocumentsDirectory();
    final mediaDirPath = p.join(docDir.path, AppConstants.imageDir);

    final whereClauses =
        _pathColumns.map((c) => "($c IS NOT NULL AND $c != '')").join(' OR ');

    int cleaned = 0;
    const batchSize = 500;

    // ID 기반 페이지네이션: offset 드리프트 방지
    // 처리된 ID를 추적하여 무한 루프 방지
    int lastMaxId = 0;

    while (true) {
      // ID 기반 페이지네이션으로 offset 드리프트 문제 해결
      final rows = await db.query(
        AppConstants.tableCards,
        columns: ['id', ..._pathColumns],
        where: 'id > ? AND id <= ? AND ($whereClauses)',
        whereArgs: [lastMaxId, maxIdAtStart],
        orderBy: 'id ASC',
        limit: batchSize,
      );
      if (rows.isEmpty) break;
      // 배치마다 import 마커를 다시 본다 — 진입 시 1회 검사로는 스캔 중 시작된 import의
      // 미추출 이미지 경로를 blank해 버린다(추출이 성공해도 카드는 영구히 이미지를 잃음).
      if (await _importInProgress()) {
        debugPrint('[GC] import 시작 감지 — 깨진 경로 정리 중단');
        break;
      }

      // 이 배치의 최대 ID 기록 (다음 배치의 시작점)
      lastMaxId = rows.last['id'] as int;

      // 파일 존재 확인은 비동기로 (UI 스레드 블로킹 방지)
      final batchUpdates = <int, Map<String, dynamic>>{};
      for (final row in rows) {
        final updates = <String, dynamic>{};
        for (final col in _pathColumns) {
          final path = row[col] as String?;
          if (path == null || path.isEmpty) continue;
          if (!await File(path).exists()) {
            // 자가치유: 같은 파일명이 현재 앱의 images/ 에 있으면 경로 접두사만 바뀐
            // 것이다(백업 복원·프로필 이동 등으로 앱 데이터 디렉토리가 달라진 경우).
            // 참조를 비워버리면 바로 다음 단계인 고아 정리가 멀쩡한 파일까지 지우는
            // 연쇄가 되므로, 지우지 않고 경로를 고쳐 쓴다.
            final healed = p.join(mediaDirPath, p.basename(path));
            if (healed != path && await File(healed).exists()) {
              updates[col] = healed;
            } else {
              updates[col] = '';
            }
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
