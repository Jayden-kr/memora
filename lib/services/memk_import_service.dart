import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;
import 'package:flutter/foundation.dart';
import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../database/database_helper.dart';
import '../models/card.dart';
import '../models/folder.dart';
import '../utils/constants.dart';
import 'locale_service.dart';

bool get _isEn => LocaleService.currentLanguageCode() == 'en';

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

/// 아카이브가 Memora/암기왕 번들이 아닐 때(folders.json·cards.json 없음/깨짐) 던진다.
/// 예전엔 빈 ImportResult를 돌려줘 "Import 완료 · 0장"으로 보고됐다(감사 D7-12).
class ImportFormatException implements Exception {
  final String detail;
  const ImportFormatException(this.detail);
  @override
  String toString() => 'ImportFormatException: $detail';
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

  /// 아카이브의 JSON 항목 하나를 디코드한다. 없거나 JSON이 아니면 [ImportFormatException].
  static dynamic _decodeJsonEntry(ArchiveFile? file, String name) {
    if (file == null) {
      throw ImportFormatException('$name missing');
    }
    try {
      // `.content`는 압축해제 결과를 ArchiveFile 안에 영구 캐시한다 — writeContent는 스트림
      // 으로 바로 풀어 주고(freeMemory) 캐시를 남기지 않는다. 같은 항목을 다시 읽어도 된다
      // (원본 압축 데이터는 그대로).
      // 압축 전 크기를 알고 있으니 버퍼를 그 크기로 잡는다(기본 32KB에서 배증하며 커지면
      // 큰 cards.json에서 피크가 2~3배 — R20-06).
      final out = OutputMemoryStream(size: file.size > 0 ? file.size : null);
      file.writeContent(out);
      return jsonDecode(utf8.decode(out.getBytes()));
    } on ImportFormatException {
      rethrow;
    } catch (e) {
      throw ImportFormatException('$name unreadable: $e');
    }
  }

  /// .memk 경로에서 파일명만 추출 (/ 및 \ 모두 처리)
  static String extractFileName(String memkPath) {
    if (memkPath.isEmpty) return '';
    final name = memkPath.split('/').last.split('\\').last;
    // 경로 순회 공격 방지 (.., /, \ 포함 파일명 거부)
    if (name.contains('..') || name.contains('/') || name.contains('\\')) {
      return '';
    }
    return name;
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

    // importSelectedFolders는 cards.json도 요구한다 — 여기서 같이 검사해야 "목록엔 뜨는데
    // 가져오기는 거부"가 안 된다(R20-05).
    final hasCards = archive.files
        .any((f) => f.isFile && f.name == AppConstants.memkCardsJson);
    for (final file in archive.files) {
      if (file.name == AppConstants.memkFoldersJson && file.isFile) {
        if (!hasCards) {
          _cachedArchive = null;
          _cachedFilePath = null;
          throw const ImportFormatException('cards.json missing');
        }
        final decoded = _decodeJsonEntry(file, AppConstants.memkFoldersJson);
        if (decoded is! List) {
          throw const ImportFormatException('folders.json is not a list');
        }
        return decoded.cast<Map<String, dynamic>>();
      }
    }
    // folders.json이 없으면 Memora 번들이 아니다 — 빈 목록을 돌려주면 화면은 "폴더 0개"로
    // 정상 진행돼 결국 "완료 0장"이 된다. 호출자(ImportScreen/MultiImportScreen)는 예외를
    // 읽기 실패로 표시한다.
    _cachedArchive = null;
    _cachedFilePath = null;
    throw const ImportFormatException('folders.json missing');
  }

