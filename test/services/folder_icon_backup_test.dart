// 폴더 아이콘/색이 .mra 백업을 한 바퀴 돌아도(내보내기 → 가져오기) 살아남는지, 그리고
// 병합 가져오기는 이 기기에서 사용자가 고른 아이콘을 덮어쓰지 않는지 실제 서비스로 확인한다.
// sqflite_common_ffi 하네스 + plain test()만 쓴다 — testWidgets에서 실제 sqlite를 만지면
// 교착하므로 위젯 테스트로 바꾸지 말 것.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:memora/database/database_helper.dart';
import 'package:memora/models/folder.dart';
import 'package:memora/services/memk_export_service.dart';
import 'package:memora/services/memk_import_service.dart';

import '../helpers/db_test_harness.dart';

void main() {
  late Directory docs;
  setUp(() async => docs = await initDbTestEnv());
  tearDown(() async => tearDownDbTestEnv(docs));

  /// 폴더 하나 + 카드 한 장을 만들고 그 폴더만 `<docs>/a.mra`로 내보낸다.
  /// 아이콘/색은 기본이 star/파랑, 글자 아이콘('t:…') 왕복을 볼 때는 값을 넘긴다.
  Future<({int folderId, String path})> seedAndExport(
      {String icon = 'star', int iconColor = 0xFF2196F3}) async {
    final db = await DatabaseHelper.instance.database;
    final aId = await db.insert(
        'folders',
        Folder(name: 'A', sequence: 0, icon: icon, iconColor: iconColor)
            .toDb());
    await db.insert(
        'cards',
        fixtureCard(folderId: aId, uuid: 'icon-card-1', question: 'q1', sequence: 1)
            .toDb());
    await DatabaseHelper.instance.updateFolderCardCount(aId);

    final path = p.join(docs.path, 'a.mra');
    await MemkExportService().exportMemk(
      outputPath: path,
      onProgress: (_) {},
      folderIds: [aId],
    );
    expect(File(path).existsSync(), isTrue, reason: '전제: 내보내기 파일이 만들어져야 한다');
    return (folderId: aId, path: path);
  }

  test('(1) 내보내기 → 새 이름으로 가져오기: 복사본 폴더가 같은 아이콘·색을 갖는다', () async {
    final seeded = await seedAndExport();

    final result = await MemkImportService().importSelectedFolders(
      filePath: seeded.path,
      selectedFolderNames: ['A'],
      onProgress: (_) {},
      conflictPolicy: 'rename',
    );
    expect(result.newFolders, 1, reason: '전제: 새 폴더가 실제로 만들어져야 한다');
    expect(result.mergedFolders, 0);

    final copy = await DatabaseHelper.instance.getFolderByName('A_1');
    expect(copy, isNotNull);
    expect(copy!.icon, 'star');
    expect(copy.iconColor, 0xFF2196F3);

    // 원본은 그대로.
    final original = await DatabaseHelper.instance.getFolderById(seeded.folderId);
    expect(original!.icon, 'star');
    expect(original.iconColor, 0xFF2196F3);
  });

  test('(2) 병합 가져오기: 이 기기에서 바꾼 아이콘을 아카이브가 덮어쓰지 않는다', () async {
    final seeded = await seedAndExport();

    // 내보낸 뒤 사용자가 이 기기에서 아이콘을 바꿨다.
    await DatabaseHelper.instance.updateFolderIcon(seeded.folderId,
        icon: 'favorite', iconColor: 0xFFFF0000);
    final foldersBefore = await DatabaseHelper.instance.getAllFolders();

    final result = await MemkImportService().importSelectedFolders(
      filePath: seeded.path,
      selectedFolderNames: ['A'],
      onProgress: (_) {},
      conflictPolicy: 'merge',
    );
    expect(result.mergedFolders, 1, reason: '전제: 병합 분기를 실제로 타야 한다');
    expect(result.newFolders, 0);

    final foldersAfter = await DatabaseHelper.instance.getAllFolders();
    expect(foldersAfter, hasLength(foldersBefore.length));

    final merged = await DatabaseHelper.instance.getFolderById(seeded.folderId);
    expect(merged!.icon, 'favorite');
    expect(merged.iconColor, 0xFFFF0000);
  });

  test('(3) folderMapping 병합: 매핑 대상 폴더의 아이콘을 아카이브가 덮어쓰지 않는다', () async {
    final seeded = await seedAndExport();

    // 아카이브 쪽 폴더 id — 매핑 키는 로컬 id가 아니라 folders.json의 id다.
    final archiveFolders = await MemkImportService()
        .readFolderList(seeded.path, cacheArchive: false);
    final archiveId =
        (archiveFolders.singleWhere((f) => f['name'] == 'A')['id'] as num).toInt();

    await DatabaseHelper.instance.updateFolderIcon(seeded.folderId,
        icon: 'favorite', iconColor: 0xFFFF0000);
    final foldersBefore = await DatabaseHelper.instance.getAllFolders();

    // conflictPolicy를 'rename'으로 둔 이유: 정책이 mergeTarget 분기(이름이 같으니 병합)를
    // 켜면 folderMapping 분기가 깨져도 이 테스트가 통과한다. 'rename'에선 mergeTarget이
    // 꺼지므로 병합은 오직 folderMapping 분기로만 일어난다(깨지면 A_1이 새로 생겨 실패).
    final result = await MemkImportService().importSelectedFolders(
      filePath: seeded.path,
      selectedFolderNames: ['A'],
      onProgress: (_) {},
      folderMapping: {archiveId: seeded.folderId},
      conflictPolicy: 'rename',
    );
    expect(result.mergedFolders, 1, reason: '전제: folderMapping 분기를 실제로 타야 한다');
    expect(result.newFolders, 0);

    final foldersAfter = await DatabaseHelper.instance.getAllFolders();
    expect(foldersAfter, hasLength(foldersBefore.length));
    expect(await DatabaseHelper.instance.getFolderByName('A_1'), isNull);

    final mapped = await DatabaseHelper.instance.getFolderById(seeded.folderId);
    expect(mapped!.icon, 'favorite');
    expect(mapped.iconColor, 0xFFFF0000);
  });

  test('(4) UNIQUE 재시도 병합: 폴더 insert가 경합으로 실패해 기존 폴더에 붙어도 그 폴더의 아이콘을 덮어쓰지 않는다',
      () async {
    final seeded = await seedAndExport();

    // 이 기기에서 A를 지운다 → 가져올 때 'A'는 존재하지 않는 이름이라 mergeTarget이 null이고
    // 새 폴더 insert로 간다.
    final db = await DatabaseHelper.instance.database;
    await db.delete('cards');
    await db.delete('folders');
    expect(await DatabaseHelper.instance.getFolderByName('A'), isNull);

    // UNIQUE 재시도 분기는 "getFolderByName은 없다고 했는데 insert 직전에 누가 같은 이름을
    // 먼저 만든" 경합에서만 탄다(동시 import). 실제 경합은 타이밍에 기대야 해서 결정적이지
    // 않으므로 DB 트리거로 같은 일을 만든다: 'A' insert가 들어오면 트리거가 이 기기의
    // 'A'(favorite/빨강)를 먼저 만들어 커밋시키고 RAISE(FAIL)로 그 insert만 실패시킨다
    // (FAIL은 앞서 한 변경을 되돌리지 않는다). 그러면 서비스의 catch → retry 분기가 실제
    // 코드 그대로 실행된다.
    await db.execute('''
      CREATE TRIGGER race_a BEFORE INSERT ON folders
      WHEN NEW.name = 'A'
      BEGIN
        INSERT INTO folders(name, sequence, icon, icon_color)
          VALUES ('A', 0, 'favorite', ${0xFFFF0000});
        SELECT RAISE(FAIL, 'simulated concurrent insert');
      END
    ''');

    final result = await MemkImportService().importSelectedFolders(
      filePath: seeded.path,
      selectedFolderNames: ['A'],
      onProgress: (_) {},
      conflictPolicy: 'merge',
    );
    expect(result.newFolders, 0,
        reason: '전제: 우리 insert는 실패해야 한다(트리거가 안 걸렸으면 새 폴더가 생긴다)');
    expect(result.mergedFolders, 1, reason: '전제: UNIQUE 재시도 병합 분기를 실제로 타야 한다');

    final folders = await DatabaseHelper.instance.getAllFolders();
    expect(folders, hasLength(1));
    expect(folders.single.name, 'A');
    expect(folders.single.icon, 'favorite');
    expect(folders.single.iconColor, 0xFFFF0000);
  });

  test('(5) 글자 아이콘(국기 이모지 "t:…")도 내보내기 → 새 이름으로 가져오기에서 같은 글자·색으로 살아남는다', () async {
    // 글자는 \u 이스케이프로 적는다(이스라엘 국기 = 지역 표시 문자 2개).
    const flag = 't:\u{1F1EE}\u{1F1F1}';
    final seeded = await seedAndExport(icon: flag, iconColor: 0xFFFF0000);

    final result = await MemkImportService().importSelectedFolders(
      filePath: seeded.path,
      selectedFolderNames: ['A'],
      onProgress: (_) {},
      conflictPolicy: 'rename',
    );
    expect(result.newFolders, 1, reason: '전제: 새 폴더가 실제로 만들어져야 한다');
    expect(result.mergedFolders, 0);

    final copy = await DatabaseHelper.instance.getFolderByName('A_1');
    expect(copy, isNotNull);
    expect(copy!.icon, flag);
    expect(Folder.iconTextOf(copy.icon), '\u{1F1EE}\u{1F1F1}');
    expect(copy.iconColor, 0xFFFF0000);

    // 원본은 그대로.
    final original = await DatabaseHelper.instance.getFolderById(seeded.folderId);
    expect(original!.icon, flag);
    expect(original.iconColor, 0xFFFF0000);
  });
}
