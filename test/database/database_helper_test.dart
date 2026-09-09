// DatabaseHelper 하드닝 스위트. 표 1개 = group 1개. 각 group은 db_test_harness의
// setUp/tearDown으로 완전히 격리된 sqflite_common_ffi DB(임시 디렉토리)를 쓴다.
//
// 이 스위트의 각 행은 나중에 한 줄짜리 프로덕션 돌연변이(negative control)로 실제
// 빨간불이 되는지 확인됐다 — 결과는 스크래치패드의 negative_controls.md 참고.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:memora/database/database_helper.dart';
import 'package:memora/utils/constants.dart';
import 'package:memora/utils/name_sort.dart';

import '../helpers/db_test_harness.dart';

/// 테이블 컬럼 집합(폴더/push_alarms/exported_files) + cards 인덱스 이름 집합.
/// 업그레이드된 DB와 새로 만든(fresh) v4 DB가 정확히 같은 모양인지 비교하는 데 쓴다.
Future<Map<String, Object?>> _schemaFingerprint(Database db) async {
  Future<Set<String>> cols(String table) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    return rows.map((r) => r['name'] as String).toSet();
  }

  Future<Set<String>> indexNames(String table) async {
    final rows = await db.rawQuery('PRAGMA index_list($table)');
    return rows.map((r) => r['name'] as String).toSet();
  }

  return {
    'folders': await cols('folders'),
    'push_alarms': await cols('push_alarms'),
    'exported_files': await cols('exported_files'),
    'cards_indexes': await indexNames('cards'),
  };
}