  /// 선택된 폴더의 카드+이미지를 import
  /// [folderMapping]: memk 폴더 ID → 로컬 폴더 ID (null이면 자동 생성)
  /// [conflictPolicy]: 동일 이름 폴더 처리 방식 — 'merge' (기존 폴더에 병합),
  /// 'rename' (새 이름으로 새 폴더 생성). 기본값은 'merge'.
  /// folderMapping에 명시된 폴더는 conflictPolicy의 영향을 받지 않는다.
  Future<ImportResult> importSelectedFolders({
    required String filePath,
    required List<String> selectedFolderNames,
    required void Function(ImportProgress) onProgress,
    Map<int, int?>? folderMapping,
    String conflictPolicy = 'merge',
  }) async {
    final stopwatch = Stopwatch()..start();
    final db = DatabaseHelper.instance;
    final appDocDir = (await getApplicationDocumentsDirectory()).path;

    // 이미지 디렉토리 생성 (동시 import 시 race condition 방지)
    final imageDir = Directory(p.join(appDocDir, AppConstants.imageDir));
    try {
      imageDir.createSync(recursive: true);
    } catch (e) {
      if (!imageDir.existsSync()) rethrow;
    }

    onProgress(ImportProgress(
        phase: 'parsing',
        message: _isEn ? 'Analyzing file...' : '파일 분석 중...'));

    // 캐시된 Archive 재사용 (readFolderList에서 이미 디코딩됨)
    // 메모리 절약: zipBytes는 나중에 raw 추출이 필요할 때만 읽음
    // nullable인 이유: 아래 raw ZIP 폴백 직전에 참조를 놓아 원본 버퍼가 회수되게 하려고.
    Archive? archive;
    if (_cachedArchive != null && _cachedFilePath == filePath) {
      archive = _cachedArchive!;
      _cachedArchive = null;
      _cachedFilePath = null;
    } else {
      // 캐시가 다른 파일 것이면 즉시 해제 (stale archive를 물고 있는 채로
      // 새 파일을 디코딩하면 메모리 사용량이 두 배로 뜀 — multi-import에서 OOM 위험)
      _cachedArchive = null;
      _cachedFilePath = null;
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

    // folders.json / cards.json 파싱 — 둘 다 폴더를 만들기 *전에* 검증한다. 어느 하나라도
    // 없거나 깨졌으면 ImportFormatException(빈 폴더만 남기고 "완료 0장"이 되지 않게).
    final foldersDecoded = _decodeJsonEntry(
        zipFileIndex[AppConstants.memkFoldersJson], AppConstants.memkFoldersJson);
    final cardsDecoded = _decodeJsonEntry(
        zipFileIndex[AppConstants.memkCardsJson], AppConstants.memkCardsJson);
    if (foldersDecoded is! List || cardsDecoded is! List) {
      throw const ImportFormatException('folders.json/cards.json is not a list');
    }
    final List<dynamic> foldersJson = foldersDecoded;
    final List<dynamic> cardsJson = cardsDecoded;
    // counter.json은 작으니 여기서 미리 디코드해 두고, 아래에서 아카이브 참조를 놓을 때
    // 같이 놓는다(예전엔 ArchiveFile 참조를 끝까지 들고 있어 원본 버퍼 전체가 pin됐다 — X6-03).
    Map<String, dynamic>? counterData;
    try {
      final counterDecoded = _decodeJsonEntry(
          zipFileIndex[AppConstants.memkCounterJson], AppConstants.memkCounterJson);
      if (counterDecoded is List && counterDecoded.isNotEmpty) {
        counterData = counterDecoded[0] as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('[IMPORT] counter.json 없음/깨짐 — 건너뜀: $e');
    }
    // 홈 '수동 정렬'은 sequence 순이다. 아카이브의 sequence를 그대로 심으면 새 폴더가 기존
    // 폴더 사이에 끼어들고 값이 겹친다(X3-04) — 이번 import의 새 폴더는 맨 뒤에 붙인다.
    int nextFolderSequence = await db.getMaxFolderSequence() + 1;

    // 선택된 폴더만 필터 + 폴더 ID 매핑
    final selectedFolderSet = selectedFolderNames.toSet();
    final folderIdMap = <int, int>{}; // memk folderId → local DB folderId
    // 이름 충돌 때문에 새 이름(_1, _2…)으로 만들어진 '복사본' 폴더의 로컬 id. 여기 들어가는
    // 카드는 원본과 uuid가 같으면 UNIQUE+ignore로 전부 건너뛰어 빈 폴더만 남으므로 새 uuid를 받는다.
    final renamedFolderIds = <int>{};
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
      // 이름이 같은 폴더가 '묶음(bundle)'이면 병합 대상이 아니다 — 묶음은 카드를 직접 갖지
      // 않아 홈 타일에 카드 수가 안 뜨고, 묶음 화면에선 카드에 도달할 수 없고, export
      // 목록에도 안 잡히며, 묶음을 지우면 CASCADE로 그 카드가 경고 없이 전멸한다.
      // 이 경우 정책과 무관하게 새 이름(_1, _2…)의 일반 폴더로 가져온다.
      final collidesWithBundle =
          existingFolder != null && existingFolder.isBundle;
      final mergeTarget = (existingFolder != null &&
              !existingFolder.isBundle &&
              conflictPolicy != 'rename')
          ? existingFolder
          : null;

      if (mergeTarget != null) {
        // 기존 폴더에 병합
        folderIdMap[memkFolderId] = mergeTarget.id!;
        mergedFolders++;
      } else {
        // 새 폴더 생성 (id를 제거하여 autoincrement 사용)
        // 이름 충돌(rename 정책 또는 묶음과 충돌) 시 _1, _2 등 unique suffix 부여
        final folder = Folder.fromJson(folderData);
        String targetName = folder.name;
        final renamed = existingFolder != null &&
            (conflictPolicy == 'rename' || collidesWithBundle);
        if (renamed) {
          int suffix = 1;
          while (await db.getFolderByName('${folder.name}_$suffix') != null) {
            suffix++;
          }
          targetName = '${folder.name}_$suffix';
        }
        try {
          final newId = await db.insertFolder(
            Folder(
              name: targetName,
              cardCount: 0, // 나중에 updateFolderCardCount로 갱신
              folderCount: 0, // 번들 관계는 import에서 미지원
              sequence: nextFolderSequence++,
              originalSequence: folder.originalSequence,
              modified: folder.modified,
              parent: false, // parentFolderId 리매핑 미지원이므로 리셋
              isSpecialFolder: folder.isSpecialFolder,
              isBundle: folder.isBundle,
            ),
          );
          folderIdMap[memkFolderId] = newId;
          newFolders++;
          if (renamed) renamedFolderIds.add(newId);
        } catch (_) {
          // UNIQUE 제약 충돌 (동시 import 등) — 이미 존재하는 '일반' 폴더만 병합 대상
          // (여기서 묶음을 잡으면 위에서 막은 경로가 되살아난다)
          final retryFolder = await db.getNonBundleFolderByName(targetName);
          if (retryFolder != null) {
            folderIdMap[memkFolderId] = retryFolder.id!;
            mergedFolders++;
          }
        }
      }
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
    Future<void> flushBatch() async {
      if (batch.isEmpty) return;
      try {
        final result = await db.insertCardsBatch(batch);
        newCards += result.inserted;
        skippedCards += result.skipped;
      } catch (e) {
        // 배치 전체가 실패(대상 폴더가 import 도중 삭제돼 FK 위반 등)하면 그 배치는 건너뛴다 —
        // 예전엔 batch를 비우지 않아 다음 카드마다 같은 배치를 다시 던져 O(N²)로 멈춘 듯
        // 보이다가 결국 한 장도 안 들어갔다(D1-02).
        debugPrint('[IMPORT] batch insert failed, ${batch.length} cards skipped: $e');
        skippedCards += batch.length;
      }
      batch.clear();
    }

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
        // '새 이름으로 가져오기'(또는 묶음과 이름 충돌)로 만들어진 복사본 폴더의 카드는
        // 새 uuid를 받는다. 원본과 같은 uuid면 insertCardsBatch의 UNIQUE+ignore가 전부
        // 건너뛰어 "카드 0장짜리 빈 폴더"만 남고, uuid 복구 분기는 원본 폴더의 카드를 건드렸다.
        if (renamedFolderIds.contains(cardJson['folderId'] as int)) {
          cardJson['uuid'] =
              '${const Uuid().v4()}-import-${DateTime.now().microsecondsSinceEpoch}';
        }

        // 이미지 경로 변환: memk 경로 → 로컬 경로 (ZIP에 있는 것만)
        _convertImagePaths(cardJson, appDocDir, neededImageFiles,
            zipFileIndex, zipFileByBareName, rawZipEntries);

        final card = CardModel.fromJson(cardJson);
        batch.add(card);

        // 배치 insert (UUID 중복은 건너뜀)
        if (batch.length >= AppConstants.importBatchSize) {
          await flushBatch();

          // 진행률은 '처리한' 카드 수(i+1)다 — '삽입된' 수(newCards)로 세면 재import처럼
          // 전부 건너뛰는 경우 0/N에 멈춰 보였다(D7-08).
          final processed = i + 1;
          onProgress(ImportProgress(
            phase: 'cards',
            currentCards: processed,
            totalCards: totalCards,
            message: _isEn
                ? 'Processing cards... $processed / $totalCards'
                : '카드 처리 중... $processed / $totalCards',
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
    await flushBatch();

    onProgress(ImportProgress(
      phase: 'images',
      currentCards: totalCards,
      totalCards: totalCards,
      message: _isEn ? 'Extracting images...' : '이미지 추출 중...',
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
        // 같은 이름의 파일이 이미 있으면 덮어쓰지 않는다. 단, 아카이브 것보다 *짧은* 파일은
        // 예전 버전의 중단된 import가 최종 경로에 직접 쓰다 남긴 잘린 파일이므로 교체한다.
        // "크기가 다르기만 하면 덮는다"던 규칙은 이름만 같은 남의 사진까지 바꿔치기했다(X3-05).
        final existingLen =
            localFile.existsSync() ? localFile.lengthSync() : -1;
        if (existingLen < 0 || existingLen < zipFile.size) {
          // 임시 파일에 스트리밍으로 풀고 rename — (1) 압축해제 결과를 ArchiveFile 캐시에
          // 남기지 않아(D7-02: `.content`는 끝까지 힙에 남았다) 피크 메모리가 "원본 + 이미지
          // 한 장"으로 고정되고, (2) 도중에 강제종료돼도 최종 경로엔 완전한 파일만 남는다
          // (D7-06: 잘린 이미지가 영구 고착되던 구멍).
          await _writeArchiveFileAtomically(zipFile, localPath);
        }
        imageCount++;

        if (imageCount % 100 == 0) {
          onProgress(ImportProgress(
            phase: 'images',
            currentCards: totalCards,
            totalCards: totalCards,
            currentImages: imageCount,
            totalImages: totalImages,
            message: _isEn
                ? 'Extracting images... $imageCount / $totalImages'
                : '이미지 추출 중... $imageCount / $totalImages',
          ));
          await Future.delayed(Duration.zero);
        }
      } catch (e) {
        debugPrint('[IMPORT] image extraction failed: $fileName — $e');
      }
    }
    debugPrint('[IMPORT] archive extraction: $imageCount extracted, $archiveSkipped skipped (not in archive index)');

    // archive에서 추출 실패한 이미지를 raw ZIP 파싱으로 추출
    final missingOnDisk = <String>{};
    for (final fileName in neededImageFiles) {
      final path = localImagePath(appDocDir, fileName);
      if (!File(path).existsSync()) {
        missingOnDisk.add(fileName);
      }
    }

    if (missingOnDisk.isNotEmpty) {
      debugPrint('[IMPORT] ${missingOnDisk.length} images missing after archive extraction, trying raw ZIP extraction');
      // 아카이브 참조를 *전부* 놓는다 — 인덱스 맵만 비우던 예전 코드는 archive 지역변수와
      // counter.json ArchiveFile이 원본 버퍼 전체를 붙들고 있어 아무것도 회수되지 않았고,
      // 그 위에 파일을 통째로 다시 읽어 피크가 2배였다(X6-03). 지금은 폴백이 파일을
      // RandomAccessFile로 필요한 항목만 읽는다.
      zipFileIndex.clear();
      zipFileByBareName.clear();
      archive = null;
      // GC 기회 제공
      await Future.delayed(Duration.zero);

      final rawExtracted = await _extractMissingImages(
        zipPath: filePath,
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

    // counter.json 처리 — 현재 값보다 높은 경우만 적용 (위에서 미리 디코드해 둔 값)
    if (counterData != null) {
      try {
        final current = await db.getCounter();
        // snake_case / camelCase 양쪽 키 호환 (.memk 원본은 camelCase)
        // num → int 안전 캐스트 (JSON 파싱 결과가 num일 수 있음)
        int counterVal(String snakeKey, String camelKey) =>
            (counterData![snakeKey] as num?)?.toInt() ??
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
      } catch (e) {
        debugPrint('[IMPORT] counter.json merge 실패: $e');
      }
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
      message: _isEn ? 'Import complete' : 'Import 완료',
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
      if (fileName.isEmpty) {
        // 경로 순회 등으로 거부된 이름 — 남의 샌드박스를 가리키는 레거시 절대경로를 그대로
        // 저장하면 깨진 이미지가 export로 전파된다(X4-08). 아래 '아카이브에 없음' 분기와 같이
        // 빈 값으로 지운다.
        cardJson[key] = '';
        continue;
      }

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

  /// ArchiveFile 하나를 `<localPath>.tmp`에 스트리밍으로 풀고 rename한다.
  /// writeContent(freeMemory: true)는 압축해제 결과를 ArchiveFile에 캐시하지 않는다.
  static Future<void> _writeArchiveFileAtomically(
      ArchiveFile zipFile, String localPath) async {
    final tmpPath = '$localPath.tmp';
    final out = OutputFileStream(tmpPath);
    try {
      zipFile.writeContent(out);
    } finally {
      out.closeSync();
    }
    await File(tmpPath).rename(localPath);
  }

  /// archive 패키지가 누락한 ZIP 항목을 직접 추출
  /// Central Directory에서 compSize/compression/localOffset를 읽고
  /// Local File Header에서 데이터 위치만 계산하여 추출
  /// (LFH의 compSize는 data descriptor 사용 시 0일 수 있으므로 CD 값 사용)
  ///
  /// 파일을 통째로 읽지 않는다 — EOCD·Central Directory·대상 항목만 RandomAccessFile로
  /// 읽어 피크 메모리가 "가장 큰 항목 하나"로 묶인다(X6-03).
  static Future<int> _extractMissingImages({
    required String zipPath,
    required Set<String> missingFileNames,
    required String appDocDir,
  }) async {
    if (missingFileNames.isEmpty) return 0;

    final raf = await File(zipPath).open();
    try {
      final fileLen = await raf.length();
      if (fileLen < 22) return 0; // 최소 ZIP 크기 검증

      // EOCD는 파일 끝에서 최대 65535(주석)+22바이트 안에 있다.
      final tailLen = fileLen < 65557 ? fileLen : 65557;
      await raf.setPosition(fileLen - tailLen);
      final tail = await raf.read(tailLen);
      int eocdPos = -1;
      for (int i = tail.length - 22; i >= 0; i--) {
        if (tail[i] == 0x50 && tail[i + 1] == 0x4b &&
            tail[i + 2] == 0x05 && tail[i + 3] == 0x06) {
          eocdPos = i;
          break;
        }
      }
      if (eocdPos < 0) return 0;
      final tailBd = ByteData.sublistView(tail);
      final cdSize = tailBd.getUint32(eocdPos + 12, Endian.little);
      final cdOffset = tailBd.getUint32(eocdPos + 16, Endian.little);
      if (cdSize <= 0 || cdOffset < 0 || cdOffset + cdSize > fileLen) return 0;

      // Central Directory만 메모리에 올린다 (항목당 46바이트+이름 — 수만 항목이라도 수 MB)
      await raf.setPosition(cdOffset);
      final cd = await raf.read(cdSize);
      final bd = ByteData.sublistView(cd);

      // Central Directory에서 메타데이터 수집 (compSize, compression 포함)
      final targets = <String, ({int localOffset, int compSize, int compression})>{};
      int pos = 0;
      while (pos + 46 <= cd.length) {
        if (cd[pos] != 0x50 || cd[pos + 1] != 0x4b ||
            cd[pos + 2] != 0x01 || cd[pos + 3] != 0x02) {
          break;
        }
        final compression = bd.getUint16(pos + 10, Endian.little);
        final compSize = bd.getUint32(pos + 20, Endian.little);
        final fnameLen = bd.getUint16(pos + 28, Endian.little);
        final extraLen = bd.getUint16(pos + 30, Endian.little);
        final commentLen = bd.getUint16(pos + 32, Endian.little);
        final localOffset = bd.getUint32(pos + 42, Endian.little);

        if (fnameLen > 0 && pos + 46 + fnameLen <= cd.length) {
          final fname = utf8.decode(
              cd.sublist(pos + 46, pos + 46 + fnameLen),
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
          if (offset < 0 || offset + 30 > fileLen) continue;

          // deflate(8)/store(0) 외의 압축 방식은 풀 수 없다 — 예전엔 전부 '무압축'으로 보고
          // 압축 바이트를 그대로 .jpg로 저장해 영구히 깨진 이미지를 만들었다(X6-02).
          if (t.compression != 0 && t.compression != 8) {
            debugPrint('[IMPORT] unsupported compression ${t.compression} for $fileName — skipped');
            continue;
          }

          await raf.setPosition(offset);
          final lfh = await raf.read(30);
          if (lfh.length < 30) continue;
          final lbd = ByteData.sublistView(lfh);
          final localSig = lbd.getUint32(0, Endian.little);
          if (localSig != 0x04034b50) {
            debugPrint('[IMPORT] bad LFH signature at $offset for $fileName');
            continue;
          }

          final localFnameLen = lbd.getUint16(26, Endian.little);
          final localExtraLen = lbd.getUint16(28, Endian.little);
          final dataStart = offset + 30 + localFnameLen + localExtraLen;
          final compSize = t.compSize;
          // 단일 파일 100MB 제한 (악의적 ZIP 대응)
          if (compSize > 100 * 1024 * 1024 || dataStart + compSize > fileLen) {
            debugPrint('[IMPORT] data out of bounds for $fileName: start=$dataStart size=$compSize total=$fileLen');
            continue;
          }

          await raf.setPosition(dataStart);
          final compressedData = await raf.read(compSize);
          if (compressedData.length != compSize) continue;

          final Uint8List fileData = t.compression == 8
              ? Uint8List.fromList(ZLibCodec(raw: true).decode(compressedData))
              : compressedData;

          final localPath = localImagePath(appDocDir, fileName);
          // 임시 파일에 먼저 쓰고 rename — 쓰기 도중 강제종료돼도 최종 경로에는
          // 완전한 파일만 존재하게 되어 손상 파일이 남지 않음
          final tmpFile = File('$localPath.tmp');
          await tmpFile.writeAsBytes(fileData);
          await tmpFile.rename(localPath);
          extracted++;
        } catch (e) {
          debugPrint('[IMPORT] raw extraction failed: ${entry.key} — $e');
        }
      }
      return extracted;
    } finally {
      await raf.close();
    }
  }
}
