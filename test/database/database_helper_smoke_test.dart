// sqlite3.dll 로딩 게이트 + 스키마 골격 확인용 스모크 테스트. 이 파일 하나만 따로
// 돌려서 sqflite_common_ffi가 실제로 DB를 열 수 있는지부터 확인한다(Step 0).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

import 'package:memora/database/database_helper.dart';

import '../helpers/db_test_harness.dart';

void main() {
  late Directory docs;

  setUp(() async {
    docs = await initDbTestEnv();
  });

  tearDown(() async {
    await tearDownDbTestEnv(docs);
  });

  test('DatabaseHelper.instance.database가 v4 스키마로 새로 열린다', () async {
    final db = await DatabaseHelper.instance.database;

    final versionRow = await db.rawQuery('PRAGMA user_version');
    expect(Sqflite.firstIntValue(versionRow), 4);

    final fkRow = await db.rawQuery('PRAGMA foreign_keys');
    expect(Sqflite.firstIntValue(fkRow), 1);

    final counters = await db.query('counters');
    expect(counters, hasLength(1));
    expect(counters.first['id'], 1);
  });
}
