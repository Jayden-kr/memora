import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../database/database_helper.dart';
import '../l10n/app_localizations.dart';
import '../services/import_export_controller.dart';
import '../widgets/overwrite_dialog.dart';
import 'import_screen.dart';

/// 여러 .mra/.memk 파일 일괄 임포트 화면.
/// 사용자가 multi-select로 N>1개 파일을 고른 경우 진입.
/// - 체크된 파일: "새 폴더로" 일괄 임포트 (충돌 시 한 번만 정책 선택)
/// - 체크 해제한 파일: batch 종료 후 개별 ImportScreen으로 한 개씩 진행
class MultiImportScreen extends StatefulWidget {
  final List<String> filePaths;

  const MultiImportScreen({super.key, required this.filePaths});

  @override
  State<MultiImportScreen> createState() => _MultiImportScreenState();
}

enum _Stage { loading, picking, importing, done }

class _FileEntry {
  final String filePath;
  final String fileName;
  List<Map<String, dynamic>>? folders;
  int totalCards = 0;
  String? error;
  // 임포트 결과 (batch 완료 후)
  int newCards = 0;
  int newFolders = 0;
  int mergedFolders = 0;

  _FileEntry(this.filePath) : fileName = p.basename(filePath);
}

class _MultiImportScreenState extends State<MultiImportScreen> {
  final _controller = ImportExportController.instance;

  _Stage _stage = _Stage.loading;
  final List<_FileEntry> _files = [];
  final Set<String> _checked = {};

