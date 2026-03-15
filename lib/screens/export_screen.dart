import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart' show Share, XFile;

import '../database/database_helper.dart';
import '../models/folder.dart';
import '../services/import_export_controller.dart';

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
      _checkExportResult();
    }
  }

  void _checkExportResult() {
    if (!mounted) return;

    if (_controller.lastExportError != null) {
      final error = _controller.lastExportError;
      _controller.clearExportResult();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('내보내기 실패: $error')),
      );
      if (widget.progressOnly) Navigator.pop(context);
    } else if (_controller.lastExportFileNames != null) {
      _showCompletionDialog();
    } else if (widget.progressOnly && !_isExporting) {
      // 알림 탭했으나 결과도 진행도 없음 — 뒤로
      Navigator.pop(context);
    }
  }

  Future<void> _showCompletionDialog() async {
    final fileNames = List<String>.from(_controller.lastExportFileNames!);
    final filePaths = List<String>.from(_controller.lastExportFilePaths!);
    _controller.clearExportResult();

    final shouldShare = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('내보내기 완료'),
        content: Text(
          '${fileNames.length}개 파일이 생성되었습니다.\n\n${fileNames.join('\n')}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('확인'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.share),
            label: const Text('공유'),
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

    final appDocDir = await getApplicationDocumentsDirectory();
    final exportDir = Directory('${appDocDir.path}/exports');
    if (!await exportDir.exists()) {
      await exportDir.create(recursive: true);
    }

    final selectedFolders =
        _folders.where((f) => _selectedFolderIds.contains(f.id)).toList();

    if (_fileType == 'memk') {
      _controller.startMemkPerFolderExport(
        selectedFolders: selectedFolders,
        exportDirPath: exportDir.path,
      );
    } else {
      _controller.startPdfExport(
        selectedFolders: selectedFolders,
        exportDirPath: exportDir.path,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('파일 만들기'),
        actions: [
          if (!_isExporting && !widget.progressOnly)
            TextButton(
              onPressed: _selectedFolderIds.isEmpty ? null : _export,
              child: const Text('생성'),
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
                                Text('폴더 선택',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                                const Spacer(),
                                TextButton(
                                  onPressed: _toggleSelectAll,
                                  child: Text(
                                      _selectedFolderIds.length ==
                                              _folders.length
                                          ? '전체 해제'
                                          : '전체 선택'),
                                ),
                              ],
                            ),
                          ),
                          ..._folders.map((folder) {
                            return CheckboxListTile(
                              title: Text(folder.name),
                              subtitle: Text('${folder.cardCount}장'),
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
                            child: Text('파일 형식',
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
                                  title: const Text('.memk'),
                                  subtitle: const Text(
                                      '암기짱/Memora 호환 백업 파일'),
                                  value: 'memk',
                                ),
                                RadioListTile<String>(
                                  title: const Text('PDF'),
                                  subtitle: const Text('인쇄/공유용 문서'),
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
