import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart' show Share, XFile;

import '../database/database_helper.dart';
import '../l10n/app_localizations.dart';
import '../models/folder.dart';
import '../utils/folder_label.dart';
import '../utils/constants.dart';
import '../services/import_export_controller.dart';
import '../widgets/overwrite_dialog.dart';

class ExportScreen extends StatefulWidget {
  final List<int>? initialFolderIds;
  final bool progressOnly;
  static bool isOpen = false;

  const ExportScreen({
    super.key,
    this.initialFolderIds,
    this.progressOnly = false,
  });

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  final _controller = ImportExportController.instance;

  List<Folder> _folders = [];
  final Set<int> _selectedFolderIds = {};
  String _fileType = 'memk';
  bool _loading = true;

  bool get _isExporting =>
      _controller.isRunning && _controller.currentOperation == 'export';

  /// 지난 실행의 내보내기 실패를 이 화면이 뜬 뒤 한 번 보여주기 위해 잠깐 들고 있는다.
  Object? _pendingExportError;

  @override
  void initState() {
    super.initState();
    ExportScreen.isOpen = true;
    _controller.addListener(_onControllerUpdate);

    if (_isExporting || widget.progressOnly) {
      // 이미 진행 중이거나 알림 탭으로 열린 경우 — 폴더 로딩 불필요
      _loading = false;
    } else {
      // 새 Export 화면: 이전 결과 정리 (재진입 시 이전 완료 다이얼로그 방지).
      // 다만 지난 내보내기가 파일 하나 없이 실패로 끝났다면 그 사실은 한 번은 보여주고
      // 지운다 — 예전엔 메뉴로 이 화면을 열면 여기서 조용히 지워져서, 사용자가 실패를
      // 영영 모른 채 "내보냈는데 파일이 없다"만 겪었다.
      if (_controller.lastExportFileNames == null) {
        _pendingExportError = _controller.lastExportError;
      }
      _controller.clearExportResult();
      _loadFolders();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pending = _pendingExportError;
      _pendingExportError = null;
      if (pending != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                AppLocalizations.of(context).exportFailSnack(pending.toString())),
          ),
        );
      }
      _checkExportResult();
    });
  }

  @override
  void dispose() {
    ExportScreen.isOpen = false;
    _controller.removeListener(_onControllerUpdate);
    super.dispose();
  }

  void _onControllerUpdate() {
    if (!mounted) return;
    setState(() {});

    // export 완료/에러 체크
    if (!_controller.isRunning && _controller.currentOperation == null) {
      // 화면이 export 진행 중에 열려 initState에서 _loadFolders를 건너뛴
      // 경우 (line 46) — 여기서 뒤늦게 로드해서 "내보낼 폴더 없음" 오표시 방지.
      if (_folders.isEmpty && !widget.progressOnly) _loadFolders();
      _checkExportResult();
    }
  }

  void _checkExportResult() {
    if (!mounted) return;

    if (_controller.lastExportFileNames != null) {
      // 파일이 하나라도 생성됐으면 완료 다이얼로그로 안내 (중간 실패로
      // lastExportError도 함께 설정된 부분 성공 케이스 포함 — 그렇지 않으면
      // 컨트롤러가 보존한 부분 결과가 여기서 그냥 버려진다).
      _showCompletionDialog();
    } else if (_controller.lastExportError != null) {
      final error = _controller.lastExportError;
      _controller.clearExportResult();
      final t = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.exportFailSnack(error.toString()))),
      );
      if (widget.progressOnly) Navigator.pop(context);
    } else if (widget.progressOnly && !_isExporting) {
      // 알림 탭했으나 결과도 진행도 없음 — 뒤로
      Navigator.pop(context);
    }
  }

  Future<void> _showCompletionDialog() async {
    final fileNames = List<String>.from(_controller.lastExportFileNames!);
    final filePaths = List<String>.from(_controller.lastExportFilePaths!);
    // clearExportResult로 지워지기 전에 부분 실패 여부를 먼저 읽어둔다 —
    // 중간 실패 시에도 이미 만들어진 파일은 공유 가능하게 보여준다.
    final partialError = _controller.lastExportError;
    _controller.clearExportResult();
    final t = AppLocalizations.of(context);
    final body = partialError == null
        ? t.exportDoneBody(fileNames.length, fileNames.join('\n'))
        : '${t.exportDoneBody(fileNames.length, fileNames.join('\n'))}\n\n'
            '${t.exportFailSnack(partialError.toString())}';

    final shouldShare = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.exportDoneTitle),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.commonOk),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.share),
            label: Text(t.exportShare),
          ),
        ],
      ),
    );

    if (shouldShare == true) {
      try {
        await Share.shareXFiles(
            filePaths.map((path) => XFile(path)).toList());
      } catch (e) {
        debugPrint('[EXPORT] share failed: $e');
      }
    }

    if (!mounted) return;
    Navigator.pop(context);
  }

  Future<void> _loadFolders() async {
    final folders = await DatabaseHelper.instance.getNonBundleFolders();
    if (!mounted) return;
    setState(() {
      _folders = folders;
      if (widget.initialFolderIds != null) {
        _selectedFolderIds.addAll(
          widget.initialFolderIds!.where(
            (id) => folders.any((f) => f.id == id),
          ),
        );
      }
      _loading = false;
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selectedFolderIds.length == _folders.length) {
        _selectedFolderIds.clear();
      } else {
        _selectedFolderIds.addAll(_folders.where((f) => f.id != null).map((f) => f.id!));
      }
    });
  }

  Future<void> _export() async {
    if (_isExporting || _selectedFolderIds.isEmpty) return;

    // import 등 export가 아닌 다른 작업이 실행 중이면 startXxxExport의
    // operationLock 체크에서 조용히 no-op한다 — 디렉토리 생성/충돌 다이얼로그를
    // 다 거치고 나서야 아무 일도 안 일어나는 것을 막기 위해 여기서 먼저 차단.
    // isBusy: 다중 import 배치의 파일 사이 틈도 막는다 — 그 틈에 시작한 export는 배치 종료의
    // STOP에 FGS를 빼앗겼다(R20-01).
    if (_controller.isBusy) {
      final t = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.importBusy)),
      );
      return;
    }

    final appDocDir = await getApplicationDocumentsDirectory();
    final exportDir =
        Directory(p.join(appDocDir.path, AppConstants.exportDir));
    if (!await exportDir.exists()) {
      await exportDir.create(recursive: true);
    }

    final selectedFolders =
        _folders.where((f) => _selectedFolderIds.contains(f.id)).toList();

    // 동일 이름 파일 충돌 감지
    final ext = _fileType == 'memk' ? '.mra' : '.pdf';
    final conflictNames = <String>[];
    for (final folder in selectedFolders) {
      final safeName = _sanitizeForExport(folder.name);
      final candidate = p.join(exportDir.path, '$safeName$ext');
      if (File(candidate).existsSync()) {
        conflictNames.add('$safeName$ext');
      }
    }

    String conflictPolicy = 'rename';
    if (conflictNames.isNotEmpty) {
      if (!mounted) return;
      final t = AppLocalizations.of(context);
      final preview = conflictNames.length <= 3
          ? conflictNames.join(', ')
          : '${conflictNames.take(3).join(', ')} ${t.exportConflictPreviewSuffix(conflictNames.length - 3)}';
      final action = await showOverwriteDialog(
        context: context,
        title: t.exportConflictTitle,
        message: t.exportConflictMessage(preview),
        options: [
          OverwriteOption(
            icon: Icons.refresh,
            title: t.commonOverwrite,
            subtitle: t.exportOverwriteSubtitle,
            value: 'overwrite',
            accent: true,
          ),
          OverwriteOption(
            icon: Icons.add_circle_outline,
            title: t.exportRenameNew,
            subtitle: t.exportRenameSubtitle,
            value: 'rename',
          ),
        ],
      );
      if (action == null || action == 'cancel') return;
      conflictPolicy = action;
    }

    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final busyMessage = AppLocalizations.of(context).opBusyIgnored;
    final started = _fileType == 'memk'
        ? await _controller.startMemkPerFolderExport(
            selectedFolders: selectedFolders,
            exportDirPath: exportDir.path,
            conflictPolicy: conflictPolicy,
          )
        : await _controller.startPdfExport(
            selectedFolders: selectedFolders,
            exportDirPath: exportDir.path,
            conflictPolicy: conflictPolicy,
          );
    // 다른 작업이 진행 중이면 컨트롤러가 조용히 무시한다 — 버튼이 먹통인 것처럼
    // 보이지 않게 이유를 알린다.
    if (!started) {
      messenger.showSnackBar(SnackBar(content: Text(busyMessage)));
    }
  }

  /// Controller의 _sanitizeFileName과 동일 로직 — 충돌 감지용으로 미리 적용
  static String _sanitizeForExport(String name) {
    final sanitized =
        name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
    return sanitized.isEmpty ? 'export' : sanitized;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.exportTitle),
        actions: [
          if (!_isExporting && !widget.progressOnly)
            TextButton(
              onPressed: _selectedFolderIds.isEmpty ? null : _export,
              child: Text(t.exportGenerate),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _isExporting
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 24),
                        LinearProgressIndicator(
                            value: _controller.exportProgressValue),
                        const SizedBox(height: 12),
                        Text(_controller.exportProgressMessage),
                        Text(
                          '${(_controller.exportProgressValue * 100).toInt()}%',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 24),
                        // PDF는 카드 경계에서 멈추고 만들다 만 파일은 네이티브가 지운다.
                        if (_controller.isCancelRequested)
                          Text(
                            t.opCancelling,
                            style: Theme.of(context).textTheme.bodySmall,
                            textAlign: TextAlign.center,
                          )
                        else
                          OutlinedButton.icon(
                            onPressed: () => _controller.requestCancel(),
                            icon: const Icon(Icons.stop_circle_outlined),
                            label: Text(t.opCancelButton),
                          ),
                      ],
                    ),
                  ),
                )
              : widget.progressOnly
                  ? const Center(child: CircularProgressIndicator())
                  : SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 폴더 선택
                          Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
                            child: Row(
                              children: [
                                Text(t.exportFolderPick,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                                const Spacer(),
                                TextButton(
                                  onPressed: _toggleSelectAll,
                                  child: Text(
                                      _selectedFolderIds.length ==
                                              _folders.length
                                          ? t.homeDeselectAll
                                          : t.homeSelectAll),
                                ),
                              ],
                            ),
                          ),
                          if (_folders.isEmpty)
                            Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(t.exportNoExportable),
                            ),
                          ..._folders.map((folder) {
                            return CheckboxListTile(
                              title: Text(folderDisplayPath(folder)),
                              subtitle: Text(t.cardCountSuffix(folder.cardCount)),
                              value:
                                  _selectedFolderIds.contains(folder.id),
                              onChanged: (checked) {
                                if (folder.id == null) return;
                                setState(() {
                                  if (checked == true) {
                                    _selectedFolderIds.add(folder.id!);
                                  } else {
                                    _selectedFolderIds.remove(folder.id!);
                                  }
                                });
                              },
                            );
                          }),

                          const Divider(height: 32),

                          // 파일 형식
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 16),
                            child: Text(t.exportFileType,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium),
                          ),
                          RadioGroup<String>(
                            groupValue: _fileType,
                            onChanged: (v) =>
                                setState(() => _fileType = v ?? _fileType),
                            child: Column(
                              children: [
                                RadioListTile<String>(
                                  title: const Text('.mra'),
                                  subtitle: Text(t.exportFileTypeMra),
                                  value: 'memk',
                                ),
                                RadioListTile<String>(
                                  title: const Text('PDF'),
                                  subtitle: Text(t.exportFileTypePdfDesc),
                                  value: 'pdf',
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
    );
  }
}
