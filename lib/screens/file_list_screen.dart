import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart' show Share, XFile;

import '../database/database_helper.dart';
import '../l10n/app_localizations.dart';
import '../widgets/overwrite_dialog.dart';
import 'import_screen.dart';

class FileListScreen extends StatefulWidget {
  const FileListScreen({super.key});

  @override
  State<FileListScreen> createState() => _FileListScreenState();
}

class _FileListScreenState extends State<FileListScreen> {
  static const _channel =
      MethodChannel('com.henry.memora/import_export');

  List<Map<String, dynamic>> _files = [];
  bool _loading = true;

  final Set<int> _selectedIds = {};
  bool get _isSelecting => _selectedIds.isNotEmpty;
  bool _isDeleting = false; // batch delete 재진입 차단

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    List<Map<String, dynamic>> rawFiles;
    try {
      rawFiles = await DatabaseHelper.instance.getAllExportedFiles();
    } catch (e) {
      debugPrint('[FILE_LIST] _loadFiles error: $e');
      if (!mounted) return;
      setState(() {
        _files = [];
        _loading = false;
      });
      return;
    }
    final files = rawFiles.map((f) => Map<String, dynamic>.from(f)).toList();
    for (final file in files) {
      final filePath = file['file_path'] as String?;
      if (filePath != null) {
        file['_exists'] = await File(filePath).exists();
      } else {
        file['_exists'] = false;
      }
    }
    if (!mounted) return;
    setState(() {
      _files = files;
      _loading = false;
      _selectedIds.retainWhere(
          (id) => files.any((f) => f['id'] == id));
    });
  }

  String _formatFileSize(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  IconData _fileIcon(String? fileType) {
    switch (fileType) {
      case 'memk':
        return Icons.archive;
      case 'pdf':
        return Icons.picture_as_pdf;
      default:
        return Icons.insert_drive_file;
    }
  }

  // ─── Single-file actions ───

  Future<void> _deleteFile(Map<String, dynamic> file) async {
    final t = AppLocalizations.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.fileDeleteTitle),
        content: Text(t.fileDeleteSingle(file['file_name'] as String)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.commonDelete,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    try {
      final filePath = file['file_path'] as String?;
      if (filePath != null) {
        final f = File(filePath);
        if (await f.exists()) {
          await f.delete();
        }
      }
    } catch (e) {
      debugPrint('[FILE_LIST] file delete failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.fileDeleteFail(e.toString()))),
        );
      }
    }

    await DatabaseHelper.instance.deleteExportedFile(file['id'] as int);

    if (!mounted) return;
    await _loadFiles();
  }

  Future<void> _restoreFile(Map<String, dynamic> file) async {
    final t = AppLocalizations.of(context);
    final filePath = file['file_path'] as String?;
    if (filePath == null) return;
    if (!filePath.endsWith('.memk') && !filePath.endsWith('.mra')) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.fileOnlyMemkRestore)),
      );
      return;
    }

    final f = File(filePath);
    if (!await f.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.fileNotFound)),
      );
      return;
    }

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ImportScreen(filePath: filePath)),
    );
    _loadFiles();
  }

  /// ⚠️ 예전엔 여기 스코프에 클로저 변수로 `TextEditingController`를 만들고
  /// `try { showDialog(...) } finally { controller.dispose(); }`로 정리했었다 —
  /// push_notification_settings.dart의 `_PushRuleDialog` 문서에 적힌 것과 동일한
  /// '_dependents.isEmpty' 크래시 위험 패턴. 지금은 controller를
  /// [_RenameFileDialog]의 State가 소유해 dispose()가 Element unmount 시점에만
  /// 불리도록 고쳤다.
  Future<void> _renameFile(Map<String, dynamic> file) async {
    final t = AppLocalizations.of(context);
    final oldName = file['file_name'] as String;
    final filePath = file['file_path'] as String;
    final ext = oldName.contains('.') ? '.${oldName.split('.').last}' : '';
    final nameWithoutExt = ext.isNotEmpty
        ? oldName.substring(0, oldName.length - ext.length)
        : oldName;

    final newName = await showDialog<String>(
      context: context,
      builder: (_) => _RenameFileDialog(
        initialName: nameWithoutExt,
        ext: ext,
      ),
    );
    if (newName == null || newName.isEmpty || newName == nameWithoutExt) return;

    final newFileName = '$newName$ext';
    final dir = File(filePath).parent.path;
    final newFilePath = '$dir/$newFileName';

    if (newFilePath != filePath && await File(newFilePath).exists()) {
      if (!mounted) return;
      final action = await showOverwriteDialog(
        context: context,
        title: t.fileRenameOverwriteTitle,
        message: t.fileRenameOverwriteBody(newFileName),
        options: [
          OverwriteOption(
            icon: Icons.refresh,
            title: t.commonOverwrite,
            subtitle: t.fileRenameOverwriteSubtitle,
            value: 'overwrite',
            accent: true,
          ),
        ],
      );
      if (action != 'overwrite') return;
      try { await File(newFilePath).delete(); } catch (_) {}
      try {
        await DatabaseHelper.instance.deleteExportedFileByPath(newFilePath);
      } catch (_) {}
    }

    final f = File(filePath);
    try {
      if (await f.exists()) {
        await f.rename(newFilePath);
      }
    } catch (e) {
      debugPrint('[FILE_LIST] rename failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.fileRenameFail)),
      );
      return;
    }

    await DatabaseHelper.instance.renameExportedFile(
      file['id'] as int,
      newFileName,
      newFilePath,
    );

    if (!mounted) return;
    await _loadFiles();
  }

  Future<void> _saveToDevice(Map<String, dynamic> file) async {
    final t = AppLocalizations.of(context);
    final filePath = file['file_path'] as String;
    final fileName = file['file_name'] as String;
    final f = File(filePath);
    if (!await f.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.fileNotFound)),
      );
      return;
    }

    try {
      await _channel.invokeMethod('saveToDownloads', {
        'sourcePath': filePath,
        'fileName': fileName,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.fileSavedToDownloads(fileName))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.fileSaveFail(e.toString()))),
      );
    }
  }

  Future<void> _shareFile(Map<String, dynamic> file) async {
    final t = AppLocalizations.of(context);
    final filePath = file['file_path'] as String;
    final fileName = file['file_name'] as String;
    final f = File(filePath);
    if (!await f.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.fileNotFound)),
      );
      return;
    }

    await Share.shareXFiles([XFile(filePath, name: fileName)]);
  }

  void _showFileOptions(Map<String, dynamic> file) {
    final t = AppLocalizations.of(context);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: Text(t.fileOptionsRename, style: const TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(ctx);
                _renameFile(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.download),
              title: Text(t.fileOptionsSaveDevice, style: const TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(ctx);
                _saveToDevice(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.share),
              title: Text(t.fileOptionsShare, style: const TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(ctx);
                _shareFile(file);
              },
            ),
            if ((file['file_type'] as String?) == 'memk')
              ListTile(
                leading: const Icon(Icons.restore),
                title:
                    Text(t.fileOptionsRestore, style: const TextStyle(fontSize: 14)),
                onTap: () {
                  Navigator.pop(ctx);
                  _restoreFile(file);
                },
              ),
            ListTile(
              leading: Icon(Icons.delete, color: Theme.of(context).colorScheme.error),
              title: Text(t.commonDelete,
                  style: TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.error)),
              onTap: () {
                Navigator.pop(ctx);
                _deleteFile(file);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ─── Multi-select ───

  void _toggleSelection(int id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _clearSelection() {
    setState(() => _selectedIds.clear());
  }

  void _selectAll() {
    setState(() {
      if (_selectedIds.length == _files.length) {
        _selectedIds.clear();
      } else {
        _selectedIds.addAll(_files.map((f) => f['id'] as int));
      }
    });
  }

  List<Map<String, dynamic>> get _selectedFiles =>
      _files.where((f) => _selectedIds.contains(f['id'] as int)).toList();

  Future<void> _deleteSelected() async {
    if (_isDeleting) return; // 재진입 차단
    final t = AppLocalizations.of(context);
    final selected = _selectedFiles;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.fileDeleteTitle),
        content: Text(t.fileDeleteMulti(selected.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.commonDelete,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    _isDeleting = true;
    try {
      // ⚡ DB는 단일 transaction으로 batch delete (수십~수백 ms)
      final ids = selected.map((f) => f['id'] as int).toList();
      await DatabaseHelper.instance.deleteExportedFilesBatch(ids);
      if (!mounted) return;

      // commit 직후 UI 즉시 정리
      setState(() {
        _files.removeWhere((f) => ids.contains(f['id'] as int));
        _selectedIds.clear();
      });

      // 🔄 .mra 파일 시스템 삭제는 fire-and-forget. DB는 이미 commit.
      for (final file in selected) {
        final filePath = file['file_path'] as String?;
        if (filePath != null) {
          File(filePath).delete().ignore();
        }
      }
    } catch (e) {
      debugPrint('[FILE_LIST] batch file delete failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.fileDeleteFail(e.toString()))),
        );
      }
    } finally {
      _isDeleting = false;
    }
  }

  Future<void> _shareSelected() async {
    final t = AppLocalizations.of(context);
    final selected = _selectedFiles;
    final xFiles = <XFile>[];
    for (final file in selected) {
      final filePath = file['file_path'] as String?;
      final fileName = file['file_name'] as String?;
      if (filePath == null || fileName == null) continue;
      if (await File(filePath).exists()) {
        xFiles.add(XFile(filePath, name: fileName));
      }
    }
    if (xFiles.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.fileNoShareable)),
      );
      return;
    }
    await Share.shareXFiles(xFiles);
  }

  Future<void> _saveSelectedToDevice() async {
    final t = AppLocalizations.of(context);
    final selected = _selectedFiles;
    int saved = 0;
    for (final file in selected) {
      final filePath = file['file_path'] as String?;
      final fileName = file['file_name'] as String?;
      if (filePath == null || fileName == null) continue;
      if (!await File(filePath).exists()) continue;
      try {
        await _channel.invokeMethod('saveToDownloads', {
          'sourcePath': filePath,
          'fileName': fileName,
        });
        saved++;
      } catch (_) {}
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t.fileBatchSaved(saved))),
    );
  }

  Future<void> _restoreSelected() async {
    final t = AppLocalizations.of(context);
    final selected = _selectedFiles;
    final memkFiles = selected
        .where((f) =>
            (f['file_type'] as String?) == 'memk' &&
            (f['_exists'] as bool? ?? false))
        .toList();
    if (memkFiles.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.fileNoRestorable)),
      );
      return;
    }

    for (final file in memkFiles) {
      final filePath = file['file_path'] as String;
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ImportScreen(filePath: filePath)),
      );
    }

    if (!mounted) return;
    setState(() => _selectedIds.clear());
    _loadFiles();
  }

  // ─── Build ───

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return PopScope(
      canPop: !_isSelecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _clearSelection();
      },
      child: Scaffold(
        appBar: _isSelecting ? _buildSelectionAppBar(t) : _buildNormalAppBar(t),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _files.isEmpty
                ? Center(child: Text(t.fileListEmpty))
                : ListView.builder(
                    itemCount: _files.length,
                    itemBuilder: (context, index) {
                      final file = _files[index];
                      final fileId = file['id'] as int;
                      final fileName = file['file_name'] as String;
                      final fileSize = file['file_size'] as int?;
                      final fileType = file['file_type'] as String?;
                      final createdAt = file['created_at'] as String?;
                      final exists = file['_exists'] as bool? ?? true;
                      final isSelected = _selectedIds.contains(fileId);

                      return ListTile(
                        leading: _isSelecting
                            ? Checkbox(
                                value: isSelected,
                                onChanged: (_) => _toggleSelection(fileId),
                              )
                            : Icon(
                                _fileIcon(fileType),
                                color: exists
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context).colorScheme.outline,
                              ),
                        title: Text(
                          fileName,
                          style: exists
                              ? null
                              : TextStyle(
                                  color: Theme.of(context).colorScheme.outline,
                                  decoration: TextDecoration.lineThrough,
                                ),
                        ),
                        subtitle: Text(
                          [
                            if (!exists) t.fileListMissing,
                            _formatFileSize(fileSize),
                            if (createdAt != null)
                              createdAt.length >= 10
                                  ? createdAt.substring(0, 10)
                                  : createdAt,
                          ].join(' · '),
                        ),
                        selected: isSelected,
                        onTap: _isSelecting
                            ? () => _toggleSelection(fileId)
                            : () => _showFileOptions(file),
                        onLongPress: _isSelecting
                            ? null
                            : () {
                                setState(() => _selectedIds.add(fileId));
                              },
                      );
                    },
                  ),
      ),
    );
  }

  AppBar _buildNormalAppBar(AppLocalizations t) {
    return AppBar(
      title: Text(t.fileListTitle),
    );
  }

  AppBar _buildSelectionAppBar(AppLocalizations t) {
    final allSelected = _selectedIds.length == _files.length;
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _clearSelection,
      ),
      title: Text(t.homeSelectedCount(_selectedIds.length)),
      actions: [
        IconButton(
          icon: Icon(allSelected
              ? Icons.deselect
              : Icons.select_all),
          tooltip: allSelected ? t.homeDeselectAll : t.homeSelectAll,
          onPressed: _selectAll,
        ),
        IconButton(
          icon: const Icon(Icons.download),
          tooltip: t.fileToolbarSaveDevice,
          onPressed: _saveSelectedToDevice,
        ),
        IconButton(
          icon: const Icon(Icons.share),
          tooltip: t.fileOptionsShare,
          onPressed: _shareSelected,
        ),
        IconButton(
          icon: const Icon(Icons.restore),
          tooltip: t.fileToolbarRestore,
          onPressed: _restoreSelected,
        ),
        IconButton(
          icon: const Icon(Icons.delete),
          tooltip: t.commonDelete,
          onPressed: _deleteSelected,
        ),
      ],
    );
  }
}

