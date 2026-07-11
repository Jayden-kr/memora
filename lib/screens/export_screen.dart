import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart' show Share, XFile;

import '../database/database_helper.dart';
import '../l10n/app_localizations.dart';
import '../models/folder.dart';
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

  @override
  void initState() {
    super.initState();
    ExportScreen.isOpen = true;
    _controller.addListener(_onControllerUpdate);

    if (_isExporting || widget.progressOnly) {
      // 이미 진행 중이거나 알림 탭으로 열린 경우 — 폴더 로딩 불필요
      _loading = false;
    } else {
      // 새 Export 화면: 이전 결과 정리 (재진입 시 이전 완료 다이얼로그 방지)
      _controller.clearExportResult();
      _loadFolders();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
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
    if (_controller.isRunning) {
      final t = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.importBusy)),
      );
      return;
    }

    final appDocDir = await getApplicationDocumentsDirectory();
    final exportDir = Directory('${appDocDir.path}/exports');
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

    if (_fileType == 'memk') {
      _controller.startMemkPerFolderExport(
        selectedFolders: selectedFolders,
        exportDirPath: exportDir.path,
        conflictPolicy: conflictPolicy,
      );
    } else {
      _controller.startPdfExport(
        selectedFolders: selectedFolders,
        exportDirPath: exportDir.path,
        conflictPolicy: conflictPolicy,
      );
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
                              title: Text(folder.name),
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
