import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../database/database_helper.dart';
import '../models/folder.dart';
import '../services/locale_service.dart';
import '../services/memk_import_service.dart';
import '../services/memk_export_service.dart';

/// Import/Export 백그라운드 처리 + 알림 관리 컨트롤러 (싱글톤)
class ImportExportController {
  static final instance = ImportExportController._();
  ImportExportController._();

  static const _channel =
      MethodChannel('com.henry.memora/import_export');

  final _importService = MemkImportService();
  final _exportService = MemkExportService();

  /// ImportScreen과 공유하여 Archive 캐시 재사용
  MemkImportService get importService => _importService;

  // 동시 실행 방지 락
  Completer<void>? _operationLock;

  // 공통 상태
  bool isRunning = false;
  String? currentOperation; // 'import' or 'export'

  // Import 상태
  ImportResult? lastImportResult;
  /// 지금 돌고 있는 import의 파일 경로(없으면 null) / 마지막으로 돌린 import의 파일 경로.
  /// ImportScreen이 "내 파일의 진행/완료인가"를 판정하는 데 쓴다.
  String? currentImportFilePath;
  String? lastImportFilePath;
  ImportProgress currentImportProgress = const ImportProgress();

  // Export 상태
  String exportProgressMessage = '';
  double exportProgressValue = 0.0;
  List<String>? lastExportFileNames;
  List<String>? lastExportFilePaths;
  Object? lastExportError;

  void clearExportResult() {
    lastExportFileNames = null;
    lastExportFilePaths = null;
    lastExportError = null;
  }

  /// 사용자가 "중지"를 눌렀다. 돌고 있는 루프가 다음 경계에서 스스로 멈춘다.
  bool _cancelRequested = false;

  /// 진행 중인 작업을 사용자가 멈춰 달라고 요청했는가. 화면이 버튼 상태를 이걸로 잡는다.
  /// 작업이 끝나면 자동으로 false다 — 다음 작업 시작 전에 옛 요청이 남아 보이지 않는다.
  bool get isCancelRequested => isRunning && _cancelRequested;

  /// 진행 중인 가져오기/내보내기 중단을 요청한다.
  ///
  /// 즉시 멈추지는 않는다. 가져오기는 배치 경계에서, PDF는 카드 경계에서 멈춘다 —
  /// 트랜잭션이나 페이지를 그리다 마는 일이 없게 하기 위해서다. 이미 들어간 카드는
  /// 그대로 남고(부분 롤백은 병합 가져오기에서 "이번 것만" 골라낼 수 없다), 만들다 만
  /// PDF 파일은 네이티브가 지운다.
  Future<void> requestCancel() async {
    if (!isRunning || _cancelRequested) return;
    _cancelRequested = true;
    _notify();
    // PDF는 네이티브 루프 안에서 돌아 Dart 플래그를 못 본다 — 채널로 따로 알린다.
    try {
      await _channel.invokeMethod('cancelPdf');
    } catch (e) {
      debugPrint('[ImportExportController] cancelPdf 전달 실패: $e');
    }
  }

  /// 진행 중인 작업 상태를 강제로 되돌린다(락 해제 + 알림 정리).
  ///
  /// ⚠️ 이름과 달리 **돌고 있는 작업 자체를 중단시키지는 못한다** — import/export 루프에
  /// 취소 신호를 전달할 수단이 없어서, 이 함수는 컨트롤러 쪽 상태만 정리한다. 실제로
  /// 호출되는 곳은 앱 시작의 [cleanupStaleState] 하나이며, 그 시점엔 이전 프로세스가
  /// 이미 죽어 있어 "돌고 있는 작업"이 존재하지 않는다(감사 Y3-02: 예전 주석은 "OOM/stuck
  /// 복구"라고 적어 두어, 진행 중 작업을 멈출 수 있는 것처럼 읽혔다).
  void forceCancel() {
    if (!isRunning) return;
    _cancelRequested = false;
    isRunning = false;
    currentOperation = null;
    _releaseLock();
    clearExportResult();
    _cancel();
    _notify();
  }

