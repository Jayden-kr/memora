import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../database/database_helper.dart';
import '../l10n/app_localizations.dart';
import '../models/folder.dart';
import '../utils/folder_label.dart';
import '../utils/serial_task_queue.dart';
import '../utils/name_sort.dart';
import '../widgets/confirm_delete_dialog.dart';
import '../widgets/folder_name_dialog.dart';
import '../widgets/folder_tile.dart';
import '../app.dart';
import 'bundle_folder_screen.dart';
import 'card_edit_screen.dart';
import 'card_list_screen.dart';
import 'export_screen.dart';
import 'file_list_screen.dart';
import 'import_screen.dart';
import 'multi_import_screen.dart';
import 'lock_screen_settings.dart';
import 'push_notification_settings.dart';
import 'settings_screen.dart';
import '../services/import_export_controller.dart';
import '../services/lock_screen_service.dart';
import '../services/notification_service.dart';

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
  /// 서랍 요약용 폴더 총 개수(묶음 포함, 홈에서 감춘 자식도 포함).
  int _totalFolderCount = 0;
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
    if (_isDeleting) return; // 삭제 중 옵티미스틱 UI 덮어쓰기 방지
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
    // .memk / .mra 파일 찾기 (없으면 null)
    SharedMediaFile? importFile;
    for (final f in files) {
      if (f.path.endsWith('.memk') || f.path.endsWith('.mra')) {
        importFile = f;
        break;
      }
    }
    final t = AppLocalizations.of(context);
    if (importFile != null) {
      // 편집 화면이나 다른 import 화면이 열려 있으면 그 위에 import를 얹지 않는다 — 다른
      // 진입점(알림 탭·잠금화면 딥링크)은 전부 isOpen 가드가 있는데 공유 수신만 없었다.
      // (열린 ImportScreen 위에 두 번째가 서면 static isOpen이 오염되고 공용 ZIP 캐시가
      // 지워져 바깥 화면이 재디코딩한다.)
      if (ImportScreen.isOpen || CardEditScreen.isOpen) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.importBusy)),
        );
        return;
      }
      // 시스템 파일 앱(DocumentsUI)에서 "열기"로 들어오면 플러그인이 캐시 복사 없이
      // /storage/emulated/0/... 원시 경로를 돌려주는데 이 앱은 그 경로를 읽을 권한이 없다
      // (X6-06). 여기서 걸러 우회로(공유·가져오기 버튼)를 안내한다.
      if (!_isReadableFile(importFile.path)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.homeSharedFileUnreadable)),
        );
        return;
      }
      _navigateToImport(importFile.path);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.homeOnlyMemkSnack)),
      );
    }
  }

  int _folderLoadGen = 0;

  Future<void> _loadFolders() async {
    // 세대 토큰 — 로드 중에 정렬을 바꾸면 늦게 끝난 옛 로드가 저장돼 있던 옛 정렬로
    // 화면을 되돌렸다(DB엔 새 값, 화면엔 옛 값 — X2-05).
    final gen = ++_folderLoadGen;
    try {
      final allFolders = await DatabaseHelper.instance.getAllFolders();
      // 총 카드 수는 숨김과 무관하게 전부 센다 — 묶음 안의 카드도 내 카드다.
      final totalCards = allFolders.fold<int>(0, (sum, f) => sum + f.cardCount);
      // 서랍 요약의 폴더 수도 카드 수와 같이 라이브러리 전체 기준이다. 화면에 보이는
      // 개수를 쓰면 묶음을 만든 순간 "10장 · 2폴더"처럼 카드는 전체, 폴더는 화면
      // 기준이 되어 두 숫자가 서로 다른 것을 센다(기기 검증에서 확인).
      final totalFolders = allFolders.length;
      // 묶음에 들어간 폴더는 최상위 목록에서 감춘다. 묶음 타일을 눌러 그 안에서 본다
      // — 예전엔 묶음과 그 자식이 홈에 나란히 떠서 같은 폴더가 두 번 보였다.
      //
      // 실제로 존재하는 묶음의 자식만 감춘다. parent_folder_id가 없는 묶음을 가리키는
      // 고아 폴더(중간에 프로세스가 죽는 등)를 그냥 숨기면 홈에서도 묶음 화면에서도
      // 닿을 수 없는 폴더가 된다 — 그런 폴더는 최상위로 보여준다.
      final bundleIds = allFolders
          .where((f) => f.isBundle && f.id != null)
          .map((f) => f.id!)
          .toSet();
      final folders = allFolders
          .where((f) =>
              f.parentFolderId == null || !bundleIds.contains(f.parentFolderId))
          .toList();
      final settings = await DatabaseHelper.instance.getAllSettings();
      final savedSort = settings[_sortModeKey];
      if (!mounted || gen != _folderLoadGen) return;
      setState(() {
        if (savedSort != null) _sortMode = savedSort;
        _folders = _sortFolders(folders);
        _totalCardCount = totalCards;
        _totalFolderCount = totalFolders;
        _loading = false;
      });
    } catch (e) {
      debugPrint('[HOME] _loadFolders 오류: $e');
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  List<Folder> _sortFolders(List<Folder> folders) {
    final sorted = List<Folder>.from(folders);
    switch (_sortMode) {
      case 'name_asc':
        sorted.sort((a, b) => compareNamesForSort(a.name, b.name));
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
    final t = AppLocalizations.of(context);
    // 홈 목록(_folders)은 묶음 자식을 감추므로 여기선 쓰지 않는다 — 묶음 안 폴더에도
    // 카드를 새로 만들 수 있어야 한다. DB에서 묶음이 아닌 폴더 전부를 다시 읽는다.
    final List<Folder> nonBundleFolders;
    try {
      nonBundleFolders = await DatabaseHelper.instance.getNonBundleFolders();
    } catch (e) {
      debugPrint('[HOME] folder picker load failed: $e');
      return;
    }
    if (!mounted) return;
    if (nonBundleFolders.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.homeNoFolderFirst)),
      );
      return;
    }
    final selected = await showDialog<Folder>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(t.homePickerCardFolderTitle),
        children: nonBundleFolders.map((folder) {
          return SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, folder),
            child: Text(
                '${folderDisplayPath(folder)} (${t.cardCountSuffix(folder.cardCount)})'),
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
    final t = AppLocalizations.of(context);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.note_add),
              title: Text(t.homeFabAddCard,
                  style: const TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(ctx);
                _showFolderPickerForNewCard();
              },
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder),
              title: Text(t.homeFabCreateFolder,
                  style: const TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(ctx);
                _createFolder();
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_special),
              title: Text(t.homeFabCreateBundle,
                  style: const TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(ctx);
                _navigateToBundleFolder();
              },
            ),
            ListTile(
              leading: const Icon(Icons.file_download),
              title: Text(t.homeFabImportFile,
                  style: const TextStyle(fontSize: 14)),
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

  /// ⚠️ 예전엔 여기 스코프에 클로저 변수로 `TextEditingController`를 만들고
  /// `try { showDialog(...) } finally { controller.dispose(); }`로 정리했었다 —
  /// push_notification_settings.dart의 `_PushRuleDialog` 문서에 적힌 것과 동일한
  /// '_dependents.isEmpty' 크래시 위험 패턴(Navigator.pop()의 popped Future가 퇴장
  /// 애니메이션 완료보다 먼저 끝나, 아직 리빌드 중인 TextField가 dispose된 controller를
  /// 참조). 지금은 controller를 [FolderNameDialog]의 State가 소유해 dispose()가
  /// Element unmount 시점에만 불리도록 고쳤다.
  Future<void> _createFolder() async {
    final t = AppLocalizations.of(context);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => FolderNameDialog(
        title: t.homeNewFolderTitle,
        hint: t.homeFolderNameHint,
        confirmLabel: t.commonCreate,
      ),
    );
    if (name == null || name.isEmpty) return;

    final existing = await DatabaseHelper.instance.getFolderByName(name);
    if (existing != null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.homeFolderExists(name))),
      );
      return;
    }

    try {
      final maxSeq = await DatabaseHelper.instance.getMaxFolderSequence();
      final folder = Folder(name: name, sequence: maxSeq + 1);
      await DatabaseHelper.instance.insertFolder(folder);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.homeFolderCreateFail(name))),
      );
      return;
    }
    await _loadFolders();
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



  /// 같은 크래시 클래스에 대한 고침 — [_createFolder] 위 주석 참고.
  Future<void> _renameFolder(Folder folder) async {
    final t = AppLocalizations.of(context);
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => FolderNameDialog(
        title: t.homeRenameFolderTitle,
        hint: t.homeNewNameHint,
        confirmLabel: t.commonChange,
        initialName: folder.name,
      ),
    );
    if (newName == null || newName.isEmpty || newName == folder.name) return;

    final existing = await DatabaseHelper.instance.getFolderByName(newName);
    if (existing != null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.homeFolderExists(newName))),
      );
      return;
    }

    // 이름만 UPDATE — 스냅샷 전체 되쓰기는 옛 card_count/parent_folder_id를 덮었다(D1-03).
    // 실패는 생성 경로와 같이 알린다(D1-05: 예전엔 무음).
    try {
      await DatabaseHelper.instance.renameFolder(folder.id!, newName);
    } catch (e) {
      debugPrint('[HOME] rename folder failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.homeFolderRenameFail)),
      );
      return;
    }
    if (!mounted) return;
    await _loadFolders();
  }

  static bool _isReadableFile(String path) {
    try {
      File(path).openSync().closeSync();
      return true;
    } catch (_) {
      return false;
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
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) return;

      final validPaths = <String>[];
      for (final file in result.files) {
        final p = file.path;
        if (p == null) continue;
        if (p.endsWith('.memk') || p.endsWith('.mra')) {
          validPaths.add(p);
        }
      }

      if (validPaths.isEmpty) {
        if (!mounted) return;
        final t = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.homeOnlyMemkPickSnack)),
        );
        return;
      }

      if (validPaths.length == 1) {
        await _navigateToImport(validPaths.first);
      } else {
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => MultiImportScreen(filePaths: validPaths),
          ),
        );
        if (mounted) _loadFolders();
      }
    } catch (e) {
      if (mounted) {
        final t = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.homeFilePickFail(e.toString()))),
        );
      }
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
        // 로컬 객체도 바로 맞춘다 — 리로드 전에 두 번째 드래그가 오면 옛 sequence와 비교해
        // 필요한 UPDATE를 건너뛰어 두 번째 이동이 조용히 되돌아갔다(D1-04).
        _folders[i] = folder.copyWith(sequence: i);
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
    if (_isDeleting) return; // 재진입 가드 (삭제 아이콘 연타 방지)
    final t = AppLocalizations.of(context);
    // import가 도는 동안 대상 폴더를 지우면 배치 insert가 FK로 실패해 그 파일의 카드가
    // 통째로 빠진다(D1-02) — 서비스 쪽 방어와 별개로 진입 자체를 막는다.
    if (ImportExportController.instance.isBusy) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.importBusy)),
      );
      return;
    }
    final selected =
        _folders.where((f) => _selectedFolderIds.contains(f.id)).toList();
    if (selected.isEmpty) return;

    final totalCards = selected
        .where((f) => !f.isBundle)
        .fold<int>(0, (sum, f) => sum + f.cardCount);
    final hasBundles = selected.any((f) => f.isBundle);

    String message = t.homeDeleteFolderConfirm(selected.length);
    if (totalCards > 0) {
      message += t.homeDeleteFolderCardsNote(totalCards);
    }
    if (hasBundles) {
      message += t.homeDeleteFolderBundleNote;
    }

    // 다이얼로그 pop 시 didPopNext의 _loadFolders가 옵티미스틱 삭제를
    // 덮어쓰지 않도록 가드를 showDialog 전에 켠다.
    _isDeleting = true;

    final confirmed = await confirmDelete(
      context,
      title: t.homeDeleteFolderTitle,
      message: message,
    );
    if (!confirmed) {
      _isDeleting = false;
      return;
    }

    // Optimistic UI update.
    // 합계는 화면 목록에서 다시 세지 않고 "지운 만큼 뺀다" — 목록은 묶음 자식을
    // 감추므로 다시 세면 묶음 안의 카드가 통째로 빠진 숫자가 나온다.
    // 묶음을 지우면 자식은 삭제되지 않고 최상위로 올라오므로, 묶음 자체가 들고 있는
    // 카드 수(0)만 빠지는 것이 맞다. 어차피 아래 _loadFolders()가 곧 정정한다.
    final removedCards =
        selected.fold<int>(0, (sum, f) => sum + f.cardCount);
    setState(() {
      _folders.removeWhere((f) => _selectedFolderIds.contains(f.id));
      _totalCardCount =
          (_totalCardCount - removedCards).clamp(0, _totalCardCount);
      _totalFolderCount =
          (_totalFolderCount - selected.length).clamp(0, _totalFolderCount);
    });

    try {
      final regularFolders = selected.where((f) => !f.isBundle).toList();
      final bundleFolders = selected.where((f) => f.isBundle).toList();
      final regularIds = regularFolders.map((f) => f.id!).toList();
      final bundleIds = bundleFolders.map((f) => f.id!).toList();

      // ⚡ 즉시 atomic transaction — IN 절 기반 3 statements, 수백 ms 안에 commit.
      //   이게 commit되는 순간 사용자 시점에선 "다 지워짐" 끝. swipe할 틈 없음.
      final deleteResult = await DatabaseHelper.instance.deleteFoldersBatch(
        regularFolderIds: regularIds,
        bundleFolderIds: bundleIds,
      );

      // 🔄 사후 비동기 cleanup — fire-and-forget.
      //   transaction은 이미 commit됨 → 사용자가 swipe해도 폴더는 영구 사라짐.
      //   image/voice 파일이 일부 남으면 orphan resource (디스크만 차지, 동작엔 무관).
      //   잠금화면 prefs / push 재스케줄 / 미디어 파일 삭제를 한 번에 fire-and-forget.
      unawaited(_cleanupAfterFolderDelete(
        regularIds: regularIds,
        needsPushReschedule: deleteResult.pushReschedNeeded,
        filePaths: deleteResult.filePaths,
      ));
    } catch (e) {
      debugPrint('[HOME] delete selected folders error: $e');
      if (mounted) await _loadFolders(); // 옵티미스틱 UI 롤백
    } finally {
      _isDeleting = false;
      if (mounted) {
        setState(() => _selectedFolderIds.clear());
      } else {
        _selectedFolderIds.clear();
      }
    }

    if (!mounted) return;
    await _loadFolders();
  }

  Future<void> _cleanupAfterFolderDelete({
    required List<int> regularIds,
    required bool needsPushReschedule,
    required List<String> filePaths,
  }) async {
    final pruned = await cleanupAfterFolderDelete(
      regularIds: regularIds,
      needsPushReschedule: needsPushReschedule,
      filePaths: filePaths,
    );
    if (!mounted) return;
    showPushRulesRemovedNotice(context, pruned);
  }

  void _exportSelectedFolders() {
    final nonBundleIds = _folders
        .where((f) => _selectedFolderIds.contains(f.id) && !f.isBundle)
        .map((f) => f.id!)
        .toList();
    final t = AppLocalizations.of(context);
    if (nonBundleIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.homeNoExportable)),
      );
      return;
    }
    // 묶음은 카드를 직접 갖지 않아 내보내기 대상이 아니다. 섞여 있으면 조용히 빠뜨리지 않고
    // 몇 개가 제외됐는지 알린다(감사 D1-03).
    final skipped = _selectedFolderIds.length - nonBundleIds.length;
    if (skipped > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.homeExportBundlesSkipped(skipped))),
      );
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
        // Export/Import 진행 중이면 앱을 종료하지 않고 백그라운드로 보냄 (다중 import 배치는
        // 파일 사이 틈에 isRunning이 잠깐 false라 isBusy로 본다)
        if (ImportExportController.instance.isBusy) {
          const MethodChannel('com.henry.memora/import_export')
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
                  Builder(builder: (context) {
                    final t = AppLocalizations.of(context);
                    return PopupMenuButton<String>(
                      icon: const Icon(Icons.sort),
                      tooltip: t.homeSortTooltip,
                      onSelected: _changeSortMode,
                      itemBuilder: (_) => [
                        _sortMenuItem(t.homeSortManual, 'sequence'),
                        _sortMenuItem(t.homeSortNameAsc, 'name_asc'),
                        _sortMenuItem(t.homeSortOldest, 'oldest'),
                        _sortMenuItem(t.homeSortNewest, 'newest'),
                      ],
                    );
                  }),
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
                            Text(AppLocalizations.of(context).homeNoFolders,
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
              ModalBarrier(
                  dismissible: false,
                  color: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.32)),
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(AppLocalizations.of(context).homeFilePreparing),
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
    final t = AppLocalizations.of(context);
    final allSelected = _selectedFolderIds.length == _folders.length;
    final selectedList =
        _folders.where((f) => _selectedFolderIds.contains(f.id)).toList();
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _clearSelection,
      ),
      title: Text(t.homeSelectedCount(_selectedFolderIds.length)),
      actions: [
        IconButton(
          icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
          tooltip: allSelected ? t.homeDeselectAll : t.homeSelectAll,
          onPressed: _selectAllFolders,
        ),
        IconButton(
          icon: const Icon(Icons.file_upload),
          tooltip: t.commonExport,
          onPressed: _exportSelectedFolders,
        ),
        IconButton(
          icon: const Icon(Icons.delete),
          tooltip: t.commonDelete,
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
              PopupMenuItem(
                value: 'rename',
                child: Text(t.commonRename),
              ),
              if (selectedList.first.isBundle)
                PopupMenuItem(
                  value: 'edit_bundle',
                  child: Text(t.homeBundleEdit),
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
    final t = AppLocalizations.of(context);
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
                  t.homeDrawerSummary(_totalCardCount, _totalFolderCount),
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
            title: Text(t.homeAllCards, style: const TextStyle(fontSize: 14)),
            onTap: () async {
              Navigator.pop(context);
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => CardListScreen(
                    folder: Folder(name: t.homeAllCardsTitle),
                    allCards: true,
                  ),
                ),
              );
              if (mounted) _loadFolders();
            },
          ),
          ListTile(
            leading: const Icon(Icons.notifications),
            title: Text(t.homePushAlarm, style: const TextStyle(fontSize: 14)),
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
            title: Text(t.homeLockScreen, style: const TextStyle(fontSize: 14)),
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
            title: Text(t.homeSettings, style: const TextStyle(fontSize: 14)),
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
            title: Text(t.homeMakeFile, style: const TextStyle(fontSize: 14)),
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
            title: Text(t.homeFileList, style: const TextStyle(fontSize: 14)),
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
/// 폴더 삭제 transaction commit 후 사후 정리. 모두 idempotent이고, 호출자는
/// fire-and-forget으로 돌린다(트랜잭션은 이미 commit됐다).
/// image/voice 파일 삭제도 여기서 처리 — deleteFoldersBatch가 삭제 전에 수집해 넘겨준 경로.
///
/// 삭제된 폴더의 미디어 파일 중 다른 폴더의 카드가 아직 참조하는 것은 남긴다 —
/// 레거시 .memk import나 카드 복제로 여러 카드가 같은 파일을 가리킬 수 있어서, 폴더
/// 하나를 지웠다고 남의 카드 이미지를 뺏으면 안 된다(카드 삭제 경로와 같은 규칙).
/// 재생 중인 파일 정지도 그 안에서 함께 처리한다(감사 D2-07).
///
/// 반환값은 이번 삭제로 사라진 푸시 규칙 정보다 — 호출 화면이
/// [showPushRulesRemovedNotice]로 사용자에게 알린다. 홈과 묶음 화면이 같이 쓴다.
Future<({int removedRules, bool pushDisabled, bool lockScreenDisabled})>
    cleanupAfterFolderDelete({
  required List<int> regularIds,
  required bool needsPushReschedule,
  required List<String> filePaths,
}) async {
  // 이 정리는 홈과 묶음 화면에서 fire-and-forget으로 시작될 수 있다. 안에서 하는 일이
  // "설정을 읽고 → 고치고 → 되쓰기"라, 겹치면 늦게 끝난 쪽이 앞의 것을 덮어써 이미
  // 지운 폴더를 가리키는 규칙이 되살아난다(스윕 L-02). 그래서 줄을 세운다.
  //
  // 줄 세우기에는 틀리기 쉬운 규칙 네 가지가 있고, 실제로 다섯 번 잘못 고쳤다.
  // 그 규칙과 회귀 테스트는 SerialTaskQueue에 박아 뒀다 — 손대기 전에 그쪽을 읽을 것.
  //
  // round7: 큐 자리에 5분 백스톱(queueBackstop)을 둔다 — 네이티브가 영영 답을 안
  // 주는 최악의 경우 이후 모든 정리가 큐에 영구히 쌓이는 걸 막기 위해서다(2라운드
  // 회귀와 같은 모양). 하지만 백스톱은 뒤늦게 깨어난 옛 작업을 고아로 만든다 — 그
  // 고아가 LockScreenService.removeFoldersFromSettingsBatch의 쓰기까지 그대로
  // 밀고 가면, 옛 스냅샷으로 이미 끝난 더 최신 정리의 결과를 덮어쓴다(리뷰 R6-1).
  // 푸시 규칙 쪽(removeFoldersFromPushSchedule)은 sqflite 트랜잭션으로 막았지만
  // 여기는 SharedPreferences MethodChannel이라 그럴 수 없다. 그래서 세대 번호를
  // 넘겨 [_cleanupAfterFolderDeleteImpl]이 쓰기 직전에 자신이 여전히
  // [_cleanupQueue.activeGeneration]인지 확인하고, 아니면 스스로 물러나게 한다.
  return _cleanupQueue.run(
    (generation) => _cleanupAfterFolderDeleteImpl(
      regularIds: regularIds,
      needsPushReschedule: needsPushReschedule,
      filePaths: filePaths,
      isStale: () => _cleanupQueue.activeGeneration != generation,
    ),
    timeout: const Duration(seconds: 30),
    queueBackstop: const Duration(minutes: 5),
    onTimeout: () =>
        (removedRules: 0, pushDisabled: false, lockScreenDisabled: false),
    onError: (e) => debugPrint('[HOME] post-delete cleanup failed: $e'),
  );
}

/// 폴더 삭제 사후정리 전용 큐. 홈과 묶음 화면이 같은 설정을 건드리므로 하나만 둔다.
final SerialTaskQueue _cleanupQueue = SerialTaskQueue();

Future<({int removedRules, bool pushDisabled, bool lockScreenDisabled})>
    _cleanupAfterFolderDeleteImpl({
  required List<int> regularIds,
  required bool needsPushReschedule,
  required List<String> filePaths,
  required bool Function() isStale,
}) async {
  try {
    // batch helper: settings read 1회 + write 1회로 N회 I/O 압축. isStale은 큐
    // 백스톱이 이 호출을 고아로 만들었을 때(round7) 옛 스냅샷으로 더 최신 정리의
    // 결과를 덮어쓰지 않도록 쓰기 직전에 확인하는 용도다.
    final lockScreenDisabled = await LockScreenService
        .removeFoldersFromSettingsBatch(regularIds, isStale: isStale);
    // needsPushReschedule 플래그와 무관하게 항상 호출 — 그 플래그는
    // push_alarms.folder_id(전역 기본 폴더)만 추적해서, 푸시 시간대 슬롯에만
    // 걸린 삭제(기본 폴더는 안 건드리고 슬롯 하나가 가리키던 폴더만 지운 경우)를
    // 놓친다.
    final pruned =
        await NotificationService.removeFoldersFromPushSchedule(regularIds);
    if (needsPushReschedule) {
      await NotificationService.rescheduleAll();
    }
    await DatabaseHelper.instance.deleteUnreferencedMediaFiles(filePaths);
    return (
      removedRules: pruned.removedRules,
      pushDisabled: pruned.pushDisabled,
      lockScreenDisabled: lockScreenDisabled,
    );
  } catch (e) {
    debugPrint('[HOME] post-delete cleanup error: $e');
    return (removedRules: 0, pushDisabled: false, lockScreenDisabled: false);
  }
}

/// 폴더를 지우면 그 폴더를 가리키던 알림 시간대도 함께 사라진다 — 예전엔 아무 말 없이
/// 사라져서, 알림이 안 오는 이유를 사용자가 알 수 없었다.
void showPushRulesRemovedNotice(
    BuildContext context,
    ({int removedRules, bool pushDisabled, bool lockScreenDisabled}) pruned) {
  // ⚠️ `ModalRoute.isCurrent`로 거르지 않는다. 다이얼로그나 바텀시트가 하나라도
  // 떠 있으면 그 순간 isCurrent가 false가 되는데, 이 안내는 한 번뿐이라 그대로
  // 영영 사라진다. 늦게 뜨는 것보다 안 뜨는 게 나쁘다 — 억압은 중복보다 나쁘다는
  // 이 저장소의 규칙을 내가 어겼었다(리뷰 R2-C).
  final t = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  if (pruned.removedRules > 0) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(pruned.pushDisabled
            ? t.homePushRulesRemovedAllOff(pruned.removedRules)
            : t.homePushRulesRemoved(pruned.removedRules)),
      ),
    );
  }
  // 잠금화면도 같은 규칙으로 알린다 — 조용히 꺼지면 사용자가 이유를 알 수 없다.
  if (pruned.lockScreenDisabled) {
    messenger.showSnackBar(
      SnackBar(content: Text(t.homeLockScreenTurnedOff)),
    );
  }
}