  int _currentFileIdx = 0;
  String _currentFileName = '';

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerUpdate);
    _loadMetadata();
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerUpdate);
    // 진행 중이면 cache 보존 (남은 파일이 cache hit해야 추가 ZIP decode 안 함).
    // 진행 끝났으면 비움.
    if (!_controller.isRunning) {
      _controller.importService.clearCache();
    }
    super.dispose();
  }

  void _onControllerUpdate() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _loadMetadata() async {
    for (final path in widget.filePaths) {
      final entry = _FileEntry(path);
      try {
        // 파일마다 아카이브를 물고 있지 않는다 — 이유는 readFolderList 문서 참고(감사 D7-02).
        final folders = await _controller.importService
            .readFolderList(path, cacheArchive: false);
        entry.folders = folders;
        entry.totalCards = folders.fold<int>(
          0,
          (sum, f) => sum + ((f['cardCount'] as int?) ?? 0),
        );
      } catch (e) {
        entry.error = e.toString();
      }
      if (!mounted) return;
      _files.add(entry);
      // 읽기 성공한 파일만 기본 체크
      if (entry.error == null && (entry.folders?.isNotEmpty ?? false)) {
        _checked.add(entry.filePath);
      }
    }
    if (!mounted) return;
    setState(() => _stage = _Stage.picking);
  }

  List<_FileEntry> get _batchEntries =>
      _files.where((e) => _checked.contains(e.filePath)).toList();

  List<_FileEntry> get _customEntries =>
      _files.where((e) => !_checked.contains(e.filePath) && e.error == null).toList();

  /// '시작' 연타 가드. 아래 _startImpl의 isRunning 검사는 폴더 스캔·충돌 다이얼로그를
  /// 지나서야 startImport가 락을 잡으므로(check-then-act) 두 번째 탭을 못 막았다 —
  /// 2차 startImport가 락에서 무음 no-op하고 lastImportResult 없이 "완료 0장"을 띄웠다.
  bool _starting = false;

  Future<void> _start() async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      await _startImpl();
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _startImpl() async {
    final t = AppLocalizations.of(context);

    // 다른 import/export가 이미 실행 중이면 (백그라운드 계속 진행 설계상)
    // batch loop 진입 자체를 막는다. 안 막으면 startImport가 락에 걸려
    // 조용히 no-op하고, 루프는 stale lastImportResult를 모든 파일에
    // 잘못 귀속시켜 가짜 성공 화면을 띄운다 (ImportScreen._startImport와 동일 가드).
    if (_controller.isBusy) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.importBusy)),
        );
      }
      return;
    }

    final batch = _batchEntries;
    final custom = _customEntries;

    String conflictPolicy = 'merge';

    // batch가 있으면 충돌 검사 후 정책 선택
    if (batch.isNotEmpty) {
      final conflictNames = <String>{};
      for (final entry in batch) {
        for (final f in entry.folders ?? const []) {
          final name = (f['name'] as String?) ?? '';
          if (name.isEmpty) continue;
          final existing =
              await DatabaseHelper.instance.getNonBundleFolderByName(name);
          if (existing != null) conflictNames.add(name);
        }
      }
      if (!mounted) return;

      if (conflictNames.isNotEmpty) {
        final list = conflictNames.toList();
        final preview = list.length <= 3
            ? list.join(', ')
            : '${list.take(3).join(', ')} ${t.exportConflictPreviewSuffix(list.length - 3)}';
        final action = await showOverwriteDialog(
          context: context,
          title: t.importConflictTitle,
          message: t.exportConflictMessage(preview),
          options: [
            OverwriteOption(
              icon: Icons.layers_outlined,
              title: t.importMergeTitle,
              subtitle: t.importMergeSubtitle,
              value: 'merge',
              accent: true,
            ),
            OverwriteOption(
              icon: Icons.create_new_folder_outlined,
              title: t.importRenameTitle,
              subtitle: t.importRenameSubtitle,
              value: 'rename',
            ),
          ],
        );
        if (action == null || action == 'cancel') return;
        conflictPolicy = action;
      }

      if (!mounted) return;
      setState(() => _stage = _Stage.importing);

      // ⚡ for-loop을 widget life와 분리: !mounted return 제거.
      //    widget destroy 시에도 controller가 batch import 끝까지 진행.
      //    UI 갱신만 mounted 가드 (setState만 widget life 의존).
      // 배치 구간은 FGS를 한 번만 띄우고 완료 알림도 합계로 한 번 — 파일마다 껐다 켜면
      // 앱이 뒤로 물러난 뒤 두 번째 파일부터 배경 FGS 시작이 막힐 수 있다(X1-03/X1-06).
      _controller.beginImportBatch();
      try {
        for (var i = 0; i < batch.length; i++) {
          final entry = batch[i];
          if (mounted) {
            setState(() {
              _currentFileIdx = i + 1;
              _currentFileName = entry.fileName;
            });
          }
          try {
            final allFolderNames = (entry.folders ?? const [])
                .map((f) => (f['name'] as String?) ?? '')
                .where((s) => s.isNotEmpty)
                .toList();
            await _controller.startImport(
              filePath: entry.filePath,
              selectedFolderNames: allFolderNames,
              folderMapping: null,
              conflictPolicy: conflictPolicy,
            );
            final result = _controller.lastImportResult;
            if (result != null) {
              entry.newCards = result.newCards;
              entry.newFolders = result.newFolders;
              entry.mergedFolders = result.mergedFolders;
            }
          } catch (e) {
            entry.error = e.toString();
          }
        }
      } finally {
        await _controller.endImportBatch();
      }
    }

    if (!mounted) return;
    setState(() => _stage = _Stage.done);

    // 체크 해제된 파일은 개별 ImportScreen으로 순차 진행
    if (custom.isNotEmpty) {
      for (final entry in custom) {
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ImportScreen(filePath: entry.filePath),
          ),
        );
      }
    }
    // 여기서 바로 pop하지 않는다 — 예전엔 setState(done) 직후 await 없이 pop해 완료 요약
    // 화면(_buildDone: 새 카드/폴더/병합 수)이 한 프레임도 그려지지 않았다. 사용자가
    // 요약을 보고 '확인'으로 나간다.
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return PopScope(
      // batch loop은 위젯 생명주기와 분리되어 있어 (dispose 후에도 controller가
      // 끝까지 진행, line 170-172 주석 참고) importing 중에도 뒤로 가기를 막을
      // 필요가 없다 — 막으면 화면에 보여주는 importBackgroundNote 문구
      // ("뒤로 가기를 눌러도 백그라운드에서 계속 진행됩니다")와 모순된다.
      canPop: true,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.multiImportTitle(_files.length)),
          leading: _stage == _Stage.importing
              ? null
              : IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
        ),
        body: switch (_stage) {
          _Stage.loading => _buildLoading(t),
          _Stage.picking => _buildPicking(t),
          _Stage.importing => _buildImporting(t),
          _Stage.done => _buildDone(t),
        },
      ),
    );
  }

  Widget _buildLoading(AppLocalizations t) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(t.multiImportLoading),
        ],
      ),
    );
  }

  Widget _buildPicking(AppLocalizations t) {
    final batchCount = _batchEntries.length;
    final customCount = _customEntries.length;
    final canStart = batchCount > 0 || customCount > 0;

    final String label;
    if (batchCount > 0 && customCount > 0) {
      label = t.multiImportButtonMixed(batchCount, customCount);
    } else if (batchCount > 0) {
      label = t.multiImportButtonBatchOnly(batchCount);
    } else {
      label = t.multiImportButtonCustomOnly(customCount);
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Icon(Icons.info_outline,
                  size: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  t.multiImportHelp,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color:
                            Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _files.length,
            itemBuilder: (context, idx) {
              final e = _files[idx];
              final isChecked = _checked.contains(e.filePath);
              final hasError = e.error != null;
              final hasNoFolders =
                  !hasError && (e.folders?.isEmpty ?? true);
              final cs = Theme.of(context).colorScheme;
              final summary = hasError
                  ? null
                  : t.multiImportFolderCardSummary(
                      e.folders?.length ?? 0,
                      e.totalCards,
                    );
              final showCustomHint =
                  !isChecked && !hasError && !hasNoFolders;

              return CheckboxListTile(
                value: isChecked,
                onChanged: (hasError || hasNoFolders)
                    ? null
                    : (v) {
                        setState(() {
                          if (v == true) {
                            _checked.add(e.filePath);
                          } else {
                            _checked.remove(e.filePath);
                          }
                        });
                      },
                title: Text(
                  e.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: hasError ? cs.error : null,
                  ),
                ),
                subtitle: hasError
                    ? Text(t.multiImportReadFail,
                        style: TextStyle(color: cs.error))
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(summary ?? ''),
                          if (showCustomHint)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                '→ ${t.multiImportRowCustomHint}',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: cs.primary,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                            ),
                        ],
                      ),
                dense: true,
              );
            },
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: (canStart && !_starting) ? _start : null,
                child: Text(label),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildImporting(AppLocalizations t) {
    final progress = _controller.currentImportProgress;
    final cardProg = progress.totalCards > 0
        ? progress.currentCards / progress.totalCards
        : 0.0;
    final imageProg = progress.totalImages > 0
        ? progress.currentImages / progress.totalImages
        : 0.0;
    final fileProg = progress.phase == 'images'
        ? (cardProg + imageProg) / 2
        : cardProg * 0.5;

    final batchTotal = _batchEntries.length;
    // 전체 진행률: 완료된 파일 + 현재 파일 내부 진행률
    final overall = batchTotal > 0
        ? ((_currentFileIdx - 1) + fileProg.clamp(0.0, 1.0)) / batchTotal
        : 0.0;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(value: overall.clamp(0.0, 1.0)),
            const SizedBox(height: 16),
            Text(
              t.multiImportProgressFile(_currentFileIdx, batchTotal),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              _currentFileName,
              style: Theme.of(context).textTheme.bodyMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            Text(
              progress.message ?? t.importProcessing,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Text(
              t.importBackgroundNote,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDone(AppLocalizations t) {
    final batch = _batchEntries;
    final totalNewCards = batch.fold<int>(0, (s, e) => s + e.newCards);
    final totalNewFolders = batch.fold<int>(0, (s, e) => s + e.newFolders);
    final totalMerged = batch.fold<int>(0, (s, e) => s + e.mergedFolders);

    final custom = _customEntries;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle,
                size: 64, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(t.multiImportDoneTitle,
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 24),
            _row(t.importDoneNewCards, t.cardCountSuffix(totalNewCards)),
            _row(t.importDoneNewFolders,
                t.folderCountSuffix(totalNewFolders)),
            _row(t.importDoneMerged, t.folderCountSuffix(totalMerged)),
            const SizedBox(height: 24),
            if (custom.isNotEmpty)
              Text(
                t.multiImportContinueCustom(custom.length),
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t.commonOk),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyLarge),
          Text(value,
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
