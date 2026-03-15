import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../database/database_helper.dart';
import '../models/folder.dart';
import '../services/memk_import_service.dart';
import '../services/memk_export_service.dart';

/// Import/Export 백그라운드 처리 + 알림 관리 컨트롤러 (싱글톤)
class ImportExportController {
  static final instance = ImportExportController._();
  ImportExportController._();

  static const _channel =
      MethodChannel('com.henry.amki_wang/import_export');

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

  /// 진행 중인 작업을 강제 취소 (OOM/stuck 복구용)
  void forceCancel() {
    if (!isRunning) return;
    isRunning = false;
    currentOperation = null;
    if (_operationLock != null && !_operationLock!.isCompleted) {
      _operationLock!.complete();
    }
    clearExportResult();
    _cancel();
    _notify();
  }

  /// 앱 시작 시 잔여 상태 정리
  void cleanupStaleState() {
    if (isRunning) forceCancel();
    _cancel(); // 잔여 foreground service 알림 제거
  }

  // 리스너 (UI 갱신용)
  final List<void Function()> _listeners = [];

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);
  void _notify() {
    for (final l in List.of(_listeners)) {
      l();
    }
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

  Future<void> startImport({
    required String filePath,
    required List<String> selectedFolderNames,
    Map<int, int?>? folderMapping,
  }) async {
    // 동시 실행 방지 (Completer 기반 락)
    if (_operationLock != null && !_operationLock!.isCompleted) return;
    _operationLock = Completer<void>();

    isRunning = true;
    currentOperation = 'import';
    lastImportResult = null;
    currentImportProgress = const ImportProgress();
    _notify();

    try {
      await _startService('Import 진행 중');
    } catch (_) {}

    try {
      final result = await _importService.importSelectedFolders(
        filePath: filePath,
        selectedFolderNames: selectedFolderNames,
        folderMapping: folderMapping,
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
            'Import 진행 중',
            progress.message ?? '처리 중...',
            (combined * 100).round(),
            100,
          );
        },
      );

      lastImportResult = result;
      isRunning = false;
      currentOperation = null;
      _operationLock?.complete();
      _notify();

      await _complete(
        'Import 완료',
        '${result.newCards}장 가져옴 (${result.duration.inSeconds}초)',
      );
    } catch (e) {
      isRunning = false;
      currentOperation = null;
      _operationLock?.complete();
      _notify();
      await _cancel();
      rethrow;
    }
  }

  // ─── Export (Memk per folder) ───

  static String _sanitizeFileName(String name) {
    final sanitized =
        name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
    return sanitized.isEmpty ? 'export' : sanitized;
  }

  Future<void> startMemkPerFolderExport({
    required List<Folder> selectedFolders,
    required String exportDirPath,
  }) async {
    if (_operationLock != null && !_operationLock!.isCompleted) return;
    _operationLock = Completer<void>();

    isRunning = true;
    currentOperation = 'export';
    clearExportResult();
    exportProgressMessage = '준비 중...';
    exportProgressValue = 0.0;
    _notify();

    try { await _startService('Export 진행 중', type: 'export'); } catch (_) {}

    final createdFiles = <String>[];
    final createdFileNames = <String>[];
    try {
      final totalFolders = selectedFolders.length;

      for (int i = 0; i < selectedFolders.length; i++) {
        final folder = selectedFolders[i];
        final folderProgressBase = i / totalFolders;
        final folderWeight = 1.0 / totalFolders;

        final safeName = _sanitizeFileName(folder.name);
        // 파일명 충돌 방지: 동일 이름 존재 시 숫자 접미사 추가
        var fileName = '$safeName.memk';
        var outputPath = p.join(exportDirPath, fileName);
        var counter = 1;
        while (File(outputPath).existsSync()) {
          fileName = '${safeName}_$counter.memk';
          outputPath = p.join(exportDirPath, fileName);
          counter++;
        }

        await _exportService.exportMemk(
          outputPath: outputPath,
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
                '${folder.name} (${i + 1}/$totalFolders) - ${progress.message ?? "처리 중..."}';

            exportProgressValue = overallProgress;
            exportProgressMessage = msg;
            _notify();

            _updateProgress(
              'Export 진행 중',
              msg,
              (overallProgress * 100).round(),
              100,
              type: 'export',
            );
          },
        );

        // exported_files DB 기록
        final file = File(outputPath);
        final fileSize = await file.length();
        try {
          await DatabaseHelper.instance.insertExportedFile(
            fileName: fileName,
            filePath: outputPath,
            fileSize: fileSize,
            fileType: 'memk',
          );
        } catch (dbErr) {
          debugPrint('[EXPORT] DB 기록 실패: $dbErr');
        }

        createdFiles.add(outputPath);
        createdFileNames.add(fileName);
      }

      lastExportFileNames = createdFileNames;
      lastExportFilePaths = createdFiles;
      isRunning = false;
      currentOperation = null;
      _operationLock?.complete();
      _notify();

      await _complete(
        'Export 완료',
        '${createdFileNames.length}개 파일 생성',
        type: 'export',
      );
    } catch (e) {
      // 부분 결과 보존 (중간 실패 시 성공한 파일 접근 가능)
      if (createdFileNames.isNotEmpty) {
        lastExportFileNames = List.from(createdFileNames);
        lastExportFilePaths = List.from(createdFiles);
      }
      lastExportError = e;
      isRunning = false;
      currentOperation = null;
      _operationLock?.complete();
      _notify();
      await _cancel();
    }
  }

  // ─── Export (PDF per folder — Android 네이티브) ───

  /// 네이티브 PDF 진행률 수신 (main.dart에서 호출)
  void handleNativePdfProgress(int current, int total, String message) {
    final t = total > 0 ? total : 1;
    // 현재 폴더의 진행률을 전체 진행률에 반영
    final sub = current / t;
    final overall =
        (_pdfFolderBase + sub * _pdfFolderWeight).clamp(0.0, 1.0);
    final msg = '$_pdfCurrentFolderName (${_pdfFolderIndex + 1}/$_pdfTotalFolders) - $message';

    exportProgressValue = overall;
    exportProgressMessage = msg;
    _notify();

    _updateProgress(
      'Export 진행 중', msg,
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

  Future<void> startPdfExport({
    required List<Folder> selectedFolders,
    required String exportDirPath,
  }) async {
    if (_operationLock != null && !_operationLock!.isCompleted) return;
    _operationLock = Completer<void>();

    isRunning = true;
    currentOperation = 'export';
    clearExportResult();
    exportProgressMessage = '준비 중...';
    exportProgressValue = 0.0;
    _notify();

    try { await _startService('Export 진행 중', type: 'export'); } catch (_) {}

    final createdFiles = <String>[];
    final createdFileNames = <String>[];
    try {
      final totalFolders = selectedFolders.length;
      _pdfTotalFolders = totalFolders;

      for (int i = 0; i < selectedFolders.length; i++) {
        final folder = selectedFolders[i];
        _pdfFolderBase = i / totalFolders;
        _pdfFolderWeight = 1.0 / totalFolders;
        _pdfFolderIndex = i;
        _pdfCurrentFolderName = folder.name;

        final safeName = _sanitizeFileName(folder.name);
        // 파일명 충돌 방지: 동일 이름 존재 시 숫자 접미사 추가 (memk와 동일 패턴)
        var fileName = '$safeName.pdf';
        var outputPath = p.join(exportDirPath, fileName);
        var counter = 1;
        while (File(outputPath).existsSync()) {
          fileName = '${safeName}_$counter.pdf';
          outputPath = p.join(exportDirPath, fileName);
          counter++;
        }

        // Android 네이티브 PDF 생성 (Dart VM 힙 사용 안 함)
        await _channel.invokeMethod('generatePdf', {
          'outputPath': outputPath,
          'folderId': folder.id!,
          'folderIndex': i,
          'totalFolders': totalFolders,
        });

        // exported_files DB 기록
        final file = File(outputPath);
        final fileSize = await file.length();
        try {
          await DatabaseHelper.instance.insertExportedFile(
            fileName: fileName,
            filePath: outputPath,
            fileSize: fileSize,
            fileType: 'pdf',
          );
        } catch (dbErr) {
          debugPrint('[EXPORT] DB 기록 실패: $dbErr');
        }

        createdFiles.add(outputPath);
        createdFileNames.add(fileName);
      }

      lastExportFileNames = createdFileNames;
      lastExportFilePaths = createdFiles;
      isRunning = false;
      currentOperation = null;
      _operationLock?.complete();
      _notify();

      await _complete(
        'Export 완료',
        '${createdFileNames.length}개 파일 생성',
        type: 'export',
      );
    } catch (e) {
      if (createdFileNames.isNotEmpty) {
        lastExportFileNames = List.from(createdFileNames);
        lastExportFilePaths = List.from(createdFiles);
      }
      lastExportError = e;
      isRunning = false;
      currentOperation = null;
      _operationLock?.complete();
      _notify();
      await _cancel();
    }
  }
}
