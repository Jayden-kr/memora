import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';

import '../database/database_helper.dart';
import '../utils/constants.dart';

/// Export 진행 상태
class ExportProgress {
  final int current;
  final int total;
  final String phase; // 'folders', 'cards', 'images', 'zipping', 'done'
  final String? message;

  const ExportProgress({
    this.current = 0,
    this.total = 0,
    this.phase = 'folders',
    this.message,
  });
}

class MemkExportService {
  /// 로컬 경로를 암기짱 호환 경로로 변환
  static String toMemkImagePath(String localPath) {
    if (localPath.isEmpty) return '';
    final fileName = localPath.split('/').last.split('\\').last;
    return '${AppConstants.amkizzangImagePrefix}$fileName';
  }

  /// DB 데이터를 .memk ZIP 파일로 export
  Future<void> exportMemk({
    required String outputPath,
    required void Function(ExportProgress) onProgress,
  }) async {
    final db = DatabaseHelper.instance;
    final appDocDir = (await getApplicationDocumentsDirectory()).path;

    onProgress(const ExportProgress(phase: 'folders', message: '폴더 정보 준비 중...'));

    // 폴더 조회 + JSON
    final folders = await db.getAllFolders();
    final folderNameMap = <int, String>{}; // folderId → name
    final foldersJsonList = <Map<String, dynamic>>[];
    for (final folder in folders) {
      folderNameMap[folder.id!] = folder.name;
      foldersJsonList.add(folder.toJson());
    }
    final foldersJsonStr = jsonEncode(foldersJsonList);

    onProgress(const ExportProgress(phase: 'cards', message: '카드 정보 준비 중...'));

    // 카드 조회 + JSON + 이미지 파일명 수집
    final totalCards = await db.getTotalCardCount();
    final cardsJsonList = <Map<String, dynamic>>[];
    final imageFileNames = <String>{}; // ZIP에 포함할 이미지 파일명
    int processed = 0;

    // 페이지네이션으로 메모리 절약
    const batchSize = 500;
    int offset = 0;
    while (true) {
      final cards = await db.getAllCards(limit: batchSize, offset: offset);
      if (cards.isEmpty) break;

      for (final card in cards) {
        final json = card.toJson();

        // folderName 복원
        json['folderName'] = folderNameMap[card.folderId] ?? '';

        // 이미지 경로 변환: 로컬 → 암기짱 포맷
        _convertToMemkPaths(json, imageFileNames);

        cardsJsonList.add(json);
        processed++;
      }

      onProgress(ExportProgress(
        phase: 'cards',
        current: processed,
        total: totalCards,
        message: '카드 정보 준비 중... $processed / $totalCards',
      ));

      offset += batchSize;
      await Future.delayed(Duration.zero);
    }
    final cardsJsonStr = jsonEncode(cardsJsonList);

    // counter.json
    final counter = await db.getCounter();
    final counterJsonStr = jsonEncode(counter != null ? [counter] : []);

    // prefs.json
    final settings = await db.getAllSettings();
    final prefsJsonStr = jsonEncode(settings);

    onProgress(ExportProgress(
      phase: 'zipping',
      message: 'ZIP 파일 생성 중... (이미지 ${imageFileNames.length}개)',
    ));

    // ZIP 아카이브 생성
    final archive = Archive();

    // JSON 파일 추가
    archive.addFile(_createArchiveFile(
      AppConstants.memkFoldersJson,
      utf8.encode(foldersJsonStr),
    ));
    archive.addFile(_createArchiveFile(
      AppConstants.memkCardsJson,
      utf8.encode(cardsJsonStr),
    ));
    archive.addFile(_createArchiveFile(
      AppConstants.memkCounterJson,
      utf8.encode(counterJsonStr),
    ));
    archive.addFile(_createArchiveFile(
      AppConstants.memkPrefsJson,
      utf8.encode(prefsJsonStr),
    ));

    // 이미지 파일 추가
    final imageDir = '$appDocDir/${AppConstants.imageDir}';
    int imageCount = 0;
    for (final fileName in imageFileNames) {
      final file = File('$imageDir/$fileName');
      if (file.existsSync()) {
        final data = await file.readAsBytes();
        archive.addFile(_createArchiveFile(fileName, data));
        imageCount++;

        if (imageCount % 100 == 0) {
          onProgress(ExportProgress(
            phase: 'images',
            current: imageCount,
            total: imageFileNames.length,
            message: '이미지 추가 중... $imageCount / ${imageFileNames.length}',
          ));
          await Future.delayed(Duration.zero);
        }
      }
    }

    // ZIP 인코딩 + 저장
    final zipBytes = ZipEncoder().encode(archive);
    await File(outputPath).writeAsBytes(zipBytes);

    onProgress(const ExportProgress(phase: 'done', message: 'Export 완료'));
  }

  /// JSON 맵의 로컬 이미지 경로를 암기짱 호환 경로로 변환
  void _convertToMemkPaths(
    Map<String, dynamic> cardJson,
    Set<String> imageFileNames,
  ) {
    for (final key in cardJson.keys.toList()) {
      if (!key.contains('Path')) continue;
      final value = cardJson[key];
      if (value is! String || value.isEmpty) continue;

      // 파일명 추출 (로컬 경로에서)
      final fileName = value.split('/').last.split('\\').last;
      if (fileName.isEmpty) continue;

      imageFileNames.add(fileName);
      cardJson[key] = '${AppConstants.amkizzangImagePrefix}$fileName';
    }
  }

  ArchiveFile _createArchiveFile(String name, List<int> data) {
    return ArchiveFile(name, data.length, data);
  }
}
