import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path_provider/path_provider.dart';

import '../database/database_helper.dart';
import '../models/folder.dart';
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
  /// [folderIds]: null이면 전체, 있으면 해당 폴더만
  Future<void> exportMemk({
    required String outputPath,
    required void Function(ExportProgress) onProgress,
    List<int>? folderIds,
  }) async {
    final db = DatabaseHelper.instance;
    final appDocDir = (await getApplicationDocumentsDirectory()).path;

    onProgress(const ExportProgress(phase: 'folders', message: '폴더 정보 준비 중...'));

    // 폴더 조회 + JSON
    List<Folder> folders;
    if (folderIds != null) {
      final allFolders = await db.getAllFolders();
      final idSet = folderIds.toSet();
      folders = allFolders.where((f) => idSet.contains(f.id)).toList();
    } else {
      folders = await db.getAllFolders();
    }
    final folderNameMap = <int, String>{}; // folderId → name
    final foldersJsonList = <Map<String, dynamic>>[];
    for (final folder in folders) {
      if (folder.id == null) continue;
      folderNameMap[folder.id!] = folder.name;
      foldersJsonList.add(folder.toJson());
    }
    final foldersJsonStr = jsonEncode(foldersJsonList);

    onProgress(const ExportProgress(phase: 'cards', message: '카드 정보 준비 중...'));

    // 카드 조회 + JSON + 이미지 파일명 수집
    final cardsJsonList = <Map<String, dynamic>>[];
    final imageFileNames = <String>{}; // ZIP에 포함할 이미지 파일명
    int processed = 0;

    if (folderIds != null) {
      // 선택된 폴더의 카드만 (단일 쿼리로 총 수 조회)
      int totalCards = await db.countCardsByFolderIds(folderIds);
      for (final folderId in folderIds) {
        final folderName = folderNameMap[folderId] ?? '';
        const batchSize = 500;
        int offset = 0;
        while (true) {
          final cards = await db.getCardsByFolderId(folderId,
              limit: batchSize, offset: offset);
          if (cards.isEmpty) break;
          for (final card in cards) {
            final json = card.toJson();
            json['folderName'] = folderName;
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
        // 소량 카드 폴더에서도 진행률 갱신 보장
        if (processed > 0) {
          onProgress(ExportProgress(
            phase: 'cards',
            current: processed,
            total: totalCards,
            message: '"$folderName" 완료 ($processed / $totalCards)',
          ));
        }
      }
    } else {
      // 전체 카드
      final totalCards = await db.getTotalCardCount();
      const batchSize = 500;
      int offset = 0;
      while (true) {
        final cards = await db.getAllCards(limit: batchSize, offset: offset);
        if (cards.isEmpty) break;
        for (final card in cards) {
          final json = card.toJson();
          json['folderName'] = folderNameMap[card.folderId] ?? '';
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

    // 스트리밍 ZIP 생성 — ZipFileEncoder는 파일을 디스크에서 직접 스트리밍하므로
    // 모든 이미지를 메모리에 올리지 않아 OOM 방지
    final zipEncoder = ZipFileEncoder();
    zipEncoder.create(outputPath);

    // JSON 파일 추가 (소량 데이터 — in-memory OK)
    zipEncoder.addArchiveFile(_createArchiveFile(
      AppConstants.memkFoldersJson,
      utf8.encode(foldersJsonStr),
    ));
    zipEncoder.addArchiveFile(_createArchiveFile(
      AppConstants.memkCardsJson,
      utf8.encode(cardsJsonStr),
    ));
    zipEncoder.addArchiveFile(_createArchiveFile(
      AppConstants.memkCounterJson,
      utf8.encode(counterJsonStr),
    ));
    zipEncoder.addArchiveFile(_createArchiveFile(
      AppConstants.memkPrefsJson,
      utf8.encode(prefsJsonStr),
    ));

    // 이미지 파일 추가 — 디스크에서 스트리밍 (한 번에 한 파일만 메모리 사용)
    final imageDir = '$appDocDir/${AppConstants.imageDir}';
    int imageCount = 0;
    for (final fileName in imageFileNames) {
      final file = File('$imageDir/$fileName');
      if (file.existsSync()) {
        await zipEncoder.addFile(file, fileName);
        imageCount++;

        if (imageCount % 20 == 0) {
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

    onProgress(ExportProgress(
      phase: 'zipping',
      current: 1,
      total: 1,
      message: 'ZIP 마무리 중...',
    ));
    await Future.delayed(Duration.zero);
    await zipEncoder.close();

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

