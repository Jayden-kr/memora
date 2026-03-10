import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../database/database_helper.dart';
import '../models/folder.dart';
import '../services/memk_export_service.dart';
import '../widgets/folder_tile.dart';
import 'card_list_screen.dart';
import 'import_screen.dart';
import 'lock_screen_settings.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Folder> _folders = [];
  bool _loading = true;
  StreamSubscription<List<SharedMediaFile>>? _intentSub;

  @override
  void initState() {
    super.initState();
    _loadFolders();
    _initSharingIntent();
  }

  @override
  void dispose() {
    _intentSub?.cancel();
    super.dispose();
  }

  void _initSharingIntent() {
    // 앱 시작 시 Intent로 전달된 .memk 파일 처리
    ReceiveSharingIntent.instance.getInitialMedia().then((files) {
      _handleSharedFiles(files);
    });

    // 앱 실행 중 Intent 수신
    _intentSub = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen(_handleSharedFiles);
  }

  void _handleSharedFiles(List<SharedMediaFile> files) {
    if (files.isEmpty) return;
    final memkFile = files.firstWhere(
      (f) => f.path.endsWith('.memk'),
      orElse: () => files.first,
    );
    if (memkFile.path.endsWith('.memk')) {
      _navigateToImport(memkFile.path);
    }
  }

  Future<void> _loadFolders() async {
    final folders = await DatabaseHelper.instance.getAllFolders();
    setState(() {
      _folders = folders;
      _loading = false;
    });
  }

  Future<void> _createFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('새 폴더'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '폴더 이름'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('생성'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;

    // 중복 이름 체크
    final existing = await DatabaseHelper.instance.getFolderByName(name);
    if (existing != null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('이미 "$name" 폴더가 있습니다.')),
      );
      return;
    }

    final maxSeq = _folders.isEmpty
        ? 0
        : _folders.map((f) => f.sequence).reduce((a, b) => a > b ? a : b);
    final folder = Folder(name: name, sequence: maxSeq + 1);
    await DatabaseHelper.instance.insertFolder(folder);
    await _loadFolders();
  }

  Future<void> _showFolderOptions(Folder folder) async {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('이름 변경'),
              onTap: () {
                Navigator.pop(ctx);
                _renameFolder(folder);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('삭제', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                _deleteFolder(folder);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _renameFolder(Folder folder) async {
    final controller = TextEditingController(text: folder.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('폴더 이름 변경'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '새 이름'),
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
    if (newName == null || newName.isEmpty || newName == folder.name) return;

    final existing = await DatabaseHelper.instance.getFolderByName(newName);
    if (existing != null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('이미 "$newName" 폴더가 있습니다.')),
      );
      return;
    }

    await DatabaseHelper.instance.updateFolder(folder.copyWith(name: newName));
    await _loadFolders();
  }

  Future<void> _navigateToImport(String filePath) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ImportScreen(filePath: filePath)),
    );
    _loadFolders();
  }

  Future<void> _pickAndImport() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
    );
    if (result == null || result.files.single.path == null) return;
    final filePath = result.files.single.path!;
    if (!filePath.endsWith('.memk')) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('.memk 파일만 선택할 수 있습니다.')),
      );
      return;
    }
    await _navigateToImport(filePath);
  }

  Future<void> _exportMemk() async {
    final outputDir = await FilePicker.platform.getDirectoryPath();
    if (outputDir == null) return;

    final now = DateTime.now();
    final fileName = '암기왕_backup_'
        '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}.memk';
    final outputPath = '$outputDir/$fileName';

    if (!mounted) return;

    // 진행률 다이얼로그
    String progressMsg = 'Export 준비 중...';
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(progressMsg),
              ],
            ),
          );
        },
      ),
    );

    try {
      await MemkExportService().exportMemk(
        outputPath: outputPath,
        onProgress: (progress) {
          progressMsg = progress.message ?? '처리 중...';
          // 다이얼로그 rebuild
          if (mounted) setState(() {});
        },
      );

      if (!mounted) return;
      Navigator.pop(context); // 다이얼로그 닫기
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export 완료: $fileName')),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export 실패: $e')),
      );
    }
  }

  Future<void> _deleteFolder(Folder folder) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('폴더 삭제'),
        content: Text('"${folder.name}" 폴더와 카드 ${folder.cardCount}장이 모두 삭제됩니다.'),
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

    await DatabaseHelper.instance.deleteFolder(folder.id!);
    await _loadFolders();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('암기왕'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'import':
                  _pickAndImport();
                case 'export':
                  _exportMemk();
                case 'lockscreen':
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const LockScreenSettingsScreen()),
                  );
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'import',
                child: ListTile(
                  leading: Icon(Icons.file_download),
                  title: Text('Import (.memk)'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'export',
                child: ListTile(
                  leading: Icon(Icons.file_upload),
                  title: Text('Export (.memk)'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'lockscreen',
                child: ListTile(
                  leading: Icon(Icons.lock),
                  title: Text('잠금화면 설정'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _folders.isEmpty
              ? const Center(
                  child: Text('폴더가 없습니다.\n+ 버튼으로 추가하세요.',
                      textAlign: TextAlign.center),
                )
              : ListView.builder(
                  itemCount: _folders.length,
                  itemBuilder: (context, index) {
                    final folder = _folders[index];
                    return FolderTile(
                      folder: folder,
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => CardListScreen(folder: folder),
                          ),
                        );
                        _loadFolders();
                      },
                      onLongPress: () => _showFolderOptions(folder),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createFolder,
        child: const Icon(Icons.add),
      ),
    );
  }
}
