import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'package:sqflite/sqflite.dart';

import '../database/database_helper.dart';
import '../models/card.dart';
import '../models/folder.dart';
import '../utils/constants.dart';

/// Import 진행 상태
class ImportProgress {
  final int currentCards;
  final int totalCards;
  final int currentImages;
  final int totalImages;
  final String phase; // 'parsing', 'cards', 'images', 'done'
  final String? message;

  const ImportProgress({
    this.currentCards = 0,
    this.totalCards = 0,
    this.currentImages = 0,
    this.totalImages = 0,
    this.phase = 'parsing',
    this.message,
  });
}

/// Import 결과
class ImportResult {
  final int newCards;
  final int skippedCards;
  final int newFolders;
  final int mergedFolders;
  final int images;
  final int errors;
  final Duration duration;

  const ImportResult({
    this.newCards = 0,
    this.skippedCards = 0,
    this.newFolders = 0,
    this.mergedFolders = 0,
    this.images = 0,
    this.errors = 0,
    this.duration = Duration.zero,
  });
}

class MemkImportService {
  /// .memk 경로에서 파일명만 추출
  static String extractFileName(String memkPath) {
    if (memkPath.isEmpty) return '';
    return memkPath.split('/').last;
  }

  /// 로컬 이미지 경로 생성
  static String localImagePath(String appDocDir, String fileName) {
    return p.join(appDocDir, AppConstants.imageDir, fileName);
  }

  /// ZIP에서 folders.json만 읽어 폴더 목록 반환 (UI에서 선택용)
  Future<List<Map<String, dynamic>>> readFolderList(String filePath) async {
    final bytes = await File(filePath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes, verify: false);

    for (final file in archive.files) {
      if (file.name == AppConstants.memkFoldersJson && file.isFile) {
        final jsonStr = utf8.decode(file.content as List<int>);
        final List<dynamic> foldersList = jsonDecode(jsonStr);
        return foldersList.cast<Map<String, dynamic>>();
      }
    }
    return [];
  }