class _BundleChildListScreen extends StatefulWidget {
  final Folder bundle;

  const _BundleChildListScreen({required this.bundle});

  @override
  State<_BundleChildListScreen> createState() => _BundleChildListScreenState();
}

class _BundleChildListScreenState extends State<_BundleChildListScreen> {
  List<Folder> _children = [];
  bool _loading = true;
  final Set<int> _selectedIds = {};
  bool get _isSelecting => _selectedIds.isNotEmpty;
  bool _isDeleting = false;

  @override
  void initState() {
    super.initState();
    _loadChildren();
  }

  Future<void> _loadChildren() async {
    final List<Folder> children;
    try {
      children =
          await DatabaseHelper.instance.getChildFolders(widget.bundle.id!);
    } catch (e) {
      debugPrint('[BUNDLE] load children failed: $e');
      if (!mounted) return;
      setState(() => _loading = false);
      return;
    }
    if (!mounted) return;
    setState(() {
      _children = children;
      // 사라진 폴더가 선택된 채 남으면 유령 선택이 된다 — 삭제 후 리로드에서 걷어낸다.
      final ids = children.map((f) => f.id).toSet();
      _selectedIds.removeWhere((id) => !ids.contains(id));
      _loading = false;
    });
  }

  void _toggleSelection(int id) {
    setState(() {
      if (!_selectedIds.remove(id)) _selectedIds.add(id);
    });
  }

