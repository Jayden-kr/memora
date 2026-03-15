import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;
import 'package:flutter/foundation.dart';
import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

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
  final Duration duration;

  const ImportResult({
    this.newCards = 0,
    this.skippedCards = 0,
    this.newFolders = 0,
    this.mergedFolders = 0,
    this.images = 0,
    this.duration = Duration.zero,
  });
}

class MemkImportService {
  /// 캐시된 Archive (readFolderList → importSelectedFolders 재사용)
  Archive? _cachedArchive;
  String? _cachedFilePath;

  /// 캐시된 Archive 해제 (Import 취소/완료 시 메모리 해제용)
  void clearCache() {
    _cachedArchive = null;
    _cachedFilePath = null;
  }

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
  /// Archive를 캐싱하여 importSelectedFolders에서 재사용
  Future<List<Map<String, dynamic>>> readFolderList(String filePath) async {
    final bytes = await File(filePath).readAsBytes();
    // 메인 isolate에서 직접 디코딩 (compute 사용 시 isolate 전송 과정에서
    // 일부 ArchiveFile 항목이 손실되어 이미지 누락 발생)
    final archive = ZipDecoder().decodeBytes(bytes, verify: false);
    _cachedArchive = archive;
    _cachedFilePath = filePath;

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
    Map<int, int?>? folderMapping,
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

    // 캐시된 Archive 재사용 (readFolderList에서 이미 디코딩됨)
    // 메모리 절약: zipBytes는 나중에 raw 추출이 필요할 때만 읽음
    Archive archive;
    if (_cachedArchive != null && _cachedFilePath == filePath) {
      archive = _cachedArchive!;
      _cachedArchive = null;
      _cachedFilePath = null;
    } else {
      final bytes = await File(filePath).readAsBytes();
      archive = ZipDecoder().decodeBytes(bytes, verify: false);
    }

    // ZIP 파일 인덱스 (이름 → ArchiveFile) + rawZipEntries를 archive에서 빌드
    final zipFileIndex = <String, ArchiveFile>{};
    final zipFileByBareName = <String, ArchiveFile>{};
    final rawZipEntries = <String>{};
    int archiveTotal = 0;
    int archiveFiles = 0;
    for (final file in archive.files) {
      archiveTotal++;
      if (file.isFile) {
        archiveFiles++;
        zipFileIndex[file.name] = file;
        rawZipEntries.add(file.name);
        final bareName = file.name.split('/').last;
        if (bareName.isNotEmpty) {
          zipFileByBareName[bareName] = file;
          rawZipEntries.add(bareName);
        }
      }
    }
    debugPrint('[IMPORT] archive entries: $archiveTotal total, $archiveFiles files, rawZipEntries=${rawZipEntries.length}');

    // folders.json 파싱
    final foldersFile = zipFileIndex[AppConstants.memkFoldersJson];
    if (foldersFile == null) {
      return ImportResult(duration: stopwatch.elapsed);
    }
    List<dynamic> foldersJson;
    try {
      foldersJson =
          jsonDecode(utf8.decode(foldersFile.content as List<int>))
              as List<dynamic>;
    } catch (e) {
      return ImportResult(duration: stopwatch.elapsed);
    }

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

      // folderMapping이 있으면 해당 매핑 사용 (null 값은 새 폴더 생성으로 fallback)
      if (folderMapping != null && folderMapping.containsKey(memkFolderId)) {
        final mappedId = folderMapping[memkFolderId];
        if (mappedId != null) {
          folderIdMap[memkFolderId] = mappedId;
          mergedFolders++;
          continue;
        }
        // mappedId가 null이면 아래 로직에서 새 폴더 생성
      }

      final existingFolder = await db.getFolderByName(name);

      if (existingFolder != null) {
        // 기존 폴더에 병합
        folderIdMap[memkFolderId] = existingFolder.id!;
        mergedFolders++;
      } else {
        // 새 폴더 생성 (id를 제거하여 autoincrement 사용)
        final folder = Folder.fromJson(folderData);
        try {
          final newId = await db.insertFolder(
            Folder(
              name: folder.name,
              cardCount: 0, // 나중에 updateFolderCardCount로 갱신
              folderCount: 0, // 번들 관계는 import에서 미지원
              sequence: folder.sequence,
              originalSequence: folder.originalSequence,
              modified: folder.modified,
              parent: false, // parentFolderId 리매핑 미지원이므로 리셋
              isSpecialFolder: folder.isSpecialFolder,
            ),
          );
          folderIdMap[memkFolderId] = newId;
          newFolders++;
        } catch (_) {
          // UNIQUE 제약 충돌 (동시 import 등) — 이미 존재하는 폴더 사용
          final retryFolder = await db.getFolderByName(name);
          if (retryFolder != null) {
            folderIdMap[memkFolderId] = retryFolder.id!;
            mergedFolders++;
          }
        }
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
    List<dynamic> cardsJson;
    try {
      cardsJson =
          jsonDecode(utf8.decode(cardsFile.content as List<int>))
              as List<dynamic>;
    } catch (e) {
      stopwatch.stop();
      return ImportResult(
        newFolders: newFolders,
        mergedFolders: mergedFolders,
        duration: stopwatch.elapsed,
      );
    }

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
          skippedCards++;
          continue;
        }
        if (!folderIdMap.containsKey(memkFolderId)) {
          skippedCards++;
          continue;
        }
        cardJson['folderId'] = folderIdMap[memkFolderId];

        // id 제거하여 autoincrement 사용 (UUID로 중복 관리)
        cardJson.remove('id');

        // uuid 방어적 처리: null/비문자열 → 건너뜀
        if (cardJson['uuid'] == null) {
          skippedCards++;
          continue;
        }
        cardJson['uuid'] = cardJson['uuid'].toString();
        if ((cardJson['uuid'] as String).isEmpty) {
          skippedCards++;
          continue;
        }

        // 이미지 경로 변환: memk 경로 → 로컬 경로 (ZIP에 있는 것만)
        _convertImagePaths(cardJson, appDocDir, neededImageFiles,
            zipFileIndex, zipFileByBareName, rawZipEntries);

        final card = CardModel.fromJson(cardJson);
        batch.add(card);

        // 배치 insert (UUID 중복은 건너뜀)
        if (batch.length >= AppConstants.importBatchSize) {
          final result = await db.insertCardsBatch(batch);
          newCards += result.inserted;
          skippedCards += result.skipped;
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
        debugPrint('[IMPORT] card parse error: $e');
        skippedCards++;
      }
    }

