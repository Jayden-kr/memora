import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart' show Share, XFile;

import '../database/database_helper.dart';
import 'import_screen.dart';

class FileListScreen extends StatefulWidget {
  const FileListScreen({super.key});

  @override
  State<FileListScreen> createState() => _FileListScreenState();
}

class _FileListScreenState extends State<FileListScreen> {
  List<Map<String, dynamic>> _files = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    final files = await DatabaseHelper.instance.getAllExportedFiles();
    // 실제 파일 존재 여부 체크
    for (final file in files) {
      final filePath = file['file_path'] as String?;
      if (filePath != null) {
        file['_exists'] = File(filePath).existsSync();
      } else {
        file['_exists'] = false;
      }
    }
    if (!mounted) return;
    setState(() {
      _files = files;
      _loading = false;
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
    if (confirm != true) return;

    // DB 레코드 삭제
    await DatabaseHelper.instance.deleteExportedFile(file['id'] as int);

    // 실제 파일 삭제
    try {
      final filePath = file['file_path'] as String;
      final f = File(filePath);
      if (await f.exists()) {
        await f.delete();
      }
    } catch (e) {
      debugPrint('[FILE_LIST] 파일 삭제 실패: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('파일 삭제 실패: $e')),
        );
      }
    }

    await _loadFiles();
  }

  Future<void> _restoreFile(Map<String, dynamic> file) async {
    final filePath = file['file_path'] as String;
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

  Future<void> _shareFile(Map<String, dynamic> file) async {
    final filePath = file['file_path'] as String;
    final f = File(filePath);
    if (!await f.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('파일을 찾을 수 없습니다.')),
      );
      return;
    }

    await Share.shareXFiles([XFile(filePath)]);
  }

  void _showFileOptions(Map<String, dynamic> file) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.share),
              title: const Text('공유'),
              onTap: () {
                Navigator.pop(ctx);
                _shareFile(file);
              },
            ),
            if ((file['file_type'] as String?) == 'memk')
              ListTile(
                leading: const Icon(Icons.restore),
                title: const Text('복원 (Import)'),
                onTap: () {
                  Navigator.pop(ctx);
                  _restoreFile(file);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('삭제', style: TextStyle(color: Colors.red)),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('파일 목록'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _files.isEmpty
              ? const Center(child: Text('내보낸 파일이 없습니다.'))
              : ListView.builder(
                  itemCount: _files.length,
                  itemBuilder: (context, index) {
                    final file = _files[index];
                    final fileName = file['file_name'] as String;
                    final fileSize = file['file_size'] as int?;
                    final fileType = file['file_type'] as String?;
                    final createdAt = file['created_at'] as String?;

                    final exists = file['_exists'] as bool? ?? true;

                    return ListTile(
                      leading: Icon(
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
                      onTap: () => _showFileOptions(file),
                    );
                  },
                ),
    );
  }
}
