import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../database/database_helper.dart';
import '../models/folder.dart';
import '../widgets/folder_tile.dart';
import '../app.dart';
import 'bundle_folder_screen.dart';
import 'card_edit_screen.dart';
import 'card_list_screen.dart';
import 'export_screen.dart';
import 'file_list_screen.dart';
import 'import_screen.dart';
import 'lock_screen_settings.dart';
import 'push_notification_settings.dart';
import 'settings_screen.dart';
import '../services/import_export_controller.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with RouteAware {
  List<Folder> _folders = [];
  bool _loading = true;
  bool _isDeleting = false;
  StreamSubscription<List<SharedMediaFile>>? _intentSub;
  String _sortMode = 'sequence'; // sequence, name_asc, oldest, newest
  int _totalCardCount = 0;
  bool _isPickingFile = false;

  // 다중 선택
  final Set<int> _selectedFolderIds = {};
  bool get _isSelecting => _selectedFolderIds.isNotEmpty;

  static const _sortModeKey = 'home_sort_mode';

  @override
  void initState() {
    super.initState();
    _loadFolders();
    _initSharingIntent();
    ImportExportController.instance.addListener(_onImportExportUpdate);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) routeObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    ImportExportController.instance.removeListener(_onImportExportUpdate);
    _intentSub?.cancel();
    super.dispose();
  }

  @override
  void didPopNext() {
    if (!_isDeleting) _loadFolders();
  }

  void _onImportExportUpdate() {
    if (!mounted) return;
    if (!ImportExportController.instance.isRunning &&
        ImportExportController.instance.lastImportResult != null) {
      _loadFolders();
    }
  }

  void _initSharingIntent() {
    ReceiveSharingIntent.instance.getInitialMedia().then((files) {
      if (!mounted) return;
      _handleSharedFiles(files);
    });
    _intentSub = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen((files) {
      if (mounted) _handleSharedFiles(files);
    });
  }

  void _handleSharedFiles(List<SharedMediaFile> files) {
    if (files.isEmpty) return;
    if (!mounted) return;
    final memkFile = files.firstWhere(
      (f) => f.path.endsWith('.memk'),
      orElse: () => files.first,
    );
    if (memkFile.path.endsWith('.memk')) {
      _navigateToImport(memkFile.path);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('.memk 파일만 가져올 수 있습니다.')),
        );
      }
    }
  }

  Future<void> _loadFolders() async {
    final folders = await DatabaseHelper.instance.getAllFolders();
    // 폴더별 card_count 합계로 계산 (별도 COUNT 쿼리 불필요)
    final totalCards = folders.fold<int>(0, (sum, f) => sum + f.cardCount);
    // 저장된 정렬 모드 복원
    final settings = await DatabaseHelper.instance.getAllSettings();
    final savedSort = settings[_sortModeKey];
    if (!mounted) return;
    setState(() {
      if (savedSort != null) _sortMode = savedSort;
      _folders = _sortFolders(folders);
      _totalCardCount = totalCards;
      _loading = false;
    });
  }

  List<Folder> _sortFolders(List<Folder> folders) {
    final sorted = List<Folder>.from(folders);
    switch (_sortMode) {
      case 'name_asc':
        sorted.sort((a, b) => a.name.compareTo(b.name));
      case 'oldest':
        sorted.sort((a, b) => (a.id ?? 0).compareTo(b.id ?? 0));
      case 'newest':
        sorted.sort((a, b) => (b.id ?? 0).compareTo(a.id ?? 0));
      default: // sequence
        sorted.sort((a, b) => a.sequence.compareTo(b.sequence));
    }
    return sorted;
  }

  void _changeSortMode(String mode) {
    setState(() {
      _sortMode = mode;
      _folders = _sortFolders(_folders);
    });
    DatabaseHelper.instance.upsertSetting(_sortModeKey, mode);
  }

  Future<void> _showFolderPickerForNewCard() async {
    final nonBundleFolders = _folders.where((f) => !f.isBundle).toList();
    if (nonBundleFolders.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('폴더를 먼저 만들어주세요.')),
      );
      return;
    }
    final selected = await showDialog<Folder>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('카드를 추가할 폴더'),
        children: nonBundleFolders.map((folder) {
          return SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, folder),
            child: Text('${folder.name} (${folder.cardCount}장)'),
          );
        }).toList(),
      ),
    );
    if (selected == null || !mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CardEditScreen(folderId: selected.id!),
      ),
    );
    _loadFolders();
  }

  Future<void> _showFabBottomSheet() async {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.note_add),
              title: const Text('새 카드 추가',
                  style: TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(ctx);
                _showFolderPickerForNewCard();
              },
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder),
              title: const Text('새 폴더 만들기',
                  style: TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(ctx);
                _createFolder();
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_special),
              title: const Text('묶음 폴더 만들기',
                  style: TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(ctx);
                _navigateToBundleFolder();
              },
            ),
            ListTile(
              leading: const Icon(Icons.file_download),
              title: const Text('파일(.memk) 가져오기',
                  style: TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(ctx);
                _pickAndImport();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createFolder() async {
    final controller = TextEditingController();
    try {
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

    final existing = await DatabaseHelper.instance.getFolderByName(name);
    if (existing != null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('이미 "$name" 폴더가 있습니다.')),
      );
      return;
    }

    final maxSeq = await DatabaseHelper.instance.getMaxFolderSequence();
    final folder = Folder(name: name, sequence: maxSeq + 1);
    await DatabaseHelper.instance.insertFolder(folder);
    await _loadFolders();
    } finally {
      controller.dispose();
    }
  }

  Future<void> _navigateToBundleFolder({Folder? existing}) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BundleFolderScreen(existingBundle: existing),
      ),
    );
    _loadFolders();
  }



  Future<void> _renameFolder(Folder folder) async {
    final controller = TextEditingController(text: folder.name);
    try {
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
    if (!mounted) return;
    await _loadFolders();
    } finally {
      controller.dispose();
    }
  }

  Future<void> _navigateToImport(String filePath) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ImportScreen(filePath: filePath)),
    );
    _loadFolders();
  }

  Future<void> _pickAndImport() async {
    setState(() => _isPickingFile = true);
    try {
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
    } finally {
      if (mounted) setState(() => _isPickingFile = false);
    }
  }

  Future<void> _onFolderTap(Folder folder) async {
    if (folder.isBundle) {
      // 묶음 폴더 → 하위 폴더 리스트
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => _BundleChildListScreen(bundle: folder),
        ),
      );
    } else {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CardListScreen(folder: folder),
        ),
      );
    }
    _loadFolders();
  }

  void _onReorder(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) newIndex--;
    setState(() {
      final folder = _folders.removeAt(oldIndex);
      _folders.insert(newIndex, folder);
    });
    // DB 시퀀스 업데이트 후 로컬 객체도 동기화
    () async {
      try {
        await _updateFolderSequences();
      } catch (e) {
        debugPrint('[HOME] reorder error: $e');
      } finally {
        if (mounted) _loadFolders();
      }
    }();
  }

  Future<void> _updateFolderSequences() async {
    final updates = <int, int>{};
    for (int i = 0; i < _folders.length; i++) {
      final folder = _folders[i];
      if (folder.sequence != i && folder.id != null) {
        updates[folder.id!] = i;
      }
    }
    if (updates.isNotEmpty) {
      await DatabaseHelper.instance.updateFolderSequencesBatch(updates);
    }
  }

  // ─── 다중 선택 ───

  void _toggleFolderSelection(int id) {
    setState(() {
      if (_selectedFolderIds.contains(id)) {
        _selectedFolderIds.remove(id);
      } else {
        _selectedFolderIds.add(id);
      }
    });
  }

  void _clearSelection() {
    setState(() => _selectedFolderIds.clear());
  }

  void _selectAllFolders() {
    setState(() {
      if (_selectedFolderIds.length == _folders.length) {
        _selectedFolderIds.clear();
      } else {
        _selectedFolderIds.addAll(
            _folders.where((f) => f.id != null).map((f) => f.id!));
      }
    });
  }

  Future<void> _deleteSelectedFolders() async {
    final selected =
        _folders.where((f) => _selectedFolderIds.contains(f.id)).toList();
    if (selected.isEmpty) return;

    final totalCards = selected
        .where((f) => !f.isBundle)
        .fold<int>(0, (sum, f) => sum + f.cardCount);
    final hasBundles = selected.any((f) => f.isBundle);

    String message = '선택한 ${selected.length}개 폴더를 삭제하시겠습니까?';
    if (totalCards > 0) {
      message += '\n카드 $totalCards장이 함께 삭제됩니다.';
    }
    if (hasBundles) {
      message += '\n묶음 폴더의 하위 폴더는 삭제되지 않습니다.';
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('폴더 삭제'),
        content: Text(message),
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

    _isDeleting = true;

    // Optimistic UI update
    setState(() {
      _folders.removeWhere((f) => _selectedFolderIds.contains(f.id));
      _totalCardCount = _folders.fold<int>(0, (sum, f) => sum + f.cardCount);
    });

    try {
      for (final folder in selected) {
        if (folder.isBundle) {
          await DatabaseHelper.instance.deleteBundleFolder(folder.id!);
        } else {
          // 이미지 파일 수집 후 삭제
          final imagePaths = <String>[];
          const batchSize = 500;
          int offset = 0;
          while (true) {
            final cards = await DatabaseHelper.instance
                .getCardsByFolderId(folder.id!,
                    limit: batchSize, offset: offset);
            if (cards.isEmpty) break;
            for (final card in cards) {
              imagePaths.addAll(card.questionImagePaths);
              imagePaths.addAll(card.answerImagePaths);
              for (final p in [
                card.questionHandImagePath,
                card.questionHandImagePath2,
                card.questionHandImagePath3,
                card.questionHandImagePath4,
                card.questionHandImagePath5,
                card.answerHandImagePath,
                card.answerHandImagePath2,
                card.answerHandImagePath3,
                card.answerHandImagePath4,
                card.answerHandImagePath5,
                card.questionVoiceRecordPath,
                card.questionVoiceRecordPath2,
                card.questionVoiceRecordPath3,
                card.questionVoiceRecordPath4,
                card.questionVoiceRecordPath5,
                card.questionVoiceRecordPath6,
                card.questionVoiceRecordPath7,
                card.questionVoiceRecordPath8,
                card.questionVoiceRecordPath9,
                card.questionVoiceRecordPath10,
                card.answerVoiceRecordPath,
                card.answerVoiceRecordPath2,
                card.answerVoiceRecordPath3,
                card.answerVoiceRecordPath4,
                card.answerVoiceRecordPath5,
                card.answerVoiceRecordPath6,
                card.answerVoiceRecordPath7,
                card.answerVoiceRecordPath8,
                card.answerVoiceRecordPath9,
                card.answerVoiceRecordPath10,
              ]) {
                if (p != null && p.isNotEmpty) imagePaths.add(p);
              }
            }
            offset += batchSize;
          }
          await DatabaseHelper.instance.deleteFolder(folder.id!);
          for (final path in imagePaths) {
            try {
              final f = File(path);
              if (await f.exists()) await f.delete();
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      debugPrint('[HOME] delete selected folders error: $e');
      if (mounted) await _loadFolders(); // 옵티미스틱 UI 롤백
    } finally {
      _isDeleting = false;
      _selectedFolderIds.clear();
    }

    if (!mounted) return;
    await _loadFolders();
  }

  void _exportSelectedFolders() {
    final nonBundleIds = _folders
        .where((f) => _selectedFolderIds.contains(f.id) && !f.isBundle)
        .map((f) => f.id!)
        .toList();
    if (nonBundleIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('내보낼 수 있는 폴더가 없습니다.')),
      );
      return;
    }
    _clearSelection();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ExportScreen(initialFolderIds: nonBundleIds),
      ),
    );
  }

  Future<void> _renameSelectedFolder() async {
    final selectedList =
        _folders.where((f) => _selectedFolderIds.contains(f.id)).toList();
    if (selectedList.length != 1) return;
    final folder = selectedList.first;
    _clearSelection();
    await _renameFolder(folder);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_isSelecting) {
          _clearSelection();
          return;
        }
        // Export/Import 진행 중이면 앱을 종료하지 않고 백그라운드로 보냄
        if (ImportExportController.instance.isRunning) {
          const MethodChannel('com.henry.amki_wang/import_export')
              .invokeMethod('moveToBackground');
          return;
        }
        // 기본: 앱 종료
        SystemNavigator.pop();
      },
      child: Scaffold(
        appBar: _isSelecting
            ? _buildSelectionAppBar()
            : AppBar(
                title:
                    const Text('Memora', style: TextStyle(fontSize: 20)),
                actions: [
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.sort),
                    tooltip: '정렬',
                    onSelected: _changeSortMode,
                    itemBuilder: (_) => [
                      _sortMenuItem('수동 (드래그)', 'sequence'),
                      _sortMenuItem('가나다순', 'name_asc'),
                      _sortMenuItem('오래된순', 'oldest'),
                      _sortMenuItem('최신순', 'newest'),
                    ],
                  ),
                ],
              ),
        drawer: _isSelecting ? null : _buildDrawer(),
        body: Stack(
          children: [
            _loading
                ? const Center(child: CircularProgressIndicator())
                : _folders.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.folder_open,
                                size: 64,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant
                                    .withValues(alpha: 0.5)),
                            const SizedBox(height: 16),
                            Text('폴더가 없습니다.\n+ 버튼으로 추가하세요.',
                                textAlign: TextAlign.center,
                                style:
                                    Theme.of(context).textTheme.bodyLarge),
                          ],
                        ),
                      )
                    : !_isSelecting && _sortMode == 'sequence'
                        ? ReorderableListView.builder(
                            itemCount: _folders.length,
                            onReorder: _onReorder,
                            buildDefaultDragHandles: false,
                            itemBuilder: (context, index) {
                              final folder = _folders[index];
                              return FolderTile(
                                key: ValueKey(folder.id),
                                folder: folder,
                                reorderIndex: index,
                                onTap: () => _onFolderTap(folder),
                                onLongPress: () {
                                  if (folder.id != null) {
                                    _toggleFolderSelection(folder.id!);
                                  }
                                },
                              );
                            },
                          )
                        : ListView.builder(
                            itemCount: _folders.length,
                            itemBuilder: (context, index) {
                              final folder = _folders[index];
                              return FolderTile(
                                key: ValueKey(folder.id),
                                folder: folder,
                                isSelecting: _isSelecting,
                                isSelected: _selectedFolderIds
                                    .contains(folder.id),
                                onTap: _isSelecting
                                    ? () {
                                        if (folder.id != null) {
                                          _toggleFolderSelection(
                                              folder.id!);
                                        }
                                      }
                                    : () => _onFolderTap(folder),
                                onLongPress: _isSelecting
                                    ? null
                                    : () {
                                        if (folder.id != null) {
                                          _toggleFolderSelection(
                                              folder.id!);
                                        }
                                      },
                              );
                            },
                          ),
            if (_isPickingFile) ...[
              const ModalBarrier(
                  dismissible: false, color: Colors.black26),
              const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('파일 준비 중...'),
                  ],
                ),
              ),
            ],
          ],
        ),
        floatingActionButton: _isSelecting
            ? null
            : FloatingActionButton(
                onPressed: _showFabBottomSheet,
                child: const Icon(Icons.add),
              ),
      ),
    );
  }

  AppBar _buildSelectionAppBar() {
    final allSelected = _selectedFolderIds.length == _folders.length;
    final selectedList =
        _folders.where((f) => _selectedFolderIds.contains(f.id)).toList();
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _clearSelection,
      ),
      title: Text('${_selectedFolderIds.length}개 선택'),
      actions: [
        IconButton(
          icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
          tooltip: allSelected ? '전체 해제' : '전체 선택',
          onPressed: _selectAllFolders,
        ),
        IconButton(
          icon: const Icon(Icons.file_upload),
          tooltip: '내보내기',
          onPressed: _exportSelectedFolders,
        ),
        IconButton(
          icon: const Icon(Icons.delete),
          tooltip: '삭제',
          onPressed: _deleteSelectedFolders,
        ),
        if (selectedList.length == 1)
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'rename') _renameSelectedFolder();
              if (value == 'edit_bundle') {
                final folder = selectedList.first;
                _clearSelection();
                _navigateToBundleFolder(existing: folder);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'rename',
                child: Text('이름 변경'),
              ),
              if (selectedList.first.isBundle)
                const PopupMenuItem(
                  value: 'edit_bundle',
                  child: Text('묶음 폴더 편집'),
                ),
            ],
          ),
      ],
    );
  }

  PopupMenuItem<String> _sortMenuItem(String label, String value) {
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          if (_sortMode == value)
            Icon(Icons.check,
                size: 18, color: Theme.of(context).colorScheme.primary)
          else
            const SizedBox(width: 18),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text('Memora',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    )),
                const SizedBox(height: 4),
                Text(
                  '카드 $_totalCardCount장 · 폴더 ${_folders.length}개',
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.style),
            title: const Text('전체 카드 보기', style: TextStyle(fontSize: 14)),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => CardListScreen(
                    folder: Folder(name: '전체 카드'),
                    allCards: true,
                  ),
                ),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.notifications),
            title: const Text('카드 푸시 알림', style: TextStyle(fontSize: 14)),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) =>
                        const PushNotificationSettingsScreen()),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.lock),
            title: const Text('잠금화면 설정', style: TextStyle(fontSize: 14)),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const LockScreenSettingsScreen()),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings),
            title: const Text('설정', style: TextStyle(fontSize: 14)),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(
                      themeModeNotifier: themeModeNotifier),
                ),
              );
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.file_upload),
            title: const Text('파일 만들기', style: TextStyle(fontSize: 14)),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const ExportScreen()),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.list_alt),
            title: const Text('파일 목록', style: TextStyle(fontSize: 14)),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const FileListScreen()),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 묶음 폴더 하위 폴더 리스트 화면
class _BundleChildListScreen extends StatefulWidget {
  final Folder bundle;

  const _BundleChildListScreen({required this.bundle});

  @override
  State<_BundleChildListScreen> createState() => _BundleChildListScreenState();
}

class _BundleChildListScreenState extends State<_BundleChildListScreen> {
  List<Folder> _children = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadChildren();
  }

  Future<void> _loadChildren() async {
    final children =
        await DatabaseHelper.instance.getChildFolders(widget.bundle.id!);
    if (!mounted) return;
    setState(() {
      _children = children;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.bundle.name),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _children.isEmpty
              ? const Center(child: Text('하위 폴더가 없습니다.'))
              : ListView.builder(
                  itemCount: _children.length,
                  itemBuilder: (context, index) {
                    final folder = _children[index];
                    return FolderTile(
                      folder: folder,
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => CardListScreen(folder: folder),
                          ),
                        );
                        _loadChildren();
                      },
                    );
                  },
                ),
    );
  }
}