    // 남은 배치 처리
    if (batch.isNotEmpty) {
      final result = await db.insertCardsBatch(batch);
      newCards += result.inserted;
      skippedCards += result.skipped;
      batch.clear();
    }

    onProgress(ImportProgress(
      phase: 'images',
      currentCards: totalCards,
      totalCards: totalCards,
      message: '이미지 추출 중...',
    ));

    // 이미지 추출 — archive 인덱스에 있는 파일만 (누락분은 뒤에서 raw 추출)
    debugPrint('[IMPORT] neededImageFiles=${neededImageFiles.length}, newCards=$newCards, skippedCards=$skippedCards');
    int imageCount = 0;
    int archiveSkipped = 0;
    final totalImages = neededImageFiles.length;
    for (final fileName in neededImageFiles) {
      try {
        final zipFile = zipFileIndex[fileName] ?? zipFileByBareName[fileName];
        if (zipFile == null) {
          archiveSkipped++;
          continue;
        }

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
        debugPrint('[IMPORT] image extraction failed: $fileName — $e');
      }
    }
    debugPrint('[IMPORT] archive extraction: $imageCount extracted, $archiveSkipped skipped (not in archive index)');

    // archive에서 추출 실패한 이미지를 raw ZIP 파싱으로 추출
    // archive 객체 참조 해제 → 메모리 확보 후 파일을 다시 읽음
    final missingOnDisk = <String>{};
    for (final fileName in neededImageFiles) {
      final path = localImagePath(appDocDir, fileName);
      if (!File(path).existsSync()) {
        missingOnDisk.add(fileName);
      }
    }
    // counter.json 참조를 clear() 전에 보존
    final counterFile = zipFileIndex[AppConstants.memkCounterJson];

