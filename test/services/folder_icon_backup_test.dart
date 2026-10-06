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
  Future<({int folderId, String path})> seedAndExport() async {
    final db = await DatabaseHelper.instance.database;
    final aId = await db.insert(
        'folders',
        Folder(name: 'A', sequence: 0, icon: 'star', iconColor: 0xFF2196F3)
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
}
