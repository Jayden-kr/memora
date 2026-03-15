import 'package:flutter/material.dart';

import '../database/database_helper.dart';
import '../models/folder.dart';
import '../services/import_export_controller.dart';

class ImportScreen extends StatefulWidget {
  final String filePath;
  final bool progressOnly;

  /// 현재 ImportScreen이 열려 있는지 추적 (알림 탭 중복 방지)
  static bool isOpen = false;

  const ImportScreen({
    required this.filePath,
    this.progressOnly = false,
    super.key,
  });

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

enum _ImportStage { loading, folderSelect, importing, done, error }

class _ImportScreenState extends State<ImportScreen> {
  final _controller = ImportExportController.instance;

  _ImportStage _stage = _ImportStage.loading;
  String? _stableFilePath; // 안정적 접근을 위한 임시 복사본 경로
  List<Map<String, dynamic>> _memkFolders = [];
  final Set<String> _selectedFolderNames = {};

  // 가져올 위치
  bool _useExistingFolder = false;
  List<Folder> _localFolders = [];
  final Map<int, int> _folderMapping = {}; // memk folderId → local folderId

  // 에러
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    ImportScreen.isOpen = true;
    _controller.addListener(_onControllerUpdate);
    _loadData();
  }

  @override
  void dispose() {
    ImportScreen.isOpen = false;
    _controller.removeListener(_onControllerUpdate);
    // Import 미시작 시 캐시 메모리 해제 (import 시작 후에는 이미 소비됨)
    if (_stage != _ImportStage.importing) {
      _controller.importService.clearCache();
    }
    super.dispose();
  }

  void _onControllerUpdate() {
    if (!mounted) return;
    setState(() {
      if (_controller.isRunning && _controller.currentOperation == 'import') {
        _stage = _ImportStage.importing;
      } else if (!_controller.isRunning &&
          _controller.lastImportResult != null &&
          _stage == _ImportStage.importing) {
        _stage = _ImportStage.done;
      }
    });
  }

  Future<void> _loadData() async {
    // 알림 탭으로 열린 경우: 파일 분석 없이 현재 컨트롤러 상태 표시
    if (widget.progressOnly) {
      if (_controller.isRunning && _controller.currentOperation == 'import') {
        setState(() => _stage = _ImportStage.importing);
      } else if (_controller.lastImportResult != null) {
        setState(() => _stage = _ImportStage.done);
      } else {
        // Import 상태 없음 — 홈으로 돌아감
        if (mounted) Navigator.pop(context);
      }
      return;
    }

    try {
      // file_picker가 이미 캐시에 복사한 파일을 직접 사용 (중복 복사 제거)
      _stableFilePath = widget.filePath;

      // 컨트롤러의 importService 사용 (Archive 캐시 공유)
      final memkFolders =
          await _controller.importService.readFolderList(widget.filePath);
      final localFolders =
          await DatabaseHelper.instance.getNonBundleFolders();
      if (!mounted) return;
      setState(() {
        _memkFolders = memkFolders;
        _localFolders = localFolders;
        _selectedFolderNames
            .addAll(memkFolders.map((f) => (f['name'] as String?) ?? ''));
        _stage = _ImportStage.folderSelect;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _ImportStage.error;
        _errorMessage = '파일을 읽을 수 없습니다: $e';
      });
    }
  }

