import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart' show Share, XFile;

import '../database/database_helper.dart';
import '../models/folder.dart';
import '../services/memk_export_service.dart';
import '../services/pdf_export_service.dart';

class ExportScreen extends StatefulWidget {
  final List<int>? initialFolderIds;

  const ExportScreen({super.key, this.initialFolderIds});

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  static const _channel =
      MethodChannel('com.henry.amki_wang/import_export');

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
        _selectedFolderIds.addAll(_folders.map((f) => f.id!));
      }
    });
  }

  Future<void> _export() async {
    if (_exporting || _selectedFolderIds.isEmpty) return;

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

    // Foreground Service 시작 (Android 백그라운드 킬 방지)
    try {
      await _channel.invokeMethod('startService', {'title': 'Export 진행 중'});
    } catch (_) {}

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
              double value;
              switch (progress.phase) {
                case 'cards':
                  final total = progress.total > 0 ? progress.total : 1;
                  value = 0.05 + (progress.current / total) * 0.65;
                case 'images':
                  final total = progress.total > 0 ? progress.total : 1;
                  value = 0.70 + (progress.current / total) * 0.20;
                case 'zipping':
                  value = 0.92;
                case 'done':
                  value = 1.0;
                default:
                  value = 0.02;
              }
              setState(() {
                _progressMessage = progress.message ?? '처리 중...';
                _progressValue = value.clamp(0.0, 1.0);
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

      // Foreground Service 완료
      try {
        await _channel.invokeMethod('complete', {
          'title': 'Export 완료',
          'message': fileName,
        });
      } catch (_) {}

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
      // Foreground Service 취소
      try {
        await _channel.invokeMethod('cancel');
      } catch (_) {}

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
                      RadioGroup<String>(
                        groupValue: _fileType,
                        onChanged: (v) => setState(() => _fileType = v ?? _fileType),
                        child: Column(
                          children: [
                            RadioListTile<String>(
                              title: const Text('.memk'),
                              subtitle: const Text('암기짱/Memora 호환 백업 파일'),
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
