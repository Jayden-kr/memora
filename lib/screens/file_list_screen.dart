import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart' show Share, XFile;

import '../database/database_helper.dart';
import 'import_screen.dart';

class FileListScreen extends StatefulWidget {
  const FileListScreen({super.key});

  @override
  State<FileListScreen> createState() => _FileListScreenState();
}

class _FileListScreenState extends State<FileListScreen> {
  static const _channel =
      MethodChannel('com.henry.amki_wang/import_export');

  List<Map<String, dynamic>> _files = [];
  bool _loading = true;

  // 다중 선택
  final Set<int> _selectedIds = {};
  bool get _isSelecting => _selectedIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    final rawFiles = await DatabaseHelper.instance.getAllExportedFiles();
    // sqflite query()는 읽기 전용 Map 반환 → mutable 복사 후 수정
    final files = rawFiles.map((f) => Map<String, dynamic>.from(f)).toList();
    // 실제 파일 존재 여부 체크 (비동기)
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
      // 삭제된 항목 선택 해제
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

  // ─── 단일 파일 조작 ───

  Future<void> _deleteFile(Map<String, dynamic> file) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('파일 삭제'),
        content: Text('"${file['file_name']}" 파일을 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    // 실제 파일 먼저 삭제 (실패 시 DB 레코드 유지)
    try {
      final filePath = file['file_path'] as String?;
      if (filePath != null) {
        final f = File(filePath);
        if (await f.exists()) {
          await f.delete();
        }
      }
    } catch (e) {
      debugPrint('[FILE_LIST] 파일 삭제 실패: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('파일 삭제 실패: $e')),
        );
      }
    }

    // 파일 삭제 후 DB 레코드 삭제
    await DatabaseHelper.instance.deleteExportedFile(file['id'] as int);