  Future<void> _startImport() async {
    if (_selectedFolderNames.isEmpty) return;

    setState(() => _stage = _ImportStage.importing);

    // folderMapping 구성 (기존 폴더 선택 모드)
    // 매핑되지 않은 폴더는 null → 서비스에서 자동 새 폴더 생성
    Map<int, int?>? mapping;
    if (_useExistingFolder) {
      mapping = {};
      for (final f in _memkFolders) {
        final memkId = (f['id'] as num?)?.toInt();
        if (memkId != null && _selectedFolderNames.contains(f['name'])) {
          mapping[memkId] = _folderMapping[memkId]; // null이면 새 폴더 생성
        }
      }
    }

    try {
      await _controller.startImport(
        filePath: _stableFilePath ?? widget.filePath,
        selectedFolderNames: _selectedFolderNames.toList(),
        folderMapping: mapping,
      );
      // 완료 시 controller listener가 _stage을 done으로 설정
    } catch (e) {
      if (mounted) {
        setState(() {
          _stage = _ImportStage.error;
          _errorMessage = 'Import 실패: $e';
        });
      }
    }
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selectedFolderNames.length == _memkFolders.length) {
        _selectedFolderNames.clear();
      } else {
        _selectedFolderNames.clear();
        _selectedFolderNames.addAll(
          _memkFolders.map((f) => (f['name'] as String?) ?? ''),
        );
      }
    });
  }

  Future<void> _createNewLocalFolder() async {
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
    final localFolders =
        await DatabaseHelper.instance.getNonBundleFolders();
    if (!mounted) return;
    setState(() => _localFolders = localFolders);
    } finally {
      controller.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Import'),
        leading: _stage == _ImportStage.importing
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  // Import 중에도 나갈 수 있음 (백그라운드에서 계속 진행)
                  Navigator.pop(context);
                },
              )
            : null,
      ),
      body: switch (_stage) {
        _ImportStage.loading => _buildLoading(),
        _ImportStage.folderSelect => _buildFolderSelect(),
        _ImportStage.importing => _buildImporting(),
        _ImportStage.done => _buildDone(),
        _ImportStage.error => _buildError(),
      },
    );
  }

  Widget _buildLoading() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('파일 분석 중...'),
        ],
      ),
    );
  }

  Widget _buildFolderSelect() {
    final allSelected = _selectedFolderNames.length == _memkFolders.length;
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // .memk 내부 폴더 선택
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Text('.memk 폴더 ${_memkFolders.length}개',
                          style: Theme.of(context).textTheme.titleMedium),
                      const Spacer(),
                      TextButton(
                        onPressed: _toggleSelectAll,
                        child: Text(allSelected ? '전체 해제' : '전체 선택'),
                      ),
                    ],
                  ),
                ),
                ..._memkFolders.map((folder) {
                  final name = (folder['name'] as String?) ?? '';
                  final cardCount = folder['cardCount'] as int? ?? 0;
                  final isSelected = _selectedFolderNames.contains(name);
                  return CheckboxListTile(
                    title: Text(name),
                    subtitle: Text('$cardCount장'),
                    value: isSelected,
                    onChanged: (checked) {
                      setState(() {
                        if (checked == true) {
                          _selectedFolderNames.add(name);
                        } else {
                          _selectedFolderNames.remove(name);
                        }
                      });
                    },
                  );
                }),

                const Divider(height: 32),

                // 가져올 위치 선택
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text('가져올 위치',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                RadioGroup<bool>(
                  groupValue: _useExistingFolder,
                  onChanged: (v) =>
                      setState(() => _useExistingFolder = v ?? _useExistingFolder),
                  child: Column(
                    children: [
                      RadioListTile<bool>(
                        title: const Text('새 폴더 자동 생성'),
                        value: false,
                      ),
                      RadioListTile<bool>(
                        title: const Text('기존 폴더 선택'),
                        value: true,
                      ),
                    ],
                  ),
                ),

                if (_useExistingFolder) ...[
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text('대상 폴더 매핑',
                        style: Theme.of(context).textTheme.titleSmall),
                  ),
                  const SizedBox(height: 8),
                  ..._memkFolders.where((f) {
                    return _selectedFolderNames
                        .contains((f['name'] as String?) ?? '');
                  }).map((memkFolder) {
                    final name = (memkFolder['name'] as String?) ?? '';
                    final memkId = (memkFolder['id'] as num?)?.toInt();
                    if (memkId == null) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold)),
                          ),
                          const Icon(Icons.arrow_forward, size: 16),
                          const SizedBox(width: 8),
                          Expanded(
                            child: DropdownButton<int>(
                              isExpanded: true,
                              value: _folderMapping[memkId],
                              hint: const Text('폴더 선택'),
                              items: _localFolders.map((f) {
                                return DropdownMenuItem(
                                  value: f.id,
                                  child: Text(f.name),
                                );
                              }).toList(),
                              onChanged: (v) {
                                setState(() {
                                  if (v != null) {
                                    _folderMapping[memkId] = v;
                                  }
                                });
                              },
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextButton.icon(
                      onPressed: _createNewLocalFolder,
                      icon: const Icon(Icons.add),
                      label: const Text('새 폴더 만들기'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        // Import 버튼
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed:
                    _selectedFolderNames.isEmpty ? null : _startImport,
                child: Text(
                  'Import (${_selectedFolderNames.length}개 폴더)',
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildImporting() {
    final progress = _controller.currentImportProgress;
    final cardProgress = progress.totalCards > 0
        ? progress.currentCards / progress.totalCards
        : 0.0;
    final imageProgress = progress.totalImages > 0
        ? progress.currentImages / progress.totalImages
        : 0.0;
    final totalProgress = progress.phase == 'images'
        ? (cardProgress + imageProgress) / 2
        : cardProgress * 0.5;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(
                value: totalProgress.clamp(0.0, 1.0)),
            const SizedBox(height: 24),
            Text(
              progress.message ?? '처리 중...',
              style: Theme.of(context).textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Text(
              '뒤로 가기를 눌러도 백그라운드에서 계속 진행됩니다.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDone() {
    final r = _controller.lastImportResult;
    if (r == null) {
      return _buildError();
    }
    final minutes = r.duration.inMinutes;
    final seconds = r.duration.inSeconds % 60;
    final timeStr = minutes > 0 ? '$minutes분 $seconds초' : '$seconds초';

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle,
                size: 64, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text('Import 완료',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 24),
            _resultRow('신규 카드', '${r.newCards}장'),
            _resultRow('스킵 (중복)', '${r.skippedCards}장'),
            _resultRow('신규 폴더', '${r.newFolders}개'),
            _resultRow('병합 폴더', '${r.mergedFolders}개'),
            _resultRow('이미지', '${r.images}장'),
            _resultRow('소요 시간', timeStr),
            const SizedBox(height: 32),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('확인'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyLarge),
          Text(value,
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              _errorMessage ?? '알 수 없는 에러',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('돌아가기'),
            ),
          ],
        ),
      ),
    );
  }
}