  /// 앱 시작 시 잔여 상태 정리. main()이 await한다 — 시작 GC의 "import 중이면 스킵"
  /// 가드가 이 마커 정리와 순서가 고정돼야 하기 때문(둘 다 fire-and-forget이던 시절엔
  /// 가드가 실행마다 랜덤으로 켜졌다 꺼졌다 했다).
  ///
  /// 하는 일은 두 가지뿐이다. 지난 실행이 남긴 `import_in_progress` 마커를 지우고,
  /// 그 흔적이 있었을 때만 진행 알림을 내린다. **반쯤 들어간 폴더·카드를 되돌리지는
  /// 않는다**(감사 Y3-02: 예전 주석의 "OOM-recovery"는 그런 복구를 하는 것처럼 읽혔다).
  Future<void> cleanupStaleState() async {
    if (isRunning) forceCancel();
    // OOM-recovery: 이전 import가 중간에 죽었으면 stale marker 살아있음.
    // 현재는 marker만 clear (실제 부분 폴더 cleanup은 추후 라운드).
    final hadStaleMarker = await _clearStaleImportMarker();
    // 잔여 foreground service 알림 제거는 지난 실행이 도중에 죽은 흔적(마커)이 있을 때만.
    // 무조건 보내면 앱을 켤 때마다 ImportExportService를 콜드 생성하고 알림 채널을 만든다.
    if (hadStaleMarker) await _cancel();
  }

  /// 반환: stale 마커가 있어서 지웠으면 true.
  Future<bool> _clearStaleImportMarker() async {
    try {
      final settings = await DatabaseHelper.instance.getAllSettings();
      final stale = settings['import_in_progress'];
      if (stale != null && stale.isNotEmpty) {
        debugPrint(
            '[ImportExportController] stale import marker detected: $stale (likely OOM kill, marker cleared)');
        await DatabaseHelper.instance.deleteSetting('import_in_progress');
        return true;
      }
    } catch (_) {}
    return false;
  }