/// 내보낸 파일 이름 변경 다이얼로그. [_FileListScreenState._renameFile]이 사용한다.
///
/// StatefulWidget으로 만든 이유(중요): [TextEditingController]는 반드시
/// `State.dispose()`에서만 정리해야 한다 — Future 콜백(`.whenComplete()`나
/// `finally`)에 묶으면 Navigator.pop()이 반환하는 popped Future가 퇴장 애니메이션
/// 완료보다 먼저 끝나버려서, 아직 화면에 남아 리빌드 중인 TextField가 이미 dispose된
/// controller를 참조하는 경합이 생긴다(자세한 경위는
/// push_notification_settings.dart의 `_PushRuleDialog` 문서 참고).
class _RenameFileDialog extends StatefulWidget {
  const _RenameFileDialog({required this.initialName, required this.ext});

  final String initialName;
  final String ext;

  @override
  State<_RenameFileDialog> createState() => _RenameFileDialogState();
}

class _RenameFileDialogState extends State<_RenameFileDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName)
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: widget.initialName.length,
      );
  }

  @override
  void dispose() {
    // 여기서만 dispose한다 — Element가 실제로 unmount될 때(=다이얼로그 퇴장 애니메이션이
    // 끝난 뒤)만 프레임워크가 이 메서드를 부르므로, 아직 마운트돼 리빌드 중인 TextField가
    // dispose된 controller를 참조할 여지가 구조적으로 없다.
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(t.fileRenameTitle),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(suffixText: widget.ext),
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.commonCancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: Text(t.commonChange),
        ),
      ],
    );
  }
}