  void _clearSelection() => setState(() => _selectedIds.clear());

  void _selectAll() {
    setState(() {
      if (_selectedIds.length == _children.length) {
        _selectedIds.clear();
      } else {
        _selectedIds
          ..clear()
          ..addAll(_children.where((f) => f.id != null).map((f) => f.id!));
      }
    });
  }

  void _onReorder(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) newIndex--;
    setState(() {
      final folder = _children.removeAt(oldIndex);
      _children.insert(newIndex, folder);
    });
    () async {
      try {
        final updates = <int, int>{};
        for (var i = 0; i < _children.length; i++) {
          final folder = _children[i];
          if (folder.sequence != i && folder.id != null) {
            updates[folder.id!] = i;
            // 리로드 전에 두 번째 드래그가 와도 옛 sequence와 비교하지 않도록 로컬도
            // 바로 맞춘다(홈 화면 _updateFolderSequences와 같은 이유 — D1-04).
            _children[i] = folder.copyWith(sequence: i);
          }
        }
        if (updates.isNotEmpty) {
          await DatabaseHelper.instance.updateFolderSequencesBatch(updates);
        }
      } catch (e) {
        debugPrint('[BUNDLE] reorder error: $e');
      } finally {
        if (mounted) _loadChildren();
      }
    }();
  }

  Future<void> _renameSelected() async {
    final selected =
        _children.where((f) => _selectedIds.contains(f.id)).toList();
    if (selected.length != 1) return;
    final folder = selected.first;
    final t = AppLocalizations.of(context);
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => FolderNameDialog(
        title: t.homeRenameFolderTitle,
        hint: t.homeNewNameHint,
        confirmLabel: t.commonChange,
        initialName: folder.name,
      ),
    );
    if (newName == null || newName.isEmpty || newName == folder.name) return;

    final existing = await DatabaseHelper.instance.getFolderByName(newName);
    if (!mounted) return;
    if (existing != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.homeFolderExists(newName))),
      );
      return;
    }
    try {
      await DatabaseHelper.instance.renameFolder(folder.id!, newName);
    } catch (e) {
      debugPrint('[BUNDLE] rename failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.homeFolderRenameFail)),
      );
      return;
    }
    if (!mounted) return;
    _clearSelection();
    await _loadChildren();
  }

  Future<void> _deleteSelected() async {
    if (_isDeleting) return;
    final t = AppLocalizations.of(context);
    // 홈 화면과 같은 가드 — import가 도는 동안 대상 폴더를 지우면 배치 insert가 FK로
    // 실패해 그 파일의 카드가 통째로 빠진다(D1-02). 묶음 자식도 병합 대상이 될 수 있어
    // 같은 사고가 난다(리뷰 B-01).
    if (ImportExportController.instance.isBusy) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.importBusy)),
      );
      return;
    }
    final selected =
        _children.where((f) => _selectedIds.contains(f.id)).toList();
    if (selected.isEmpty) return;
    final cardTotal = selected.fold<int>(0, (sum, f) => sum + f.cardCount);
    var message = t.homeDeleteFolderConfirm(selected.length);
    if (cardTotal > 0) message += t.homeDeleteFolderCardsNote(cardTotal);

    _isDeleting = true;
    final confirmed = await confirmDelete(
      context,
      title: t.homeDeleteFolderTitle,
      message: message,
    );
    if (!confirmed) {
      _isDeleting = false;
      return;
    }

    final ids = selected.map((f) => f.id!).toList();
    setState(() {
      _children.removeWhere((f) => ids.contains(f.id));
      _selectedIds.clear();
    });
    try {
      final result = await DatabaseHelper.instance.deleteFoldersBatch(
        regularFolderIds: ids,
        bundleFolderIds: const [],
      );
      // 홈과 같이 fire-and-forget — 미디어 파일 I/O를 기다리느라 삭제 버튼이 몇 초
      // 먹통처럼 보이지 않게 한다(트랜잭션은 이미 commit됐다).
      unawaited(_cleanupAfterDelete(ids, result));
    } catch (e) {
      debugPrint('[BUNDLE] delete failed: $e');
    } finally {
      _isDeleting = false;
      if (mounted) await _loadChildren();
    }
  }

  Future<void> _cleanupAfterDelete(List<int> ids,
      ({bool pushReschedNeeded, List<String> filePaths}) result) async {
    final pruned = await cleanupAfterFolderDelete(
      regularIds: ids,
      needsPushReschedule: result.pushReschedNeeded,
      filePaths: result.filePaths,
    );
    if (!mounted) return;
    showPushRulesRemovedNotice(context, pruned);
  }

  AppBar _buildSelectionAppBar(AppLocalizations t) {
    final allSelected = _selectedIds.length == _children.length;
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _clearSelection,
      ),
      title: Text(t.homeSelectedCount(_selectedIds.length)),
      actions: [
        IconButton(
          icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
          tooltip: allSelected ? t.homeDeselectAll : t.homeSelectAll,
          onPressed: _selectAll,
        ),
        IconButton(
          icon: const Icon(Icons.delete),
          tooltip: t.commonDelete,
          onPressed: _deleteSelected,
        ),
        if (_selectedIds.length == 1)
          IconButton(
            icon: const Icon(Icons.drive_file_rename_outline),
            tooltip: t.commonRename,
            onPressed: _renameSelected,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return PopScope(
      // 선택 중이면 뒤로가기가 화면을 닫는 대신 선택부터 푼다(홈 화면과 같은 규칙).
      canPop: !_isSelecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _clearSelection();
      },
      child: Scaffold(
        appBar: _isSelecting
            ? _buildSelectionAppBar(t)
            : AppBar(title: Text(widget.bundle.name)),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _children.isEmpty
                ? Center(child: Text(t.homeNoChildren))
                : _isSelecting
                    ? ListView.builder(
                        itemCount: _children.length,
                        itemBuilder: (context, index) {
                          final folder = _children[index];
                          return FolderTile(
                            key: ValueKey(folder.id),
                            folder: folder,
                            isSelecting: true,
                            isSelected: _selectedIds.contains(folder.id),
                            onTap: () {
                              if (folder.id != null) {
                                _toggleSelection(folder.id!);
                              }
                            },
                          );
                        },
                      )
                    : ReorderableListView.builder(
                        itemCount: _children.length,
                        onReorder: _onReorder,
                        buildDefaultDragHandles: false,
                        itemBuilder: (context, index) {
                          final folder = _children[index];
                          return FolderTile(
                            key: ValueKey(folder.id),
                            folder: folder,
                            reorderIndex: index,
                            onTap: () async {
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      CardListScreen(folder: folder),
                                ),
                              );
                              if (mounted) await _loadChildren();
                            },
                            onLongPress: () {
                              if (folder.id != null) {
                                _toggleSelection(folder.id!);
                              }
                            },
                          );
                        },
                      ),
      ),
    );
  }
}
