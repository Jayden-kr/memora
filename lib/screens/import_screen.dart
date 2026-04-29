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
        if (mounted) Navigator.pop(context);
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

    if (_controller.isRunning) {
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
      final existing = await DatabaseHelper.instance.getFolderByName(name);
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
      await _controller.startImport(
        filePath: _stableFilePath ?? widget.filePath,
        selectedFolderNames: _selectedFolderNames.toList(),
        folderMapping: mapping,
        conflictPolicy: conflictPolicy,
      );
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

  Future<void> _createNewLocalFolder() async {
    final t = AppLocalizations.of(context);
    final controller = TextEditingController();
    try {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.homeNewFolderTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: t.homeFolderNameHint),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(t.commonCreate),
          ),
        ],
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

  String _formatDuration(Duration d, AppLocalizations t) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return m > 0 ? t.durationMinSec(m, s) : t.durationSec(s);
  }

  String _resolveErrorMessage(AppLocalizations t) {
    if (_errorMessage != null) return _errorMessage!;
    if (_errorRaw == null) return t.importErrorUnknown;
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
            Icon(Icons.check_circle,
                size: 64, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(t.importDoneTitle,
                style: Theme.of(context).textTheme.headlineSmall),
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