    if (!mounted) return;
    await _loadFiles();
  }

  Future<void> _restoreFile(Map<String, dynamic> file) async {
    final filePath = file['file_path'] as String?;
    if (filePath == null) return;
    if (!filePath.endsWith('.memk')) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('.memk 파일만 복원할 수 있습니다.')),
      );
      return;
    }

    final f = File(filePath);
    if (!await f.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('파일을 찾을 수 없습니다.')),
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

  Future<void> _renameFile(Map<String, dynamic> file) async {
    final oldName = file['file_name'] as String;
    final filePath = file['file_path'] as String;
    final ext = oldName.contains('.') ? '.${oldName.split('.').last}' : '';
    final nameWithoutExt = ext.isNotEmpty
        ? oldName.substring(0, oldName.length - ext.length)
        : oldName;

    final controller = TextEditingController(text: nameWithoutExt);
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: nameWithoutExt.length,
    );

    try {
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('파일 이름 변경'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(suffixText: ext),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('변경'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == nameWithoutExt) return;

    final newFileName = '$newName$ext';
    final dir = File(filePath).parent.path;
    final newFilePath = '$dir/$newFileName';

    // 디스크에서 실제 파일 이름 변경
    final f = File(filePath);
    if (await f.exists()) {
      await f.rename(newFilePath);
    }

    // DB 레코드 업데이트
    await DatabaseHelper.instance.renameExportedFile(
      file['id'] as int,
      newFileName,
      newFilePath,
    );

    await _loadFiles();
    } finally {
      controller.dispose();
    }
  }

  Future<void> _saveToDevice(Map<String, dynamic> file) async {
    final filePath = file['file_path'] as String;
    final fileName = file['file_name'] as String;
    final f = File(filePath);
    if (!await f.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('파일을 찾을 수 없습니다.')),
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
        SnackBar(content: Text('다운로드 폴더에 저장됨: $fileName')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('저장 실패: $e')),
      );
    }
  }

  Future<void> _shareFile(Map<String, dynamic> file) async {
    final filePath = file['file_path'] as String;
    final fileName = file['file_name'] as String;
    final f = File(filePath);
    if (!await f.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('파일을 찾을 수 없습니다.')),
      );
      return;
    }

    await Share.shareXFiles([XFile(filePath, name: fileName)]);
  }

  void _showFileOptions(Map<String, dynamic> file) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('이름 변경', style: TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(ctx);
                _renameFile(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('기기에 저장', style: TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(ctx);
                _saveToDevice(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.share),
              title: const Text('공유', style: TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(ctx);
                _shareFile(file);
              },
            ),
            if ((file['file_type'] as String?) == 'memk')
              ListTile(
                leading: const Icon(Icons.restore),
                title:
                    const Text('복원 (Import)', style: TextStyle(fontSize: 14)),
                onTap: () {
                  Navigator.pop(ctx);
                  _restoreFile(file);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('삭제',
                  style: TextStyle(fontSize: 14, color: Colors.red)),
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

  // ─── 다중 선택 ───

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
    final selected = _selectedFiles;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('파일 삭제'),
        content: Text('선택한 ${selected.length}개 파일을 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    for (final file in selected) {
      if (!mounted) return;
      // 파일 먼저 삭제 (실패해도 DB 레코드는 유지 — 데이터 추적 보존)
      try {
        final filePath = file['file_path'] as String?;
        if (filePath != null) {
          final f = File(filePath);
          if (await f.exists()) await f.delete();
        }
      } catch (_) {}
      // 파일 삭제 후 DB 레코드 삭제
      await DatabaseHelper.instance.deleteExportedFile(file['id'] as int);
    }

    _selectedIds.clear();
    if (!mounted) return;
    await _loadFiles();
  }

  Future<void> _shareSelected() async {
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
        const SnackBar(content: Text('공유할 파일이 없습니다.')),
      );
      return;
    }
    await Share.shareXFiles(xFiles);
  }

  Future<void> _saveSelectedToDevice() async {
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
      SnackBar(content: Text('$saved개 파일을 다운로드 폴더에 저장했습니다.')),
    );
  }

  Future<void> _restoreSelected() async {
    final selected = _selectedFiles;
    final memkFiles = selected
        .where((f) =>
            (f['file_type'] as String?) == 'memk' &&
            (f['_exists'] as bool? ?? false))
        .toList();
    if (memkFiles.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('복원 가능한 .memk 파일이 없습니다.')),
      );
      return;
    }

    // 순차적으로 복원
    for (final file in memkFiles) {
      final filePath = file['file_path'] as String;
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ImportScreen(filePath: filePath)),
      );
    }

    _selectedIds.clear();
    if (!mounted) return;
    _loadFiles();
  }

  // ─── Build ───

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isSelecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _clearSelection();
      },
      child: Scaffold(
        appBar: _isSelecting ? _buildSelectionAppBar() : _buildNormalAppBar(),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _files.isEmpty
                ? const Center(child: Text('내보낸 파일이 없습니다.'))
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
                            if (!exists) '(파일 없음)',
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

  AppBar _buildNormalAppBar() {
    return AppBar(
      title: const Text('파일 목록'),
    );
  }

  AppBar _buildSelectionAppBar() {
    final allSelected = _selectedIds.length == _files.length;
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _clearSelection,
      ),
      title: Text('${_selectedIds.length}개 선택'),
      actions: [
        IconButton(
          icon: Icon(allSelected
              ? Icons.deselect
              : Icons.select_all),
          tooltip: allSelected ? '전체 해제' : '전체 선택',
          onPressed: _selectAll,
        ),
        IconButton(
          icon: const Icon(Icons.download),
          tooltip: '기기에 저장',
          onPressed: _saveSelectedToDevice,
        ),
        IconButton(
          icon: const Icon(Icons.share),
          tooltip: '공유',
          onPressed: _shareSelected,
        ),
        IconButton(
          icon: const Icon(Icons.restore),
          tooltip: '복원',
          onPressed: _restoreSelected,
        ),
        IconButton(
          icon: const Icon(Icons.delete),
          tooltip: '삭제',
          onPressed: _deleteSelected,
        ),
      ],
    );
  }
}
