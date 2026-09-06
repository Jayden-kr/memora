import 'package:flutter/material.dart';

import '../database/database_helper.dart';
import '../l10n/app_localizations.dart';
import '../models/folder.dart';
import '../services/import_export_controller.dart';
import '../widgets/overwrite_dialog.dart';

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
  String? _stableFilePath;
  List<Map<String, dynamic>> _memkFolders = [];
  final Set<String> _selectedFolderNames = {};

  bool _useExistingFolder = false;
  List<Folder> _localFolders = [];
  final Map<int, int> _folderMapping = {};

  String? _errorMessage;
  String? _errorRaw; // i18n placeholder substitution용

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
    _controller.importService.clearCache();
    super.dispose();
  }

  void _onControllerUpdate() {
    if (!mounted) return;
    // 이 화면의 파일이 아닌 import(뒤에서 돌고 있는 다른 파일)의 진행/완료는 무시한다.
    // 예전엔 어떤 import든 실행 중이면 importing→done으로 넘어가, 파일 B 화면이 A의
    // 결과를 "N장 가져옴"으로 보고했다(B는 한 줄도 안 읽혔는데). 알림 탭으로 열린
    // progressOnly 화면은 파일이 없으니 어떤 import든 따라간다.
    final current = _controller.currentImportFilePath;
    final mine = widget.progressOnly ||
        current == widget.filePath ||
        (current == null && _controller.lastImportFilePath == widget.filePath);
    if (!mine) return;
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
    if (widget.progressOnly) {
      if (_controller.isRunning && _controller.currentOperation == 'import') {
        setState(() => _stage = _ImportStage.importing);
      } else if (_controller.lastImportResult != null) {
        setState(() => _stage = _ImportStage.done);
      } else {
        // initState 안에서 동기 pop하면 빌드 페이즈 중 Navigator 변경이다 — 형제 ExportScreen과
        // 같이 첫 프레임 뒤로 미룬다(Y1-03).
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context);
        });
      }
      return;
    }

    try {
      _stableFilePath = widget.filePath;
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
        _errorRaw = 'fileRead:${e.toString()}';
      });
    }
  }

  Future<void> _startImport() async {
    if (_selectedFolderNames.isEmpty) return;
    final t = AppLocalizations.of(context);

    // isBusy: 다중 import 배치의 파일 사이 틈에도 막는다 — 그 틈에 시작한 단일 import는
    // 배치에 흡수돼 완료 알림이 없고, 배치의 다음 파일은 락에서 무음 no-op했다(R20-01).
    if (_controller.isBusy) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.importBusy)),
        );
      }
      return;
    }

    Map<int, int?>? mapping;
    if (_useExistingFolder) {
      mapping = {};
      for (final f in _memkFolders) {
        final memkId = (f['id'] as num?)?.toInt();
        if (memkId != null && _selectedFolderNames.contains(f['name'])) {
          mapping[memkId] = _folderMapping[memkId];
        }
      }
    }

    final conflictNames = <String>[];
    for (final f in _memkFolders) {
      final name = (f['name'] as String?) ?? '';
      if (name.isEmpty || !_selectedFolderNames.contains(name)) continue;
      final memkId = (f['id'] as num?)?.toInt();
      if (memkId != null && mapping != null && mapping[memkId] != null) {
        continue;
      }
      // 충돌 후보는 일반 폴더만 — 묶음과 이름이 겹치는 경우엔 병합/새이름 선택지를 보이지
      // 않고, 서비스가 자동으로 새 이름(_1…)의 일반 폴더로 가져온다.
      final existing =
          await DatabaseHelper.instance.getNonBundleFolderByName(name);
      if (existing != null) conflictNames.add(name);
    }

    if (!mounted) return;

    String conflictPolicy = 'merge';
    if (conflictNames.isNotEmpty) {
      final preview = conflictNames.length <= 3
          ? conflictNames.join(', ')
          : '${conflictNames.take(3).join(', ')} ${t.exportConflictPreviewSuffix(conflictNames.length - 3)}';
      final action = await showOverwriteDialog(
        context: context,
        title: t.importConflictTitle,
        message: t.exportConflictMessage(preview),
        options: [
          OverwriteOption(
            icon: Icons.layers_outlined,
            title: t.importMergeTitle,
            subtitle: t.importMergeSubtitle,
            value: 'merge',
            accent: true,
          ),
          OverwriteOption(
            icon: Icons.create_new_folder_outlined,
            title: t.importRenameTitle,
            subtitle: t.importRenameSubtitle,
            value: 'rename',
          ),
        ],
      );
      if (action == null || action == 'cancel') return;
      conflictPolicy = action;
    }

    if (!mounted) return;
    setState(() => _stage = _ImportStage.importing);

    try {
      final started = await _controller.startImport(
        filePath: _stableFilePath ?? widget.filePath,
        selectedFolderNames: _selectedFolderNames.toList(),
        folderMapping: mapping,
        conflictPolicy: conflictPolicy,
      );
      // 다른 작업이 진행 중이면 컨트롤러가 조용히 무시한다 — 화면이 "가져오는 중"에
      // 멈춘 것처럼 보이지 않게 선택 화면으로 되돌리고 이유를 말해준다.
      if (!started && mounted) {
        setState(() => _stage = _ImportStage.folderSelect);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).opBusyIgnored)),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _stage = _ImportStage.error;
          _errorRaw = 'import:${e.toString()}';
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

  /// ⚠️ 예전엔 여기 스코프에 클로저 변수로 `TextEditingController`를 만들고
  /// `try { showDialog(...) } finally { controller.dispose(); }`로 정리했었다 —
  /// push_notification_settings.dart의 `_PushRuleDialog` 문서에 적힌 것과 동일한
  /// '_dependents.isEmpty' 크래시 위험 패턴. 지금은 controller를
  /// [_CreateFolderDialog]의 State가 소유해 dispose()가 Element unmount 시점에만
  /// 불리도록 고쳤다.
  Future<void> _createNewLocalFolder() async {
    final t = AppLocalizations.of(context);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _CreateFolderDialog(),
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

    final maxSeq = await DatabaseHelper.instance.getMaxFolderSequence();
    final folder = Folder(name: name, sequence: maxSeq + 1);
    await DatabaseHelper.instance.insertFolder(folder);
    final localFolders =
        await DatabaseHelper.instance.getNonBundleFolders();
    if (!mounted) return;
    setState(() => _localFolders = localFolders);
  }

  String _formatDuration(Duration d, AppLocalizations t) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return m > 0 ? t.durationMinSec(m, s) : t.durationSec(s);
  }

  String _resolveErrorMessage(AppLocalizations t) {
    if (_errorMessage != null) return _errorMessage!;
    if (_errorRaw == null) return t.importErrorUnknown;
    // Memora 번들이 아닌 파일(folders.json/cards.json 없음·깨짐) — 원인을 그대로 알린다(D7-12).
    if (_errorRaw!.contains('ImportFormatException')) {
      return t.importErrorNotArchive;
    }
    final parts = _errorRaw!.split(':');
    final type = parts.first;
    final rest = parts.skip(1).join(':');
    switch (type) {
      case 'fileRead':
        return t.importFileReadFail(rest);
      case 'import':
        return t.importGenericFail(rest);
      default:
        return _errorRaw!;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.importTitle),
        leading: _stage == _ImportStage.importing
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  Navigator.pop(context);
                },
              )
            : null,
      ),
      body: switch (_stage) {
        _ImportStage.loading => _buildLoading(t),
        _ImportStage.folderSelect => _buildFolderSelect(t),
        _ImportStage.importing => _buildImporting(t),
        _ImportStage.done => _buildDone(t),
        _ImportStage.error => _buildError(t),
      },
    );
  }

  Widget _buildLoading(AppLocalizations t) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(t.importAnalyzing),
        ],
      ),
    );
  }

  Widget _buildFolderSelect(AppLocalizations t) {
    final allSelected = _selectedFolderNames.length == _memkFolders.length;
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Text(t.importFolderCount(_memkFolders.length),
                          style: Theme.of(context).textTheme.titleMedium),
                      const Spacer(),
                      TextButton(
                        onPressed: _toggleSelectAll,
                        child: Text(allSelected ? t.homeDeselectAll : t.homeSelectAll),
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
                    subtitle: Text(t.cardCountSuffix(cardCount)),
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

                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(t.importTargetLocation,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                RadioGroup<bool>(
                  groupValue: _useExistingFolder,
                  onChanged: (v) =>
                      setState(() => _useExistingFolder = v ?? _useExistingFolder),
                  child: Column(
                    children: [
                      RadioListTile<bool>(
                        title: Text(t.importNewFolder),
                        value: false,
                      ),
                      RadioListTile<bool>(
                        title: Text(t.importExistingFolder),
                        value: true,
                      ),
                    ],
                  ),
                ),

                if (_useExistingFolder) ...[
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(t.importMappingTitle,
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
                              hint: Text(t.importPickFolderHint),
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
                      label: Text(t.importNewLocalFolder),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed:
                    _selectedFolderNames.isEmpty ? null : _startImport,
                child: Text(t.importButton(_selectedFolderNames.length)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildImporting(AppLocalizations t) {
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
              progress.message ?? t.importProcessing,
              style: Theme.of(context).textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Text(
              t.importBackgroundNote,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            // 멈추면 여기까지 들어온 내용은 남는다 — 되돌리려면 부분 롤백이 필요한데
            // 병합 가져오기에선 "이번에 들어온 것만" 골라낼 수 없다. 결과 화면이 어디까지
            // 들어왔는지 알려준다.
            if (_controller.isCancelRequested)
              Text(
                t.opCancelling,
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              )
            else
              OutlinedButton.icon(
                onPressed: () => _controller.requestCancel(),
                icon: const Icon(Icons.stop_circle_outlined),
                label: Text(t.opCancelButton),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDone(AppLocalizations t) {
    final r = _controller.lastImportResult;
    if (r == null) {
      return _buildError(t);
    }
    final timeStr = _formatDuration(r.duration, t);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(r.cancelled ? Icons.stop_circle_outlined : Icons.check_circle,
                size: 64,
                color: r.cancelled
                    ? Theme.of(context).colorScheme.onSurfaceVariant
                    : Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(r.cancelled ? t.importCancelledTitle : t.importDoneTitle,
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center),
            if (r.cancelled) ...[
              const SizedBox(height: 8),
              Text(
                t.importCancelledNote,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 24),
            _resultRow(t.importDoneNewCards, t.cardCountSuffix(r.newCards)),
            _resultRow(t.importDoneSkipped, t.cardCountSuffix(r.skippedCards)),
            _resultRow(t.importDoneNewFolders, t.folderCountSuffix(r.newFolders)),
            _resultRow(t.importDoneMerged, t.folderCountSuffix(r.mergedFolders)),
            _resultRow(t.importDoneImages, t.imageCountSuffix(r.images)),
            _resultRow(t.importDoneTime, timeStr),
            const SizedBox(height: 32),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t.commonOk),
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

  Widget _buildError(AppLocalizations t) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 64, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 16),
            Text(
              _resolveErrorMessage(t),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t.importErrorBack),
            ),
          ],
        ),
      ),
    );
  }
}

/// 로컬 폴더 생성 다이얼로그. [_ImportScreenState._createNewLocalFolder]가 사용한다.
///
/// StatefulWidget으로 만든 이유(중요): [TextEditingController]는 반드시
/// `State.dispose()`에서만 정리해야 한다 — Future 콜백(`.whenComplete()`나
/// `finally`)에 묶으면 Navigator.pop()이 반환하는 popped Future가 퇴장 애니메이션
/// 완료보다 먼저 끝나버려서, 아직 화면에 남아 리빌드 중인 TextField가 이미 dispose된
/// controller를 참조하는 경합이 생긴다(자세한 경위는
/// push_notification_settings.dart의 `_PushRuleDialog` 문서 참고).
class _CreateFolderDialog extends StatefulWidget {
  const _CreateFolderDialog();

  @override
  State<_CreateFolderDialog> createState() => _CreateFolderDialogState();
}

class _CreateFolderDialogState extends State<_CreateFolderDialog> {
  final _controller = TextEditingController();

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
      title: Text(t.homeNewFolderTitle),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: t.homeFolderNameHint),
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.commonCancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: Text(t.commonCreate),
        ),
      ],
    );
  }
}