  /// 선택된 폴더의 카드+이미지를 import
  /// [folderMapping]: memk 폴더 ID → 로컬 폴더 ID (null이면 자동 생성)
  Future<ImportResult> importSelectedFolders({
    required String filePath,
    required List<String> selectedFolderNames,
    required void Function(ImportProgress) onProgress,
    Map<int, int>? folderMapping,
  }) async {
    final stopwatch = Stopwatch()..start();
    final db = DatabaseHelper.instance;
    final appDocDir = (await getApplicationDocumentsDirectory()).path;

    // 이미지 디렉토리 생성
    final imageDir = Directory(p.join(appDocDir, AppConstants.imageDir));
    if (!imageDir.existsSync()) {
      imageDir.createSync(recursive: true);
    }

    onProgress(const ImportProgress(phase: 'parsing', message: '파일 분석 중...'));

    // ZIP 디코드
    final bytes = await File(filePath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes, verify: false);

    // ZIP 파일 인덱스 (이름 → ArchiveFile)
    final zipFileIndex = <String, ArchiveFile>{};
    for (final file in archive.files) {
      if (file.isFile) {
        zipFileIndex[file.name] = file;
      }
    }

    // folders.json 파싱
    final foldersFile = zipFileIndex[AppConstants.memkFoldersJson];
    if (foldersFile == null) {
      return ImportResult(duration: stopwatch.elapsed);
    }
    final foldersJson =
        jsonDecode(utf8.decode(foldersFile.content as List<int>))
            as List<dynamic>;

    // 선택된 폴더만 필터 + 폴더 ID 매핑
    final selectedFolderSet = selectedFolderNames.toSet();
    final folderIdMap = <int, int>{}; // memk folderId → local DB folderId
    int newFolders = 0;
    int mergedFolders = 0;

    for (final fJson in foldersJson) {
      final folderData = fJson as Map<String, dynamic>;
      final name = folderData['name'] as String;
      if (!selectedFolderSet.contains(name)) continue;

      final memkFolderId = (folderData['id'] as num?)?.toInt();
      if (memkFolderId == null) continue;

      // folderMapping이 있으면 해당 매핑 사용
      if (folderMapping != null && folderMapping.containsKey(memkFolderId)) {
        folderIdMap[memkFolderId] = folderMapping[memkFolderId]!;
        mergedFolders++;
        continue;
      }

      final existingFolder = await db.getFolderByName(name);

      if (existingFolder != null) {
        // 기존 폴더에 병합
        folderIdMap[memkFolderId] = existingFolder.id!;
        mergedFolders++;
      } else {
        // 새 폴더 생성 (id를 제거하여 autoincrement 사용)
        final folder = Folder.fromJson(folderData);
        final newId = await db.insertFolder(
          Folder(
            name: folder.name,
            cardCount: 0, // 나중에 updateFolderCardCount로 갱신
            folderCount: folder.folderCount,
            sequence: folder.sequence,
            originalSequence: folder.originalSequence,
            modified: folder.modified,
            parent: folder.parent,
            isSpecialFolder: folder.isSpecialFolder,
          ),
        );
        folderIdMap[memkFolderId] = newId;
        newFolders++;
      }
    }

    // cards.json 파싱
    final cardsFile = zipFileIndex[AppConstants.memkCardsJson];
    if (cardsFile == null) {
      stopwatch.stop();
      return ImportResult(
        newFolders: newFolders,
        mergedFolders: mergedFolders,
        duration: stopwatch.elapsed,
      );
    }
    final cardsJson =
        jsonDecode(utf8.decode(cardsFile.content as List<int>))
            as List<dynamic>;

    // 선택된 폴더의 카드만 필터
    final selectedCards = <Map<String, dynamic>>[];
    for (final c in cardsJson) {
      final cardData = c as Map<String, dynamic>;
      final folderId = (cardData['folderId'] as num?)?.toInt();
      if (folderId != null && folderIdMap.containsKey(folderId)) {
        selectedCards.add(cardData);
      }
    }

    final totalCards = selectedCards.length;
    int newCards = 0;
    int skippedCards = 0;
    int errors = 0;

    // 필요한 이미지 파일명 수집
    final neededImageFiles = <String>{};

    // 카드 배치 처리
    final batch = <CardModel>[];
    for (int i = 0; i < selectedCards.length; i++) {
      try {
        final cardJson = Map<String, dynamic>.from(selectedCards[i]);

        // folderId를 로컬 DB ID로 매핑
        final memkFolderId = (cardJson['folderId'] as num?)?.toInt();
        if (memkFolderId == null) {
          errors++;
          continue;
        }
        cardJson['folderId'] = folderIdMap[memkFolderId];

        // id 제거하여 autoincrement 사용 (UUID로 중복 관리)
        cardJson.remove('id');

        // 이미지 경로 변환: memk 경로 → 로컬 경로
        _convertImagePaths(cardJson, appDocDir, neededImageFiles);

        final card = CardModel.fromJson(cardJson);
        batch.add(card);

        // 배치 insert
        if (batch.length >= AppConstants.importBatchSize) {
          await db.insertCardsBatch(batch,
              conflictAlgorithm: ConflictAlgorithm.replace);
          newCards += batch.length;
          batch.clear();

          onProgress(ImportProgress(
            phase: 'cards',
            currentCards: newCards,
            totalCards: totalCards,
            message: '카드 처리 중... $newCards / $totalCards',
          ));

          // UI 갱신 기회
          await Future.delayed(Duration.zero);
        }
      } catch (e) {
        errors++;
      }
    }

    // 남은 배치 처리
    if (batch.isNotEmpty) {
      await db.insertCardsBatch(batch);
      newCards += batch.length;
      batch.clear();
    }

    onProgress(ImportProgress(
      phase: 'images',
      currentCards: totalCards,
      totalCards: totalCards,
      message: '이미지 추출 중...',
    ));

    // 이미지 추출
    int imageCount = 0;
    final totalImages = neededImageFiles.length;
    for (final fileName in neededImageFiles) {
      try {
        final zipFile = zipFileIndex[fileName];
        if (zipFile == null) continue;

        final localPath = localImagePath(appDocDir, fileName);
        final localFile = File(localPath);
        if (!localFile.existsSync()) {
          await localFile.writeAsBytes(zipFile.content as List<int>);
        }
        imageCount++;

        if (imageCount % 100 == 0) {
          onProgress(ImportProgress(
            phase: 'images',
            currentCards: totalCards,
            totalCards: totalCards,
            currentImages: imageCount,
            totalImages: totalImages,
            message: '이미지 추출 중... $imageCount / $totalImages',
          ));
          await Future.delayed(Duration.zero);
        }
      } catch (e) {
        errors++;
      }
    }

    // 폴더 카드 수 업데이트
    for (final localFolderId in folderIdMap.values.toSet()) {
      await db.updateFolderCardCount(localFolderId);
    }

    // counter.json 처리
    final counterFile = zipFileIndex[AppConstants.memkCounterJson];
    if (counterFile != null) {
      try {
        final counterJson =
            jsonDecode(utf8.decode(counterFile.content as List<int>));
        if (counterJson is List && counterJson.isNotEmpty) {
          final counterData = counterJson[0] as Map<String, dynamic>;
          await db.updateCounter({
            'card_sequence': counterData['card_sequence'] ?? 0,
            'card_minus_sequence': counterData['card_minus_sequence'] ?? 0,
            'folder_sequence': counterData['folder_sequence'] ?? 0,
            'folder_minus_sequence': counterData['folder_minus_sequence'] ?? 0,
          });
        }
      } catch (_) {}
    }

    stopwatch.stop();

    final result = ImportResult(
      newCards: newCards,
      skippedCards: skippedCards,
      newFolders: newFolders,
      mergedFolders: mergedFolders,
      images: imageCount,
      errors: errors,
      duration: stopwatch.elapsed,
    );

    onProgress(ImportProgress(
      phase: 'done',
      currentCards: totalCards,
      totalCards: totalCards,
      currentImages: imageCount,
      totalImages: totalImages,
      message: 'Import 완료',
    ));

    return result;
  }

  /// JSON 맵의 모든 이미지/음성 경로를 로컬 경로로 변환
  void _convertImagePaths(
    Map<String, dynamic> cardJson,
    String appDocDir,
    Set<String> neededFiles,
  ) {
    // Path를 포함하는 모든 키를 변환
    for (final key in cardJson.keys.toList()) {
      if (!key.contains('Path')) continue;
      final value = cardJson[key];
      if (value is! String || value.isEmpty) continue;

      final fileName = extractFileName(value);
      if (fileName.isEmpty) continue;

      neededFiles.add(fileName);
      cardJson[key] = localImagePath(appDocDir, fileName);
    }
  }
}