    if (missingOnDisk.isNotEmpty) {
      debugPrint('[IMPORT] ${missingOnDisk.length} images missing after archive extraction, trying raw ZIP extraction');
      // archive/인덱스 참조 해제하여 메모리 확보
      zipFileIndex.clear();
      zipFileByBareName.clear();
      // GC 기회 제공
      await Future.delayed(Duration.zero);

      final zipBytes = await File(filePath).readAsBytes();
      final rawExtracted = await _extractMissingImages(
        zipBytes: zipBytes,
        missingFileNames: missingOnDisk,
        appDocDir: appDocDir,
      );
      imageCount += rawExtracted;
      debugPrint('[IMPORT] raw ZIP extraction recovered $rawExtracted / ${missingOnDisk.length} images');
    }

    // 폴더 카드 수 업데이트
    for (final localFolderId in folderIdMap.values.toSet()) {
      await db.updateFolderCardCount(localFolderId);
    }

    // counter.json 처리 — 현재 값보다 높은 경우만 적용
    if (counterFile != null) {
      try {
        final counterJson =
            jsonDecode(utf8.decode(counterFile.content as List<int>));
        if (counterJson is List && counterJson.isNotEmpty) {
          final counterData = counterJson[0] as Map<String, dynamic>;
          final current = await db.getCounter();
          // snake_case / camelCase 양쪽 키 호환 (암기짱 원본은 camelCase)
          // num → int 안전 캐스트 (JSON 파싱 결과가 num일 수 있음)
          int counterVal(String snakeKey, String camelKey) =>
              (counterData[snakeKey] as num?)?.toInt() ??
              (counterData[camelKey] as num?)?.toInt() ??
              0;
          await db.updateCounter({
            'card_sequence': max(
              (current?['card_sequence'] as int?) ?? 0,
              counterVal('card_sequence', 'cardSequence'),
            ),
            'card_minus_sequence': max(
              (current?['card_minus_sequence'] as int?) ?? 0,
              counterVal('card_minus_sequence', 'cardMinusSequence'),
            ),
            'folder_sequence': max(
              (current?['folder_sequence'] as int?) ?? 0,
              counterVal('folder_sequence', 'folderSequence'),
            ),
            'folder_minus_sequence': max(
              (current?['folder_minus_sequence'] as int?) ?? 0,
              counterVal('folder_minus_sequence', 'folderMinusSequence'),
            ),
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
  /// archive 인덱스와 raw ZIP 인덱스를 모두 사용하여 경로 검증
  void _convertImagePaths(
    Map<String, dynamic> cardJson,
    String appDocDir,
    Set<String> neededFiles,
    Map<String, ArchiveFile> zipFileIndex,
    Map<String, ArchiveFile> zipFileByBareName,
    Set<String> rawZipEntries,
  ) {
    for (final key in cardJson.keys.toList()) {
      if (!key.contains('Path')) continue;
      final value = cardJson[key];
      if (value is! String || value.isEmpty) continue;

      final fileName = extractFileName(value);
      if (fileName.isEmpty) continue;

      // archive 인덱스 또는 raw ZIP 인덱스에 존재하면 경로 변환
      if (zipFileIndex.containsKey(fileName) ||
          zipFileByBareName.containsKey(fileName) ||
          rawZipEntries.contains(fileName)) {
        neededFiles.add(fileName);
        cardJson[key] = localImagePath(appDocDir, fileName);
      } else {
        cardJson[key] = '';
      }
    }
  }

  /// archive 패키지가 누락한 ZIP 항목을 직접 추출
  /// Central Directory에서 compSize/compression/localOffset를 읽고
  /// Local File Header에서 데이터 위치만 계산하여 추출
  /// (LFH의 compSize는 data descriptor 사용 시 0일 수 있으므로 CD 값 사용)
  static Future<int> _extractMissingImages({
    required Uint8List zipBytes,
    required Set<String> missingFileNames,
    required String appDocDir,
  }) async {
    if (missingFileNames.isEmpty) return 0;

    final bd = ByteData.sublistView(zipBytes);
    // EOCD 찾기
    int eocdPos = -1;
    for (int i = zipBytes.length - 22; i >= 0; i--) {
      if (zipBytes[i] == 0x50 && zipBytes[i + 1] == 0x4b &&
          zipBytes[i + 2] == 0x05 && zipBytes[i + 3] == 0x06) {
        eocdPos = i;
        break;
      }
    }
    if (eocdPos < 0) return 0;

    int cdSize = bd.getUint32(eocdPos + 12, Endian.little);
    int cdOffset = bd.getUint32(eocdPos + 16, Endian.little);

    // Central Directory에서 메타데이터 수집 (compSize, compression 포함)
    final targets = <String, ({int localOffset, int compSize, int compression})>{};
    int pos = cdOffset;
    final cdEnd = cdOffset + cdSize;
    while (pos + 46 <= cdEnd) {
      if (zipBytes[pos] != 0x50 || zipBytes[pos + 1] != 0x4b ||
          zipBytes[pos + 2] != 0x01 || zipBytes[pos + 3] != 0x02) {
        break;
      }
      final compression = bd.getUint16(pos + 10, Endian.little);
      final compSize = bd.getUint32(pos + 20, Endian.little);
      final fnameLen = bd.getUint16(pos + 28, Endian.little);
      final extraLen = bd.getUint16(pos + 30, Endian.little);
      final commentLen = bd.getUint16(pos + 32, Endian.little);
      final localOffset = bd.getUint32(pos + 42, Endian.little);

      if (fnameLen > 0 && pos + 46 + fnameLen <= zipBytes.length) {
        final fname = utf8.decode(
            zipBytes.sublist(pos + 46, pos + 46 + fnameLen),
            allowMalformed: true);
        final bareName = fname.split('/').last;
        if (missingFileNames.contains(fname) ||
            missingFileNames.contains(bareName)) {
          final key = bareName.isNotEmpty ? bareName : fname;
          targets[key] = (
            localOffset: localOffset,
            compSize: compSize,
            compression: compression,
          );
        }
      }
      pos += 46 + fnameLen + extraLen + commentLen;
    }

    debugPrint('[IMPORT] _extractMissingImages: ${targets.length} targets found in CD for ${missingFileNames.length} missing files');

    // Local File Header에서 데이터 위치만 계산 (fnameLen, extraLen)
    // compSize와 compression은 CD에서 가져온 값 사용
    int extracted = 0;
    for (final entry in targets.entries) {
      try {
        final fileName = entry.key;
        final t = entry.value;
        final offset = t.localOffset;
        if (offset + 30 > zipBytes.length) continue;

        final localSig = bd.getUint32(offset, Endian.little);
        if (localSig != 0x04034b50) {
          debugPrint('[IMPORT] bad LFH signature at $offset for $fileName');
          continue;
        }

        // LFH에서 가변 길이 필드만 읽기
        final localFnameLen = bd.getUint16(offset + 26, Endian.little);
        final localExtraLen = bd.getUint16(offset + 28, Endian.little);

        final dataStart = offset + 30 + localFnameLen + localExtraLen;
        final compSize = t.compSize;
        if (dataStart + compSize > zipBytes.length) {
          debugPrint('[IMPORT] data out of bounds for $fileName: start=$dataStart size=$compSize total=${zipBytes.length}');
          continue;
        }

        final compressedData = zipBytes.sublist(dataStart, dataStart + compSize);

        Uint8List fileData;
        if (t.compression == 8) {
          // Deflate
          fileData = Uint8List.fromList(
              ZLibCodec(raw: true).decode(compressedData));
        } else {
          // Store (compression == 0)
          fileData = Uint8List.fromList(compressedData);
        }

        final localPath = localImagePath(appDocDir, fileName);
        await File(localPath).writeAsBytes(fileData);
        extracted++;
      } catch (e) {
        debugPrint('[IMPORT] raw extraction failed: ${entry.key} — $e');
      }
    }
    return extracted;
  }
}
