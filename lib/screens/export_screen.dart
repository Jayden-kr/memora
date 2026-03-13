import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart' show Share, XFile;

import '../database/database_helper.dart';
import '../models/folder.dart';
import '../services/memk_export_service.dart';
import '../services/pdf_export_service.dart';

class ExportScreen extends StatefulWidget {
  const ExportScreen({super.key});

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  List<Folder> _folders = [];
  final Set<int> _selectedFolderIds = {};
  String _fileType = 'memk'; // 'memk' or 'pdf'
  bool _loading = true;
  bool _exporting = false;
  String _progressMessage = '';
  double _progressValue = 0.0;

  @override
  void initState() {
    super.initState();
    _loadFolders();
  }

  Future<void> _loadFolders() async {
    final folders = await DatabaseHelper.instance.getNonBundleFolders();
    if (!mounted) return;
    setState(() {
      _folders = folders;
      _loading = false;
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selectedFolderIds.length == _folders.length) {
        _selectedFolderIds.clear();
      } else {
        _selectedFolderIds.addAll(_folders.map((f) => f.id!));
      }
    });
  }

  Future<void> _export() async {
    if (_selectedFolderIds.isEmpty) return;

    // 앱 내부 documents/exports 디렉토리에 저장 (권한 불필요)
    final appDocDir = await getApplicationDocumentsDirectory();
    final exportDir = Directory('${appDocDir.path}/exports');
    if (!await exportDir.exists()) {
      await exportDir.create(recursive: true);
    }

    final now = DateTime.now();
    final timestamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
        '_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';

    setState(() {
      _exporting = true;
      _progressMessage = '준비 중...';
    });

    try {
      String outputPath;
      String fileName;
      if (_fileType == 'memk') {
        fileName = 'Memora_$timestamp.memk';
        outputPath = p.join(exportDir.path, fileName);
        await MemkExportService().exportMemk(
          outputPath: outputPath,
          folderIds: _selectedFolderIds.toList(),
          onProgress: (progress) {
            if (mounted) {
              final total = progress.total > 0 ? progress.total : 1;
              setState(() {
                _progressMessage = progress.message ?? '처리 중...';
                _progressValue = progress.current / total;
              });
            }
          },
        );
      } else {
        fileName = 'Memora_$timestamp.pdf';
        outputPath = p.join(exportDir.path, fileName);
        await PdfExportService().exportPdf(
          outputPath: outputPath,
          folderIds: _selectedFolderIds.toList(),
          onProgress: (progress) {
            if (mounted) {
              final total = progress.totalFolders > 0 ? progress.totalFolders : 1;
              setState(() {
                _progressMessage = progress.message ?? '처리 중...';
                _progressValue = progress.currentFolders / total;
              });
            }
          },
        );
      }

      // exported_files에 기록
      final file = File(outputPath);
      final fileSize = await file.length();
      try {
        await DatabaseHelper.instance.insertExportedFile(
          fileName: fileName,
          filePath: outputPath,
          fileSize: fileSize,
          fileType: _fileType,
        );
      } catch (dbErr) {
        debugPrint('[EXPORT] DB 기록 실패: $dbErr (파일은 저장됨: $outputPath)');
      }

      if (!mounted) return;
      setState(() => _exporting = false);

      // 완료 다이얼로그 — 공유 옵션 제공
      final shouldShare = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('내보내기 완료'),
          content: Text('$fileName\n파일이 생성되었습니다.'),
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
        await Share.shareXFiles([XFile(outputPath)]);
      }

      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _progressMessage = '';
        _progressValue = 0.0;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('내보내기 실패: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('파일 만들기'),
        actions: [
          TextButton(
            onPressed: _exporting || _selectedFolderIds.isEmpty
                ? null
                : _export,
            child: const Text('생성'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _exporting
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 24),
                        LinearProgressIndicator(value: _progressValue),
                        const SizedBox(height: 12),
                        Text(_progressMessage),
                        Text(
                          '${(_progressValue * 100).toInt()}%',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
                  ),
                )
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
                                style:
                                    Theme.of(context).textTheme.titleMedium),
                            const Spacer(),
                            TextButton(
                              onPressed: _toggleSelectAll,
                              child: Text(_selectedFolderIds.length ==
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
                          value: _selectedFolderIds.contains(folder.id),
                          onChanged: (checked) {
                            setState(() {
                              if (checked == true) {
                                _selectedFolderIds.add(folder.id!);
                              } else {
                                _selectedFolderIds.remove(folder.id);
                              }
                            });
                          },
                        );
                      }),

                      const Divider(height: 32),

                      // 파일 형식
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text('파일 형식',
                            style: Theme.of(context).textTheme.titleMedium),
                      ),
                      Column(
                        children: [
                          RadioListTile<String>(
                            title: const Text('.memk'),
                            subtitle: const Text('암기짱/Memora 호환 백업 파일'),
                            value: 'memk',
                            groupValue: _fileType,
                            onChanged: (v) => setState(() => _fileType = v!),
                          ),
                          RadioListTile<String>(
                            title: const Text('PDF'),
                            subtitle: const Text('인쇄/공유용 문서'),
                            value: 'pdf',
                            groupValue: _fileType,
                            onChanged: (v) => setState(() => _fileType = v!),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
    );
  }
}