  // 리스너 (UI 갱신용)
  final List<void Function()> _listeners = [];

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);
  void _notify() {
    for (final l in List.of(_listeners)) {
      // 리스너 하나가 던져도 나머지 리스너와 호출자(start*)는 계속 간다 — 예전엔 락을 잡은
      // 직후의 _notify()에서 새면 락이 영영 안 풀려 import/export 전 기능이 재시작 전까지
      // 죽었다(Z2-03).
      try {
        l();
      } catch (e, st) {
        debugPrint('[ImportExportController] listener threw: $e\n$st');
      }
    }
  }

  /// 락 해제 — 이미 풀렸으면 무시(성공 경로에서 풀고 뒤이은 알림 호출이 던져 catch로 오면
  /// 두 번째 complete()가 StateError를 냈다).
  void _releaseLock() {
    final lock = _operationLock;
    if (lock != null && !lock.isCompleted) lock.complete();
  }

  // ─── 배치 import (MultiImportScreen) ───
  // 파일마다 FGS를 껐다 켜면(complete→STOP→startForegroundService) 앱이 뒤로 물러난 상태에서
  // 두 번째 파일부터 Android 12+ 배경 FGS 시작 제한에 걸릴 수 있고 그 실패는 삼켜졌다(X1-03).
  // 배치 동안은 서비스를 내리지 않고, 완료 알림도 합계로 한 번만 낸다(X1-06).
  int _batchDepth = 0;
  int _batchFiles = 0;
  int _batchFailed = 0;
  int _batchNewCards = 0;
  Duration _batchDuration = Duration.zero;

  /// 배치가 열려 있으면 파일 사이의 짧은 틈에도 true — 홈 뒤로가기의 "백그라운드로" 판정용.
  bool get isBusy => isRunning || _batchDepth > 0;

  void beginImportBatch() {
    if (_batchDepth++ == 0) {
      _batchFiles = 0;
      _batchFailed = 0;
      _batchNewCards = 0;
      _batchDuration = Duration.zero;
    }
  }

  Future<void> endImportBatch() async {
    if (_batchDepth == 0) return;
    if (--_batchDepth > 0) return;
    if (_batchFiles == 0 && _batchFailed == 0) {
      await _cancel();
      return;
    }
    final isEn = LocaleService.currentLanguageCode() == 'en';
    final secs = _batchDuration.inSeconds;
    if (_batchFiles == 0) {
      // 전부 실패 — "완료 · 0장"으로 포장하지 않는다(R20-03).
      await _complete(
        isEn ? 'Import failed' : 'Import 실패',
        isEn ? '$_batchFailed file(s) failed' : '$_batchFailed개 파일 실패',
      );
      return;
    }
    final failedNote = _batchFailed == 0
        ? ''
        : (isEn ? ', $_batchFailed failed' : ', 실패 $_batchFailed개');
    final body = isEn
        ? 'Imported $_batchNewCards card(s) from $_batchFiles file(s) (${secs}s)$failedNote'
        : '$_batchFiles개 파일에서 $_batchNewCards장 가져옴 ($secs초)$failedNote';
    await _complete(isEn ? 'Import complete' : 'Import 완료', body);
  }

  // ─── Foreground Service 제어 ───

  Future<void> _startService(String title, {String type = 'import'}) async {
    try {
      await _channel.invokeMethod('startService', {
        'title': title,
        'type': type,
      });
    } catch (_) {}
  }

  Future<void> _updateProgress(
    String title,
    String message,
    int progress,
    int max, {
    String type = 'import',
  }) async {
    try {
      await _channel.invokeMethod('updateProgress', {
        'title': title,
        'message': message,
        'progress': progress,
        'max': max,
        'type': type,
      });
    } catch (_) {}
  }

  Future<void> _complete(String title, String message,
      {String type = 'import'}) async {
    try {
      await _channel.invokeMethod('complete', {
        'title': title,
        'message': message,
        'type': type,
      });
    } catch (_) {}
  }

  Future<void> _cancel() async {
    try {
      await _channel.invokeMethod('cancel');
    } catch (_) {}
  }

  // ─── Import ───

  /// 반환값 false = 다른 가져오기/내보내기가 진행 중이라 이번 요청을 무시했다.
  /// 호출 화면이 그 사실을 사용자에게 알려야 한다 — 예전엔 조용히 아무 일도
  /// 일어나지 않아 버튼이 고장 난 것처럼 보였다.
  Future<bool> startImport({
    required String filePath,
    required List<String> selectedFolderNames,
    Map<int, int?>? folderMapping,
    String conflictPolicy = 'merge',
  }) async {
    // 동시 실행 방지 (Completer 기반 락)
    if (_operationLock != null && !_operationLock!.isCompleted) return false;
    _operationLock = Completer<void>();

    _cancelRequested = false;
    isRunning = true;
    currentOperation = 'import';
    currentImportFilePath = filePath;
    lastImportFilePath = filePath;
    lastImportResult = null;
    currentImportProgress = const ImportProgress();
    _notify();

    // OOM-recovery marker: 이 import가 진행 중임을 disk에 기록.
    // 다음 앱 시작 시 cleanupStaleState가 marker 보고 stale 인지.
    try {
      await DatabaseHelper.instance.upsertSetting('import_in_progress', filePath);
    } catch (_) {}

    final isEn = LocaleService.currentLanguageCode() == 'en';
    final importTitle = isEn ? 'Importing' : 'Import 진행 중';
    final processingMsg = isEn ? 'Processing...' : '처리 중...';

    try {
      await _startService(importTitle);
    } catch (_) {}

    try {
      final result = await _importService.importSelectedFolders(
        filePath: filePath,
        selectedFolderNames: selectedFolderNames,
        folderMapping: folderMapping,
        conflictPolicy: conflictPolicy,
        shouldCancel: () => _cancelRequested,
        onProgress: (progress) {
          currentImportProgress = progress;
          _notify();

          // 카드+이미지 통합 진행률 계산 (0-100)
          final cardProg = progress.totalCards > 0
              ? progress.currentCards / progress.totalCards
              : 0.0;
          final imageProg = progress.totalImages > 0
              ? progress.currentImages / progress.totalImages
              : 0.0;
          double combined;
          if (progress.phase == 'images') {
            combined = (cardProg + imageProg) / 2;
          } else if (progress.phase == 'cards') {
            combined = cardProg * 0.5;
          } else {
            combined = 0.0;
          }

          _updateProgress(
            importTitle,
            progress.message ?? processingMsg,
            (combined * 100).round(),
            100,
          );
        },
      );

      lastImportResult = result;
      isRunning = false;
      currentOperation = null;
      currentImportFilePath = null;
      _releaseLock();
      _notify();

      // import 정상 완료 → marker clear
      try {
        await DatabaseHelper.instance.deleteSetting('import_in_progress');
      } catch (_) {}

      if (_batchDepth > 0) {
        // 배치 중: 서비스는 유지, 완료 알림은 endImportBatch가 합계로 한 번.
        _batchFiles++;
        _batchNewCards += result.newCards;
        _batchDuration += result.duration;
        return true;
      }
      final body = result.cancelled
          ? (isEn
              ? 'Cancelled — ${result.newCards} card(s) were imported'
              : '취소됨 — ${result.newCards}장까지 들어왔습니다')
          : (isEn
              ? 'Imported ${result.newCards} card(s) (${result.duration.inSeconds}s)'
              : '${result.newCards}장 가져옴 (${result.duration.inSeconds}초)');
      await _complete(
        result.cancelled
            ? (isEn ? 'Import cancelled' : 'Import 취소됨')
            : (isEn ? 'Import complete' : 'Import 완료'),
        body,
      );
      return true;
    } catch (e) {
      isRunning = false;
      currentOperation = null;
      currentImportFilePath = null;
      _releaseLock();
      _notify();
      // 실패도 마커 clear (실패는 사용자가 인지하고 재시도 가능, OOM kill 아니라)
      try {
        await DatabaseHelper.instance.deleteSetting('import_in_progress');
      } catch (_) {}
      if (_batchDepth > 0) {
        // 배치 중엔 FGS를 내리지 않는다(다음 파일이 배경에서 다시 못 띄울 수 있다).
        _batchFailed++;
      } else {
        await _cancel();
      }
      rethrow;
    }
  }

  // ─── Export (Memk per folder) ───

  /// 파일 이름 stem이 차지할 수 있는 최대 UTF-8 바이트. Android(ext4/f2fs)의 이름 한도는
  /// 255바이트 — `_NNN.mra`/`.pdf` 접미사 여유를 두고 자른다. 긴 폴더 이름 하나가 배치
  /// 전체를 ENAMETOOLONG으로 중단시켰다(D7-14).
  static const _maxStemBytes = 200;

  @visibleForTesting
  static String sanitizeFileName(String name) => _sanitizeFileName(name);

  static String _sanitizeFileName(String name) {
    var sanitized =
        name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
    if (utf8.encode(sanitized).length > _maxStemBytes) {
      final buf = StringBuffer();
      var used = 0;
      for (final rune in sanitized.runes) {
        final n = utf8.encode(String.fromCharCode(rune)).length;
        if (used + n > _maxStemBytes) break;
        buf.writeCharCode(rune);
        used += n;
      }
      sanitized = buf.toString().trimRight();
    }
    return sanitized.isEmpty ? 'export' : sanitized;
  }

  /// 반환값 false = 다른 가져오기/내보내기가 진행 중이라 이번 요청을 무시했다
  /// (규약은 [startImport]와 같다).
  Future<bool> startMemkPerFolderExport({
    required List<Folder> selectedFolders,
    required String exportDirPath,
    String conflictPolicy = 'rename',
  }) async {
    if (_operationLock != null && !_operationLock!.isCompleted) return false;
    _operationLock = Completer<void>();

    final isEn = LocaleService.currentLanguageCode() == 'en';
    final exportTitle = isEn ? 'Exporting' : 'Export 진행 중';
    final preparingMsg = isEn ? 'Preparing...' : '준비 중...';
    final processingMsg = isEn ? 'Processing...' : '처리 중...';

    _cancelRequested = false;
    isRunning = true;
    currentOperation = 'export';
    clearExportResult();
    exportProgressMessage = preparingMsg;
    exportProgressValue = 0.0;
    _notify();

    try { await _startService(exportTitle, type: 'export'); } catch (_) {}

    final createdFiles = <String>[];
    final createdFileNames = <String>[];
    var exportCancelled = false;
    try {
      final totalFolders = selectedFolders.length;
      // 이번 배치에서 이미 사용(claim)한 출력 경로 — 동일 배치 내 이름 충돌 감지용
      final usedOutputPaths = <String>{};

      for (int i = 0; i < selectedFolders.length; i++) {
        // .mra는 폴더 하나가 통째로 한 파일이라 폴더 경계에서만 멈춘다 — 도중에
        // 끊으면 반쪽짜리 .mra가 남는다.
        if (_cancelRequested) {
          exportCancelled = true;
          break;
        }
        final folder = selectedFolders[i];
        final folderProgressBase = i / totalFolders;
        final folderWeight = 1.0 / totalFolders;

        final safeName = _sanitizeFileName(folder.name);
        var fileName = '$safeName.mra';
        var outputPath = p.join(exportDirPath, fileName);
        // 감사 Y4-01: 예전엔 기존 파일을 **먼저 지우고** 새로 만들었다. 새 내보내기가
        // 실패하면(디스크 부족·중단) 멀쩡하던 백업만 사라졌다. 임시 파일에 다 쓴 뒤
        // 성공했을 때만 교체한다.
        final overwriting = conflictPolicy == 'overwrite' &&
            !usedOutputPaths.contains(outputPath) &&
            File(outputPath).existsSync();
        if (conflictPolicy == 'overwrite' &&
            !usedOutputPaths.contains(outputPath)) {
          // 교체는 아래(성공 후)에서 한다.
        } else {
          // 'rename' (기본값) 또는 이번 배치 내 이름 충돌: 숫자 접미사 추가
          // (overwrite 정책이라도 방금 이 배치에서 만든 파일을 지우면 안 됨)
          var counter = 1;
          while (File(outputPath).existsSync() ||
              usedOutputPaths.contains(outputPath)) {
            fileName = '${safeName}_$counter.mra';
            outputPath = p.join(exportDirPath, fileName);
            counter++;
          }
        }
        usedOutputPaths.add(outputPath);

        final writePath = overwriting ? '$outputPath.tmp' : outputPath;
        await _exportService.exportMemk(
          outputPath: writePath,
          folderIds: [folder.id!],
          onProgress: (progress) {
            double subProgress;
            switch (progress.phase) {
              case 'cards':
                final total = progress.total > 0 ? progress.total : 1;
                subProgress = 0.05 + (progress.current / total) * 0.65;
              case 'images':
                final total = progress.total > 0 ? progress.total : 1;
                subProgress = 0.70 + (progress.current / total) * 0.20;
              case 'zipping':
                subProgress = 0.92;
              case 'done':
                subProgress = 1.0;
              default:
                subProgress = 0.02;
            }
            final overallProgress =
                (folderProgressBase + subProgress * folderWeight)
                    .clamp(0.0, 1.0);
            final msg =
                '${folder.name} (${i + 1}/$totalFolders) - ${progress.message ?? processingMsg}';

            exportProgressValue = overallProgress;
            exportProgressMessage = msg;
            _notify();

            _updateProgress(
              exportTitle,
              msg,
              (overallProgress * 100).round(),
              100,
              type: 'export',
            );
          },
        );

        if (overwriting) {
          // 여기까지 왔다는 건 새 파일이 완성됐다는 뜻 — 이제야 옛 파일을 치운다.
          try { await File(outputPath).delete(); } catch (_) {}
          try {
            await DatabaseHelper.instance.deleteExportedFileByPath(outputPath);
          } catch (_) {}
          await File(writePath).rename(outputPath);
        }

        // exported_files DB 기록 — 크기 조회 실패로 배치를 멈추지 않는다(파일은 이미 만들어졌다).
        final fileSize = await _fileLengthOrZero(outputPath);
        try {
          await DatabaseHelper.instance.insertExportedFile(
            fileName: fileName,
            filePath: outputPath,
            fileSize: fileSize,
            fileType: 'memk',
          );
        } catch (dbErr) {
          debugPrint('[EXPORT] DB record failed: $dbErr');
        }

        createdFiles.add(outputPath);
        createdFileNames.add(fileName);
      }

      lastExportFileNames = createdFileNames;
      lastExportFilePaths = createdFiles;
      isRunning = false;
      currentOperation = null;
      _releaseLock();
      _notify();

      final body = exportCancelled
          ? (isEn
              ? 'Cancelled — ${createdFileNames.length} file(s) were created'
              : '취소됨 — ${createdFileNames.length}개까지 만들었습니다')
          : (isEn
              ? '${createdFileNames.length} file(s) created'
              : '${createdFileNames.length}개 파일 생성');
      await _complete(
        exportCancelled
            ? (isEn ? 'Export cancelled' : 'Export 취소됨')
            : (isEn ? 'Export complete' : 'Export 완료'),
        body,
        type: 'export',
      );
      // 시작은 됐다 — 개별 폴더 실패는 lastExportError로 별도 보고한다.
      return true;
    } catch (e) {
      // 부분 결과 보존 (중간 실패 시 성공한 파일 접근 가능)
      if (createdFileNames.isNotEmpty) {
        lastExportFileNames = List.from(createdFileNames);
        lastExportFilePaths = List.from(createdFiles);
      }
      lastExportError = e;
      isRunning = false;
      currentOperation = null;
      _releaseLock();
      _notify();
      await _cancel();
      return true;
    }
  }

  /// 산출물이 아예 없으면 예외(배치 실패 경로 유지) — 있는데 크기 조회만 실패하면 0(R20-04).
  static Future<int> _fileLengthOrZero(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw FileSystemException('export output missing', path);
    }
    try {
      return await file.length();
    } catch (e) {
      debugPrint('[EXPORT] length() failed for $path: $e');
      return 0;
    }
  }

  // ─── Export (PDF per folder — Android 네이티브) ───

  /// 네이티브 PDF 진행률 수신 (main.dart에서 호출)
  void handleNativePdfProgress(int current, int total, String message) {
    final t = total > 0 ? total : 1;
    final sub = current / t;
    final overall =
        (_pdfFolderBase + sub * _pdfFolderWeight).clamp(0.0, 1.0);
    final msg = '$_pdfCurrentFolderName (${_pdfFolderIndex + 1}/$_pdfTotalFolders) - $message';

    exportProgressValue = overall;
    exportProgressMessage = msg;
    _notify();

    final isEn = LocaleService.currentLanguageCode() == 'en';
    _updateProgress(
      isEn ? 'Exporting' : 'Export 진행 중', msg,
      (overall * 100).round(), 100,
      type: 'export',
    );
  }

  // 네이티브 PDF 진행률 계산용 임시 상태
  double _pdfFolderBase = 0;
  double _pdfFolderWeight = 1;
  int _pdfFolderIndex = 0;
  int _pdfTotalFolders = 1;
  String _pdfCurrentFolderName = '';

  /// 반환값 false = 다른 가져오기/내보내기가 진행 중이라 이번 요청을 무시했다
  /// (규약은 [startImport]와 같다).
  Future<bool> startPdfExport({
    required List<Folder> selectedFolders,
    required String exportDirPath,
    String conflictPolicy = 'rename',
  }) async {
    if (_operationLock != null && !_operationLock!.isCompleted) return false;
    _operationLock = Completer<void>();

    final isEn = LocaleService.currentLanguageCode() == 'en';
    final exportTitle = isEn ? 'Exporting' : 'Export 진행 중';

    _cancelRequested = false;
    isRunning = true;
    currentOperation = 'export';
    clearExportResult();
    exportProgressMessage = isEn ? 'Preparing...' : '준비 중...';
    exportProgressValue = 0.0;
    _notify();

    try { await _startService(exportTitle, type: 'export'); } catch (_) {}

    final createdFiles = <String>[];
    final createdFileNames = <String>[];
    var exportCancelled = false;
    try {
      final totalFolders = selectedFolders.length;
      _pdfTotalFolders = totalFolders;
      // 이번 배치에서 이미 사용(claim)한 출력 경로 — 동일 배치 내 이름 충돌 감지용.
      // .mra per-folder export(#15)와 동일 규칙: 폴더명이 서로 다른데 sanitize 결과가
      // 같으면(`N2/N3` vs `N2_N3`) overwrite 정책이 방금 이 배치에서 만든 PDF를 지워버린다.
      final usedOutputPaths = <String>{};

      for (int i = 0; i < selectedFolders.length; i++) {
        final folder = selectedFolders[i];
        _pdfFolderBase = i / totalFolders;
        _pdfFolderWeight = 1.0 / totalFolders;
        _pdfFolderIndex = i;
        _pdfCurrentFolderName = folder.name;

        final safeName = _sanitizeFileName(folder.name);
        var fileName = '$safeName.pdf';
        var outputPath = p.join(exportDirPath, fileName);
        // .mra 경로와 같은 이유로 임시 파일에 만든 뒤 교체한다(감사 Y4-01).
        final overwriting = conflictPolicy == 'overwrite' &&
            !usedOutputPaths.contains(outputPath) &&
            File(outputPath).existsSync();
        if (conflictPolicy == 'overwrite' &&
            !usedOutputPaths.contains(outputPath)) {
          // 교체는 아래(성공 후)에서 한다.
        } else {
          // 'rename' (기본값) 또는 이번 배치 내 이름 충돌: 숫자 접미사 추가
          var counter = 1;
          while (File(outputPath).existsSync() ||
              usedOutputPaths.contains(outputPath)) {
            fileName = '${safeName}_$counter.pdf';
            outputPath = p.join(exportDirPath, fileName);
            counter++;
          }
        }
        usedOutputPaths.add(outputPath);

        final writePath = overwriting ? '$outputPath.tmp' : outputPath;
        // Android 네이티브 PDF 생성 (Dart VM 힙 사용 안 함).
        // false = 사용자가 중간에 멈췄다. 만들다 만 파일은 네이티브가 지웠으므로
        // 여기선 이 폴더를 결과에 넣지 않고 루프만 빠져나온다.
        final generated = await _channel.invokeMethod<bool>('generatePdf', {
          'outputPath': writePath,
          'folderId': folder.id!,
          'folderIndex': i,
          'totalFolders': totalFolders,
          'resetCancel': i == 0,
        });
        if (generated == false) {
          exportCancelled = true;
          break;
        }

        if (overwriting) {
          try { await File(outputPath).delete(); } catch (_) {}
          try {
            await DatabaseHelper.instance.deleteExportedFileByPath(outputPath);
          } catch (_) {}
          await File(writePath).rename(outputPath);
        }

        // exported_files DB 기록
        final fileSize = await _fileLengthOrZero(outputPath);
        try {
          await DatabaseHelper.instance.insertExportedFile(
            fileName: fileName,
            filePath: outputPath,
            fileSize: fileSize,
            fileType: 'pdf',
          );
        } catch (dbErr) {
          debugPrint('[EXPORT] DB record failed: $dbErr');
        }

        createdFiles.add(outputPath);
        createdFileNames.add(fileName);
      }

      lastExportFileNames = createdFileNames;
      lastExportFilePaths = createdFiles;
      isRunning = false;
      currentOperation = null;
      _releaseLock();
      _notify();

      final body = exportCancelled
          ? (isEn
              ? 'Cancelled — ${createdFileNames.length} file(s) were created'
              : '취소됨 — ${createdFileNames.length}개까지 만들었습니다')
          : (isEn
              ? '${createdFileNames.length} file(s) created'
              : '${createdFileNames.length}개 파일 생성');
      await _complete(
        exportCancelled
            ? (isEn ? 'Export cancelled' : 'Export 취소됨')
            : (isEn ? 'Export complete' : 'Export 완료'),
        body,
        type: 'export',
      );
      // 시작은 됐다 — 개별 폴더 실패는 lastExportError로 별도 보고한다.
      return true;
    } catch (e) {
      if (createdFileNames.isNotEmpty) {
        lastExportFileNames = List.from(createdFileNames);
        lastExportFilePaths = List.from(createdFiles);
      }
      lastExportError = e;
      isRunning = false;
      currentOperation = null;
      _releaseLock();
      _notify();
      await _cancel();
      return true;
    }
  }
}