void main() {
  group('#1 _upgradeDB — v1/v2/v3 → v4', () {
    late Map<String, Object?> freshFingerprint;

    setUpAll(() async {
      final baseline = await initDbTestEnv();
      final db = await DatabaseHelper.instance.database;
      freshFingerprint = await _schemaFingerprint(db);
      await tearDownDbTestEnv(baseline);
    });

    late Directory docs;
    setUp(() async => docs = await initDbTestEnv());
    tearDown(() async => tearDownDbTestEnv(docs));

    for (final legacyVersion in [1, 2, 3]) {
      test('v$legacyVersion → v4: 스키마가 fresh v4와 일치하고 기존 행이 보존된다',
          () async {
        await openLegacyDb(docs, legacyVersion);

        final path = p.join(docs.path, AppConstants.dbName);
        final raw = await databaseFactoryFfi.openDatabase(path);
        final legacyFolderId =
            await raw.insert('folders', {'name': 'legacy-folder', 'sequence': 0});
        await raw.insert('cards', {
          'uuid': 'legacy-uuid-1',
          'folder_id': legacyFolderId,
          'question': 'legacy-q',
          'sequence': 0,
        });
        await raw.close();

        final db = await DatabaseHelper.instance.database;

        final versionRow = await db.rawQuery('PRAGMA user_version');
        expect(Sqflite.firstIntValue(versionRow), 4);

        final fp = await _schemaFingerprint(db);
        expect(fp, equals(freshFingerprint));

        final folders =
            await db.query('folders', where: 'name = ?', whereArgs: ['legacy-folder']);
        expect(folders, hasLength(1));
        final cards =
            await db.query('cards', where: 'uuid = ?', whereArgs: ['legacy-uuid-1']);
        expect(cards, hasLength(1));
        expect(cards.single['question'], 'legacy-q');
      });
    }
  });

  group('#2 deleteFoldersBatch', () {
    late Directory docs;
    setUp(() async => docs = await initDbTestEnv());
    tearDown(() async => tearDownDbTestEnv(docs));

    test(
        '일반 폴더 삭제(500 페이징 루프 2회) + 번들 자식 승격 + push_alarms 해제 + '
        '파일 경로 회수 + 다른 번들 folder_count 보정', () async {
      final db = await DatabaseHelper.instance.database;

      final regularAId =
          await db.insert('folders', fixtureFolder(name: 'A', sequence: 0).toDb());
      final regularBId =
          await db.insert('folders', fixtureFolder(name: 'B', sequence: 1).toDb());
      final bundle1Id = await db.insert(
          'folders', fixtureFolder(name: 'Bundle1', isBundle: true, sequence: 5).toDb());
      final child1Id = await db.insert(
          'folders',
          fixtureFolder(name: 'child1', sequence: 10, parentFolderId: bundle1Id).toDb());
      final child2Id = await db.insert(
          'folders',
          fixtureFolder(name: 'child2', sequence: 3, parentFolderId: bundle1Id).toDb());

      // regularA가 유일한 자식인 bundle2 — 삭제 뒤 folder_count가 실제 자식 수(0)로 보정돼야 한다.
      final bundle2Id = await db.insert(
          'folders', fixtureFolder(name: 'Bundle2', isBundle: true, sequence: 2).toDb());
      await db.update('folders', {'parent_folder_id': bundle2Id, 'folder_count': 99},
          where: 'id = ?', whereArgs: [regularAId]);
      await db.update('folders', {'folder_count': 1},
          where: 'id = ?', whereArgs: [bundle2Id]);

      // B에 600장(경로 있는 599장 + 빈 경로 1장) — 500/OFFSET 루프가 두 번 돈다.
      final expectedPaths = <String>{};
      for (var i = 0; i < 599; i++) {
        final path = 'media_$i.jpg';
        expectedPaths.add(path);
        await db.insert(
            'cards',
            fixtureCard(
              folderId: regularBId,
              uuid: 'b-$i',
              overrides: {'question_image_path': path},
            ).toDb());
      }
      await db.insert(
          'cards',
          fixtureCard(
            folderId: regularBId,
            uuid: 'b-599',
            overrides: {'question_image_path': ''},
          ).toDb());
      await db.insert('cards', fixtureCard(folderId: regularAId, uuid: 'a-1').toDb());

      final alarmAId =
          await db.insert('push_alarms', {'time': '09:00', 'folder_id': regularAId});
      final alarmBId =
          await db.insert('push_alarms', {'time': '10:00', 'folder_id': regularBId});

      final result = await DatabaseHelper.instance.deleteFoldersBatch(
        regularFolderIds: [regularAId, regularBId],
        bundleFolderIds: [bundle1Id],
      );

      expect(result.pushReschedNeeded, isTrue);
      expect(result.filePaths.toSet(), expectedPaths);
      expect(result.filePaths.every((p) => p.isNotEmpty), isTrue);
      expect(result.filePaths, hasLength(599));

      expect(
          await db.query('cards', where: 'folder_id IN (?, ?)', whereArgs: [regularAId, regularBId]),
          isEmpty);
      expect(
          await db.query('folders',
              where: 'id IN (?, ?, ?)', whereArgs: [regularAId, regularBId, bundle1Id]),
          isEmpty);

      final alarms = await db.query('push_alarms',
          where: 'id IN (?, ?)', whereArgs: [alarmAId, alarmBId]);
      expect(alarms.every((r) => r['folder_id'] == null), isTrue);

      final child1 = (await db.query('folders', where: 'id = ?', whereArgs: [child1Id])).single;
      final child2 = (await db.query('folders', where: 'id = ?', whereArgs: [child2Id])).single;
      expect(child1['parent_folder_id'], isNull);
      expect(child2['parent_folder_id'], isNull);
      // 승격 전 최상위 최대 sequence(=5, bundle1 자신)보다 크고 서로 달라야 한다.
      expect(child1['sequence'], greaterThan(5));
      expect(child2['sequence'], greaterThan(5));
      expect(child1['sequence'], isNot(child2['sequence']));

      final bundle2 = (await db.query('folders', where: 'id = ?', whereArgs: [bundle2Id])).single;
      expect(bundle2['folder_count'], 0);
    });
  });

  group('#3 _unlinkFromBundle (via deleteFoldersBatch) — 승격 순서', () {
    late Directory docs;
    setUp(() async => docs = await initDbTestEnv());
    tearDown(() async => tearDownDbTestEnv(docs));

    test('자식 1000개, sequence 셔플 — 승격 순서는 묶음 안 sequence 오름차순, 번호는 max+1부터 증가',
        () async {
      final db = await DatabaseHelper.instance.database;
      await db.insert('folders', fixtureFolder(name: 'pre', sequence: 100).toDb());
      final bundleId =
          await db.insert('folders', fixtureFolder(name: 'Bundle', isBundle: true, sequence: 50).toDb());

      final shuffledSeqs = List<int>.generate(1000, (i) => i)..shuffle();
      final childIds = <int>[];
      for (var i = 0; i < 1000; i++) {
        final id = await db.insert(
            'folders',
            fixtureFolder(
              name: 'child_$i',
              sequence: shuffledSeqs[i],
              parentFolderId: bundleId,
            ).toDb());
        childIds.add(id);
      }
      final idToOldSeq = {for (var i = 0; i < 1000; i++) childIds[i]: shuffledSeqs[i]};

      await DatabaseHelper.instance
          .deleteFoldersBatch(regularFolderIds: [], bundleFolderIds: [bundleId]);

      final promoted = await db.query('folders',
          where: 'parent_folder_id IS NULL AND name != ?', whereArgs: ['pre']);
      expect(promoted, hasLength(1000));

      final sortedByNewSeq = List<Map<String, Object?>>.from(promoted)
        ..sort((a, b) => (a['sequence'] as int).compareTo(b['sequence'] as int));

      final newSeqs = sortedByNewSeq.map((r) => r['sequence'] as int).toList();
      for (var i = 0; i < newSeqs.length; i++) {
        expect(newSeqs[i], 101 + i, reason: '최상위 max(100)+1부터 연속 증가해야 한다');
      }

      final oldSeqOrder =
          sortedByNewSeq.map((r) => idToOldSeq[r['id'] as int]!).toList();
      final expectedOldSeqOrder = List<int>.from(shuffledSeqs)..sort();
      expect(oldSeqOrder, expectedOldSeqOrder,
          reason: '새 번호 오름차순으로 봤을 때, 원래 묶음 안 sequence도 오름차순이어야 한다');
    });
  });

  group('#4 chunk 산술 (_sqlInChunkSize = 800)', () {
    late Directory docs;
    setUp(() async => docs = await initDbTestEnv());
    tearDown(() async => tearDownDbTestEnv(docs));

    test('deleteCardsBatch: 1700개 id (800+800+100 청크)', () async {
      final db = await DatabaseHelper.instance.database;
      final folderXId = await db.insert('folders', fixtureFolder(name: 'X').toDb());
      final folderYId = await db.insert('folders', fixtureFolder(name: 'Y').toDb());

      final toDelete = <int>[];
      for (var i = 0; i < 900; i++) {
        toDelete.add(await db.insert(
            'cards', fixtureCard(folderId: folderXId, uuid: 'x-$i').toDb()));
      }
      final leftoverId = await db.insert(
          'cards', fixtureCard(folderId: folderXId, uuid: 'x-leftover').toDb());
      for (var i = 0; i < 800; i++) {
        toDelete.add(await db.insert(
            'cards', fixtureCard(folderId: folderYId, uuid: 'y-$i').toDb()));
      }
      expect(toDelete, hasLength(1700));

      final deleted = await DatabaseHelper.instance.deleteCardsBatch(toDelete);
      expect(deleted, 1700);

      expect(await db.query('cards', where: 'id IN (${toDelete.join(',')})'), isEmpty);
      expect(await db.query('cards', where: 'id = ?', whereArgs: [leftoverId]), hasLength(1));

      final xFolder = (await db.query('folders', where: 'id = ?', whereArgs: [folderXId])).single;
      final yFolder = (await db.query('folders', where: 'id = ?', whereArgs: [folderYId])).single;
      expect(xFolder['card_count'], 1);
      expect(yFolder['card_count'], 0);
    });

    test('deleteFoldersBatch: 일반 폴더 900개 (800+100 청크)', () async {
      final db = await DatabaseHelper.instance.database;
      final folderIds = <int>[];
      for (var i = 0; i < 900; i++) {
        final fid = await db.insert('folders', fixtureFolder(name: 'F$i').toDb());
        await db.insert('cards', fixtureCard(folderId: fid, uuid: 'c-$i').toDb());
        folderIds.add(fid);
      }

      final result = await DatabaseHelper.instance
          .deleteFoldersBatch(regularFolderIds: folderIds, bundleFolderIds: []);

      expect(result.filePaths, isEmpty);
      expect(await db.query('folders', where: 'id IN (${folderIds.join(',')})'), isEmpty);
      expect(await db.query('cards', where: 'folder_id IN (${folderIds.join(',')})'), isEmpty);
    });
  });

  group('#5 updateSettingsAtomically + _inSettingsTxn', () {
    late Directory docs;
    setUp(() async => docs = await initDbTestEnv());
    tearDown(() async => tearDownDbTestEnv(docs));

    test('(a) transform이 돌려준 키만 쓴다', () async {
      final db = await DatabaseHelper.instance.database;
      await db.insert('settings', {'key': 'k1', 'value': 'v1'});
      await DatabaseHelper.instance
          .updateSettingsAtomically(['k1', 'k2'], (current) => {'k1': 'v1-new'});
      final rows = await db.query('settings');
      final map = {for (final r in rows) r['key'] as String: r['value']};
      expect(map['k1'], 'v1-new');
      expect(map.containsKey('k2'), isFalse);
    });

    test('(b) null 또는 빈 맵을 돌려주면 아무것도 쓰지 않는다', () async {
      final db = await DatabaseHelper.instance.database;
      await db.insert('settings', {'key': 'k1', 'value': 'orig'});
      await DatabaseHelper.instance.updateSettingsAtomically(['k1'], (current) => null);
      await DatabaseHelper.instance.updateSettingsAtomically(['k1'], (current) => {});
      final row =
          (await db.query('settings', where: 'key = ?', whereArgs: ['k1'])).single;
      expect(row['value'], 'orig');
    });

    test('(c) 요청하지 않은 키를 돌려주면 AssertionError', () async {
      await expectLater(
        DatabaseHelper.instance
            .updateSettingsAtomically(['k1'], (current) => {'other': 'x'}),
        throwsA(isA<AssertionError>()),
      );
    });

    group('(d) transform 안에서 재호출 — 타임아웃 10초로 hang을 감지', () {
      test('재진입은 StateError로 즉시 실패한다(교착 없이)', () async {
        late Future<Object?> reentrant;
        await DatabaseHelper.instance.updateSettingsAtomically(['k1'], (current) {
          reentrant = DatabaseHelper.instance
              .updateSettingsAtomically(['k1'], (inner) => {'k1': 'nested'})
              .then<Object?>((_) => null, onError: (Object e) => e);
          return {'k1': 'outer'};
        });
        expect(await reentrant, isA<StateError>());
      }, timeout: const Timeout(Duration(seconds: 10)));
    });

    test('(e) transform이 던지면 바깥으로 rethrow, 다음 정상 호출은 성공한다', () async {
      await expectLater(
        DatabaseHelper.instance.updateSettingsAtomically(['k1'], (current) {
          throw StateError('boom');
        }),
        throwsA(isA<StateError>()),
      );

      await DatabaseHelper.instance
          .updateSettingsAtomically(['k1'], (current) => {'k1': 'ok'});
      final db = await DatabaseHelper.instance.database;
      final row =
          (await db.query('settings', where: 'key = ?', whereArgs: ['k1'])).single;
      expect(row['value'], 'ok');
    });
  });

  group('#6 insertCardsBatch — UUID 중복 시 빈 이미지 경로만 복구', () {
    late Directory docs;
    setUp(() async => docs = await initDbTestEnv());
    tearDown(() async => tearDownDbTestEnv(docs));

    test('빈 경로는 복구되고, 값 있는 경로는 클로버되지 않는다', () async {
      final db = await DatabaseHelper.instance.database;
      final folderId = await db.insert('folders', fixtureFolder(name: 'F').toDb());
      const uuid = 'dup-uuid';

      final first = fixtureCard(
        folderId: folderId,
        uuid: uuid,
        overrides: {'question_image_path': '', 'answer_image_path': 'a'},
      );
      final r1 = await DatabaseHelper.instance.insertCardsBatch([first]);
      expect(r1.inserted, 1);
      expect(r1.skipped, 0);

      final second = fixtureCard(
        folderId: folderId,
        uuid: uuid,
        overrides: {'question_image_path': 'y', 'answer_image_path': 'b'},
      );
      final r2 = await DatabaseHelper.instance.insertCardsBatch([second]);
      expect(r2.inserted, 0);
      expect(r2.skipped, 1);

      final rows = await db.query('cards', where: 'uuid = ?', whereArgs: [uuid]);
      expect(rows, hasLength(1));
      expect(rows.single['question_image_path'], 'y', reason: '비어 있던 경로는 복구되어야 한다');
      expect(rows.single['answer_image_path'], 'a', reason: '값 있는 경로는 유지돼야 한다');
    });
  });

  group('#7 moveCardsBatch / moveCard', () {
    late Directory docs;
    setUp(() async => docs = await initDbTestEnv());
    tearDown(() async => tearDownDbTestEnv(docs));

    test('배치 이동: 대상 폴더 맨 뒤로 이어붙는다, 양쪽 card_count 갱신', () async {
      final db = await DatabaseHelper.instance.database;
      final folderAId = await db.insert('folders', fixtureFolder(name: 'A').toDb());
      final folderBId = await db.insert('folders', fixtureFolder(name: 'B').toDb());
      await db.insert(
          'cards', fixtureCard(folderId: folderBId, uuid: 'b-existing', sequence: 5).toDb());
      final id1 = await db.insert('cards', fixtureCard(folderId: folderAId, uuid: 'a1').toDb());
      final id2 = await db.insert('cards', fixtureCard(folderId: folderAId, uuid: 'a2').toDb());
      final id3 = await db.insert('cards', fixtureCard(folderId: folderAId, uuid: 'a3').toDb());

      await DatabaseHelper.instance.moveCardsBatch([id1, id2, id3], folderBId);

      Future<int> seqOf(int id) async =>
          (await db.query('cards', where: 'id = ?', whereArgs: [id])).single['sequence'] as int;
      expect(await seqOf(id1), 6);
      expect(await seqOf(id2), 7);
      expect(await seqOf(id3), 8);

      final aFolder = (await db.query('folders', where: 'id = ?', whereArgs: [folderAId])).single;
      final bFolder = (await db.query('folders', where: 'id = ?', whereArgs: [folderBId])).single;
      expect(aFolder['card_count'], 0);
      expect(bFolder['card_count'], 4);
    });

    test('moveCard: 같은 폴더로 이동은 sequence를 건드리지 않는다', () async {
      final db = await DatabaseHelper.instance.database;
      final folderId = await db.insert('folders', fixtureFolder(name: 'A').toDb());
      final cardId =
          await db.insert('cards', fixtureCard(folderId: folderId, uuid: 'c1', sequence: 3).toDb());

      final result = await DatabaseHelper.instance.moveCard(cardId, folderId);
      expect(result, 1);
      final row = (await db.query('cards', where: 'id = ?', whereArgs: [cardId])).single;
      expect(row['sequence'], 3);
    });

    test('moveCard: fields에 명시된 sequence를 존중한다', () async {
      final db = await DatabaseHelper.instance.database;
      final folderAId = await db.insert('folders', fixtureFolder(name: 'A').toDb());
      final folderBId = await db.insert('folders', fixtureFolder(name: 'B').toDb());
      final cardId = await db.insert('cards', fixtureCard(folderId: folderAId, uuid: 'c1').toDb());

      await DatabaseHelper.instance
          .moveCard(cardId, folderBId, fields: {'sequence': 42});

      final row = (await db.query('cards', where: 'id = ?', whereArgs: [cardId])).single;
      expect(row['sequence'], 42);
      expect(row['folder_id'], folderBId);
    });

    test('moveCard: 다른 폴더 이동 + fields 적용, 양쪽 card_count 갱신', () async {
      final db = await DatabaseHelper.instance.database;
      final folderAId = await db.insert('folders', fixtureFolder(name: 'A').toDb());
      final folderBId = await db.insert('folders', fixtureFolder(name: 'B').toDb());
      await db.insert(
          'cards', fixtureCard(folderId: folderBId, uuid: 'b-existing', sequence: 9).toDb());
      final cardId = await db.insert(
          'cards', fixtureCard(folderId: folderAId, uuid: 'c1', question: 'old').toDb());

      await DatabaseHelper.instance
          .moveCard(cardId, folderBId, fields: {'question': 'new-q'});

      final row = (await db.query('cards', where: 'id = ?', whereArgs: [cardId])).single;
      expect(row['sequence'], 10);
      expect(row['question'], 'new-q');
      expect(row['folder_id'], folderBId);

      final aFolder = (await db.query('folders', where: 'id = ?', whereArgs: [folderAId])).single;
      final bFolder = (await db.query('folders', where: 'id = ?', whereArgs: [folderBId])).single;
      expect(aFolder['card_count'], 0);
      expect(bFolder['card_count'], 2);
    });
  });

  group('#8 saveBundleFolder', () {
    late Directory docs;
    setUp(() async => docs = await initDbTestEnv());
    tearDown(() async => tearDownDbTestEnv(docs));

    test('생성: is_bundle=1, sequence=전역 max+1, 가짜/번들 id는 folder_count에서 제외',
        () async {
      final db = await DatabaseHelper.instance.database;
      final f1 = await db.insert('folders', fixtureFolder(name: 'f1', sequence: 3).toDb());
      final f2 = await db.insert('folders', fixtureFolder(name: 'f2', sequence: 7).toDb());
      final existingBundle = await db.insert(
          'folders', fixtureFolder(name: 'old-bundle', isBundle: true, sequence: 10).toDb());
      const bogusId = 999999;

      final bundleId = await DatabaseHelper.instance.saveBundleFolder(
        bundleId: null,
        bundleName: 'MyBundle',
        selectedChildIds: {f1, f2, bogusId, existingBundle},
      );

      final row = (await db.query('folders', where: 'id = ?', whereArgs: [bundleId])).single;
      expect(row['is_bundle'], 1);
      expect(row['sequence'], 11);
      expect(row['folder_count'], 2);

      final f1Row = (await db.query('folders', where: 'id = ?', whereArgs: [f1])).single;
      final f2Row = (await db.query('folders', where: 'id = ?', whereArgs: [f2])).single;
      expect(f1Row['parent_folder_id'], bundleId);
      expect(f2Row['parent_folder_id'], bundleId);
    });

    test('편집: 이름 변경 + 자식 하나 제거/하나 추가 → folder_count 보정, 뺀 자식은 승격',
        () async {
      final db = await DatabaseHelper.instance.database;
      final f1 = await db.insert('folders', fixtureFolder(name: 'f1').toDb());
      final f2 = await db.insert('folders', fixtureFolder(name: 'f2').toDb());
      final f3 = await db.insert('folders', fixtureFolder(name: 'f3').toDb());

      final bundleId = await DatabaseHelper.instance.saveBundleFolder(
        bundleId: null,
        bundleName: 'B1',
        selectedChildIds: {f1, f2},
      );

      final resultId = await DatabaseHelper.instance.saveBundleFolder(
        bundleId: bundleId,
        bundleName: 'B1-renamed',
        selectedChildIds: {f2, f3},
        oldChildIds: {f1, f2},
      );
      expect(resultId, bundleId);

      final bundleRow = (await db.query('folders', where: 'id = ?', whereArgs: [bundleId])).single;
      expect(bundleRow['name'], 'B1-renamed');
      expect(bundleRow['folder_count'], 2);

      final f1Row = (await db.query('folders', where: 'id = ?', whereArgs: [f1])).single;
      expect(f1Row['parent_folder_id'], isNull);
      final f2Row = (await db.query('folders', where: 'id = ?', whereArgs: [f2])).single;
      expect(f2Row['parent_folder_id'], bundleId);
      final f3Row = (await db.query('folders', where: 'id = ?', whereArgs: [f3])).single;
      expect(f3Row['parent_folder_id'], bundleId);
    });
  });

  group('#9 updateFolderCardCount / resyncFolderCardCounts', () {
    late Directory docs;
    setUp(() async => docs = await initDbTestEnv());
    tearDown(() async => tearDownDbTestEnv(docs));

    test('updateFolderCardCount: 단일 폴더를 실제 COUNT로 정확히 갱신', () async {
      final db = await DatabaseHelper.instance.database;
      final folderId = await db.insert('folders', fixtureFolder(name: 'A').toDb());
      await db.update('folders', {'card_count': 999}, where: 'id = ?', whereArgs: [folderId]);
      await db.insert('cards', fixtureCard(folderId: folderId, uuid: 'c1').toDb());
      await db.insert('cards', fixtureCard(folderId: folderId, uuid: 'c2').toDb());

      await DatabaseHelper.instance.updateFolderCardCount(folderId);
      final row = (await db.query('folders', where: 'id = ?', whereArgs: [folderId])).single;
      expect(row['card_count'], 2);
    });

    test('resyncFolderCardCounts: 어긋난 행 수만 반환, is_bundle 제외, 맞는 행은 안 건드림',
        () async {
      final db = await DatabaseHelper.instance.database;
      final staleId = await db.insert('folders', fixtureFolder(name: 'stale').toDb());
      await db.update('folders', {'card_count': 999}, where: 'id = ?', whereArgs: [staleId]);
      await db.insert('cards', fixtureCard(folderId: staleId, uuid: 'c1').toDb());

      final correctId = await db.insert('folders', fixtureFolder(name: 'correct').toDb());
      await db.insert('cards', fixtureCard(folderId: correctId, uuid: 'c2').toDb());
      await DatabaseHelper.instance.updateFolderCardCount(correctId);

      final bundleId =
          await db.insert('folders', fixtureFolder(name: 'bundle', isBundle: true).toDb());
      await db.update('folders', {'card_count': 999}, where: 'id = ?', whereArgs: [bundleId]);

      final changed = await DatabaseHelper.instance.resyncFolderCardCounts();
      expect(changed, 1);

      final staleRow = (await db.query('folders', where: 'id = ?', whereArgs: [staleId])).single;
      expect(staleRow['card_count'], 1);
      final correctRow =
          (await db.query('folders', where: 'id = ?', whereArgs: [correctId])).single;
      expect(correctRow['card_count'], 1);
      final bundleRow = (await db.query('folders', where: 'id = ?', whereArgs: [bundleId])).single;
      expect(bundleRow['card_count'], 999, reason: 'is_bundle=1은 건드리면 안 된다');
    });
  });

  group('#10 이름순 정렬 일치 — getAllCardIds/getCardIdsByFolderIdSorted vs compareNamesForSort',
      () {
    late Directory docs;
    setUp(() async => docs = await initDbTestEnv());
    tearDown(() async => tearDownDbTestEnv(docs));

    test('SQL 정렬과 Dart 비교자가 정확히 같은 순서를 낸다', () async {
      final db = await DatabaseHelper.instance.database;
      final folderId = await db.insert('folders', fixtureFolder(name: 'F').toDb());
      const qs = [
        'apple', 'Apple', 'APPLE', '바나나', '가', '😀zz', '�zz', 'Ｚz', 'é', 'E',
      ];
      final idToQ = <int, String>{};
      for (var i = 0; i < qs.length; i++) {
        final id = await db.insert(
            'cards', fixtureCard(folderId: folderId, uuid: 'u$i', question: qs[i]).toDb());
        idToQ[id] = qs[i];
      }
      final expectedOrder = List<String>.of(qs)..sort(compareNamesForSort);

      final allIds = await DatabaseHelper.instance.getAllCardIds(sortBy: 'name_asc');
      final allOrder = allIds.map((id) => idToQ[id]).whereType<String>().toList();
      expect(allOrder, expectedOrder);

      final folderSortedIds =
          await DatabaseHelper.instance.getCardIdsByFolderIdSorted(folderId, 'name_asc');
      final folderOrder = folderSortedIds.map((id) => idToQ[id]).whereType<String>().toList();
      expect(folderOrder, expectedOrder);
    });
  });

  group('#11 duplicateCard + _duplicateFiles — 현재 동작 고정', () {
    late Directory docs;
    setUp(() async => docs = await initDbTestEnv());
    tearDown(() async => tearDownDbTestEnv(docs));

    test('실제 파일은 새 copy_* 파일로, 없는 경로는 그대로, 빈 경로는 그대로', () async {
      final db = await DatabaseHelper.instance.database;
      final folderId = await db.insert('folders', fixtureFolder(name: 'F').toDb());

      final realFile = File(p.join(docs.path, 'real.jpg'));
      await realFile.writeAsBytes([1, 2, 3, 4]);
      final missingPath = p.join(docs.path, 'missing.jpg');

      final origId = await db.insert(
          'cards',
          fixtureCard(
            folderId: folderId,
            uuid: 'orig-uuid',
            sequence: 5,
            overrides: {
              'question_image_path': realFile.path,
              'answer_image_path': missingPath,
              'answer_image_path_2': '',
            },
          ).toDb());

      final newId = await DatabaseHelper.instance.duplicateCard(origId);
      expect(newId, greaterThan(0));

      final row = (await db.query('cards', where: 'id = ?', whereArgs: [newId])).single;
      expect((row['uuid'] as String).startsWith('orig-uuid-copy-'), isTrue);
      expect(row['sequence'], 6);

      final newQPath = row['question_image_path'] as String;
      expect(newQPath, isNot(realFile.path));
      expect(p.basename(newQPath), startsWith('copy_'));
      expect(await File(newQPath).exists(), isTrue);
      expect(await File(newQPath).readAsBytes(), await realFile.readAsBytes());

      expect(row['answer_image_path'], missingPath);
      expect(row['answer_image_path_2'], '');

      final folderRow = (await db.query('folders', where: 'id = ?', whereArgs: [folderId])).single;
      expect(folderRow['card_count'], 2);

      expect(await DatabaseHelper.instance.duplicateCard(999999), -1);
    });
  });

  group('#12 cleanupBrokenImagePaths', () {
    late Directory docs;
    setUp(() async => docs = await initDbTestEnv());
    tearDown(() async => tearDownDbTestEnv(docs));

    test('자가치유(같은 basename) / 완전소실→빈문자열 / 정상은 그대로 / import 중엔 무변경',
        () async {
      final db = await DatabaseHelper.instance.database;
      final folderId = await db.insert('folders', fixtureFolder(name: 'F').toDb());

      final imagesDir = Directory(p.join(docs.path, AppConstants.imageDir));
      await imagesDir.create(recursive: true);
      final healedTarget = File(p.join(imagesDir.path, 'a.jpg'));
      await healedTarget.writeAsBytes([9]);

      final cardAId = await db.insert(
          'cards',
          fixtureCard(
            folderId: folderId,
            uuid: 'a',
            overrides: {
              'question_image_path': p.join(docs.path, 'old_location', 'a.jpg'),
            },
          ).toDb());
      final cardBId = await db.insert(
          'cards',
          fixtureCard(
            folderId: folderId,
            uuid: 'b',
            overrides: {'question_image_path': p.join(docs.path, 'gone.jpg')},
          ).toDb());
      final validFile = File(p.join(docs.path, 'valid.jpg'));
      await validFile.writeAsBytes([1]);
      final cardCId = await db.insert(
          'cards',
          fixtureCard(
            folderId: folderId,
            uuid: 'c',
            overrides: {'question_image_path': validFile.path},
          ).toDb());

      // 컬럼 목록의 마지막 항목(answer_voice_record_path_10)도 자가치유되는지 —
      // 목록이 잘리면(예: 앞쪽 컬럼만 남기는 회귀) 이 카드만 안 고쳐지고 조용히 넘어간다.
      final healedTargetE = File(p.join(imagesDir.path, 'e.jpg'));
      await healedTargetE.writeAsBytes([9]);
      final cardEId = await db.insert(
          'cards',
          fixtureCard(
            folderId: folderId,
            uuid: 'e',
            overrides: {
              'answer_voice_record_path_10':
                  p.join(docs.path, 'old_location', 'e.jpg'),
            },
          ).toDb());

      final cleaned = await DatabaseHelper.instance.cleanupBrokenImagePaths();
      expect(cleaned, 3);

      final rowA = (await db.query('cards', where: 'id = ?', whereArgs: [cardAId])).single;
      expect(rowA['question_image_path'], p.join(imagesDir.path, 'a.jpg'));
      final rowB = (await db.query('cards', where: 'id = ?', whereArgs: [cardBId])).single;
      expect(rowB['question_image_path'], '');
      final rowC = (await db.query('cards', where: 'id = ?', whereArgs: [cardCId])).single;
      expect(rowC['question_image_path'], validFile.path);
      final rowE = (await db.query('cards', where: 'id = ?', whereArgs: [cardEId])).single;
      expect(rowE['answer_voice_record_path_10'], p.join(imagesDir.path, 'e.jpg'));

      // import 진행 중 마커 — 이후 새로 생긴 깨진 경로는 건드리지 않는다.
      await db.insert('settings', {'key': 'import_in_progress', 'value': '1'});
      final cardDId = await db.insert(
          'cards',
          fixtureCard(
            folderId: folderId,
            uuid: 'd',
            overrides: {'question_image_path': p.join(docs.path, 'also_gone.jpg')},
          ).toDb());
      final cleaned2 = await DatabaseHelper.instance.cleanupBrokenImagePaths();
      expect(cleaned2, 0);
      final rowD = (await db.query('cards', where: 'id = ?', whereArgs: [cardDId])).single;
      expect(rowD['question_image_path'], p.join(docs.path, 'also_gone.jpg'));
    });
  });

  group('#13 cleanupOrphanMediaFiles', () {
    late Directory docs;
    setUp(() async => docs = await initDbTestEnv());
    tearDown(() async => tearDownDbTestEnv(docs));

    test('오래된 미참조 파일만 삭제, 신선한 파일/닷파일/참조된 파일은 보존', () async {
      final db = await DatabaseHelper.instance.database;
      final folderId = await db.insert('folders', fixtureFolder(name: 'F').toDb());
      final imagesDir = Directory(p.join(docs.path, AppConstants.imageDir));
      await imagesDir.create(recursive: true);

      final referencedFile = File(p.join(imagesDir.path, 'ref.jpg'));
      await referencedFile.writeAsBytes([1]);
      await db.insert(
          'cards',
          fixtureCard(
            folderId: folderId,
            uuid: 'ref-card',
            overrides: {'question_image_path': referencedFile.path},
          ).toDb());

      final oldOrphan = File(p.join(imagesDir.path, 'old_orphan.jpg'));
      await oldOrphan.writeAsBytes([2]);
      await oldOrphan.setLastModified(DateTime.now().subtract(const Duration(minutes: 20)));

      final freshOrphan = File(p.join(imagesDir.path, 'fresh_orphan.jpg'));
      await freshOrphan.writeAsBytes([3]);

      final dotfile = File(p.join(imagesDir.path, '.nomedia'));
      await dotfile.writeAsBytes(const []);

      final deleted = await DatabaseHelper.instance.cleanupOrphanMediaFiles();
      expect(deleted, 1);
      expect(await oldOrphan.exists(), isFalse);
      expect(await freshOrphan.exists(), isTrue);
      expect(await dotfile.exists(), isTrue);
      expect(await referencedFile.exists(), isTrue);
    });

    test('참조 0건 + 후보 20개 이상 — 안전장치로 이번 실행은 아무 것도 안 지운다', () async {
      final imagesDir = Directory(p.join(docs.path, AppConstants.imageDir));
      await imagesDir.create(recursive: true);
      for (var i = 0; i < 25; i++) {
        final f = File(p.join(imagesDir.path, 'orphan_$i.jpg'));
        await f.writeAsBytes([i]);
        await f.setLastModified(DateTime.now().subtract(const Duration(minutes: 20)));
      }

      final deleted = await DatabaseHelper.instance.cleanupOrphanMediaFiles();
      expect(deleted, 0);
      for (var i = 0; i < 25; i++) {
        expect(await File(p.join(imagesDir.path, 'orphan_$i.jpg')).exists(), isTrue);
      }
    });

    test('import 진행 중이면 아무 것도 지우지 않는다', () async {
      final db = await DatabaseHelper.instance.database;
      final folderId = await db.insert('folders', fixtureFolder(name: 'F').toDb());
      await db.insert('cards', fixtureCard(folderId: folderId, uuid: 'c1').toDb());
      await db.insert('settings', {'key': 'import_in_progress', 'value': '1'});

      final imagesDir = Directory(p.join(docs.path, AppConstants.imageDir));
      await imagesDir.create(recursive: true);
      final orphan = File(p.join(imagesDir.path, 'orphan.jpg'));
      await orphan.writeAsBytes([1]);
      await orphan.setLastModified(DateTime.now().subtract(const Duration(minutes: 20)));

      final deleted = await DatabaseHelper.instance.cleanupOrphanMediaFiles();
      expect(deleted, 0);
      expect(await orphan.exists(), isTrue);
    });
  });

  group('#14 exported_files CRUD', () {
    late Directory docs;
    setUp(() async => docs = await initDbTestEnv());
    tearDown(() async => tearDownDbTestEnv(docs));

    test('생성순(DESC) 정렬, 이름 변경, 개별/경로/배치 삭제', () async {
      final id1 = await DatabaseHelper.instance
          .insertExportedFile(fileName: 'a.mra', filePath: '/x/a.mra');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final id2 = await DatabaseHelper.instance
          .insertExportedFile(fileName: 'b.mra', filePath: '/x/b.mra');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final id3 = await DatabaseHelper.instance
          .insertExportedFile(fileName: 'c.mra', filePath: '/x/c.mra');

      final all = await DatabaseHelper.instance.getAllExportedFiles();
      expect(all.map((r) => r['id']).toList(), [id3, id2, id1]);

      await DatabaseHelper.instance.renameExportedFile(id1, 'a2.mra', '/x/a2.mra');
      final renamed = (await DatabaseHelper.instance.getAllExportedFiles())
          .firstWhere((r) => r['id'] == id1);
      expect(renamed['file_name'], 'a2.mra');
      expect(renamed['file_path'], '/x/a2.mra');

      expect(await DatabaseHelper.instance.deleteExportedFile(id2), 1);
      expect(await DatabaseHelper.instance.deleteExportedFileByPath('/x/c.mra'), 1);
      expect(await DatabaseHelper.instance.deleteExportedFileByPath('/nope.mra'), 0);

      final remaining = await DatabaseHelper.instance.getAllExportedFiles();
      expect(remaining, hasLength(1));
      expect(remaining.single['id'], id1);

      final batchIds = <int>[];
      for (var i = 0; i < 900; i++) {
        batchIds.add(await DatabaseHelper.instance
            .insertExportedFile(fileName: 'f$i', filePath: '/f$i'));
      }
      expect(await DatabaseHelper.instance.deleteExportedFilesBatch(batchIds), 900);
      expect(await DatabaseHelper.instance.getAllExportedFiles(), hasLength(1));
    });
  });

  group('#15 getMaxSequence / getMaxFolderSequence / getCounter', () {
    late Directory docs;
    setUp(() async => docs = await initDbTestEnv());
    tearDown(() async => tearDownDbTestEnv(docs));

    test('빈 상태는 0, getCounter는 자동 시딩되고 멱등이다', () async {
      final db = await DatabaseHelper.instance.database;

      expect(await DatabaseHelper.instance.getMaxFolderSequence(), 0);

      final folderId = await db.insert('folders', fixtureFolder(name: 'F').toDb());
      expect(await DatabaseHelper.instance.getMaxSequence(folderId), 0);

      await db.insert('cards', fixtureCard(folderId: folderId, uuid: 'c1', sequence: 7).toDb());
      expect(await DatabaseHelper.instance.getMaxSequence(folderId), 7);

      await db.insert('folders', fixtureFolder(name: 'F2', sequence: 12).toDb());
      expect(await DatabaseHelper.instance.getMaxFolderSequence(), 12);

      await db.delete('counters');
      final counter1 = await DatabaseHelper.instance.getCounter();
      expect(counter1, isNotNull);
      expect(counter1!['id'], 1);
      expect(counter1['card_sequence'], 0);

      final counter2 = await DatabaseHelper.instance.getCounter();
      expect(counter2!['id'], 1);
      expect(await db.query('counters'), hasLength(1));
    });
  });

  group('#16 referencedMediaPaths — ≤100(패딩청크) / >100(키셋페이징)', () {
    late Directory docs;
    setUp(() async => docs = await initDbTestEnv());
    tearDown(() async => tearDownDbTestEnv(docs));

    test('두 분기 모두 참조된 경로만 정확히 반환하고, 공유 경로도 잡는다', () async {
      final db = await DatabaseHelper.instance.database;
      final folderId = await db.insert('folders', fixtureFolder(name: 'F').toDb());

      final smallPaths = List<String>.generate(30, (i) => 'small_$i.jpg');
      for (var i = 0; i < smallPaths.length; i++) {
        await db.insert(
            'cards',
            fixtureCard(
              folderId: folderId,
              uuid: 'small-$i',
              overrides: {'question_image_path': smallPaths[i]},
            ).toDb());
      }
      await db.insert(
          'cards',
          fixtureCard(
            folderId: folderId,
            uuid: 'small-shared-2',
            overrides: {'answer_image_path': smallPaths[0]},
          ).toDb());
      const unreferencedSmall = 'not_referenced_small.jpg';

      final smallResult = await DatabaseHelper.instance
          .referencedMediaPaths([...smallPaths, unreferencedSmall]);
      expect(smallResult, smallPaths.toSet());
      expect(smallResult.contains(unreferencedSmall), isFalse);

      final bigPaths = List<String>.generate(150, (i) => 'big_$i.jpg');
      for (var i = 0; i < bigPaths.length; i++) {
        await db.insert(
            'cards',
            fixtureCard(
              folderId: folderId,
              uuid: 'big-$i',
              overrides: {'question_image_path': bigPaths[i]},
            ).toDb());
      }
      await db.insert(
          'cards',
          fixtureCard(
            folderId: folderId,
            uuid: 'big-shared-2',
            overrides: {'answer_image_path': bigPaths[0]},
          ).toDb());
      const unreferencedBig = 'not_referenced_big.jpg';

      final bigResult = await DatabaseHelper.instance
          .referencedMediaPaths([...bigPaths, unreferencedBig]);
      expect(bigResult, bigPaths.toSet());
      expect(bigResult.contains(unreferencedBig), isFalse);
    });
  });
}
