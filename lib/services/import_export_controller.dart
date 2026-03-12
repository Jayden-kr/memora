import 'dart:async';

import 'package:flutter/services.dart';

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

  // 동시 실행 방지 락
  Completer<void>? _operationLock;

  // 상태
  bool isRunning = false;
  String? currentOperation; // 'import' or 'export'
  ImportResult? lastImportResult;
  ImportProgress currentImportProgress = const ImportProgress();

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

  Future<void> _startService(String title) async {
    try {
      await _channel.invokeMethod('startService', {'title': title});
    } catch (_) {}
  }

  Future<void> _updateProgress(
      String title, String message, int progress, int max) async {
    try {
      await _channel.invokeMethod('updateProgress', {
        'title': title,
        'message': message,
        'progress': progress,
        'max': max,
      });
    } catch (_) {}
  }

  Future<void> _complete(String title, String message) async {
    try {
      await _channel.invokeMethod('complete', {
        'title': title,
        'message': message,
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

    await _startService('Import 진행 중');

    try {
      final result = await _importService.importSelectedFolders(
        filePath: filePath,
        selectedFolderNames: selectedFolderNames,
        folderMapping: folderMapping,
        onProgress: (progress) {
          currentImportProgress = progress;
          _notify();

          // 알림 업데이트 (너무 자주 안 보내도록)
          final total = progress.totalCards > 0 ? progress.totalCards : 1;
          final current = progress.currentCards;
          _updateProgress(
            'Import 진행 중',
            progress.message ?? '처리 중...',
            current,
            total,
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

  // ─── Export ───

  Future<void> startExport({
    required String outputPath,
    List<int>? folderIds,
  }) async {
    if (_operationLock != null && !_operationLock!.isCompleted) return;
    _operationLock = Completer<void>();

    isRunning = true;
    currentOperation = 'export';
    _notify();

    await _startService('Export 진행 중');

    try {
      await _exportService.exportMemk(
        outputPath: outputPath,
        folderIds: folderIds,
        onProgress: (progress) {
          _notify();

          final total = progress.total > 0 ? progress.total : 1;
          _updateProgress(
            'Export 진행 중',
            progress.message ?? '처리 중...',
            progress.current,
            total,
          );
        },
      );

      isRunning = false;
      currentOperation = null;
      _operationLock?.complete();
      _notify();

      await _complete('Export 완료', '파일이 생성되었습니다.');
    } catch (e) {
      isRunning = false;
      currentOperation = null;
      _operationLock?.complete();
      _notify();
      await _cancel();
      rethrow;
    }
  }
}
