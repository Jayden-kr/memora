import 'package:flutter/material.dart';

import '../database/database_helper.dart';
import '../l10n/app_localizations.dart';
import '../models/folder.dart';

class BundleFolderScreen extends StatefulWidget {
  final Folder? existingBundle;

  const BundleFolderScreen({super.key, this.existingBundle});

  @override
  State<BundleFolderScreen> createState() => _BundleFolderScreenState();
}

class _BundleFolderScreenState extends State<BundleFolderScreen> {
  final _nameController = TextEditingController();
  List<Folder> _availableFolders = [];
  Set<int> _selectedFolderIds = {};
  bool _loading = true;
  bool _saving = false;

  bool get _isEditing => widget.existingBundle != null;

  @override
  void initState() {
    super.initState();
    if (_isEditing) {
      _nameController.text = widget.existingBundle!.name;
    }
    _loadFolders();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loadFolders() async {
    final allFolders = await DatabaseHelper.instance.getNonBundleFolders();

    Set<int> selectedIds = {};
    if (_isEditing) {
      // 편집 모드: 현재 묶음에 속한 폴더를 미리 선택
      final children = await DatabaseHelper.instance
          .getChildFolders(widget.existingBundle!.id!);
      selectedIds = children.map((f) => f.id!).toSet();
    }

    if (!mounted) return;
    setState(() {
      _selectedFolderIds = selectedIds;
      _availableFolders = allFolders;
      _loading = false;
    });
  }

  bool _isFolderAvailable(Folder folder) {
    // 이미 다른 묶음에 속한 폴더는 선택 불가 (현재 편집 중인 묶음 제외)
    if (folder.parentFolderId != null && folder.parentFolderId != 0) {
      if (_isEditing &&
          folder.parentFolderId == widget.existingBundle!.id) {
        return true;
      }
      return false;
    }
    return true;
  }

  Future<void> _save() async {
    if (_saving) return;
    final t = AppLocalizations.of(context);
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.bundleNameEmptyError)),
      );
      return;
    }

    // 이름 중복 사전 체크 (transaction 밖, UNIQUE constraint도 fallback으로 동작)
    if (!_isEditing || name != widget.existingBundle!.name) {
      final existing = await DatabaseHelper.instance.getFolderByName(name);
      if (existing != null &&
          (!_isEditing || existing.id != widget.existingBundle!.id)) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.homeFolderExists(name))),
        );
        return;
      }
    }

    setState(() => _saving = true);

    try {
      // 편집 모드: 기존 child id 집합 미리 fetch
      Set<int>? oldChildIds;
      if (_isEditing) {
        final oldChildren = await DatabaseHelper.instance
            .getChildFolders(widget.existingBundle!.id!);
        oldChildIds = oldChildren.map((f) => f.id!).toSet();
      }

      // ⚡ 단일 transaction으로 묶음 row + child parent 변경 모두 atomic 처리
      await DatabaseHelper.instance.saveBundleFolder(
        bundleId: _isEditing ? widget.existingBundle!.id : null,
        bundleName: name,
        selectedChildIds: _selectedFolderIds,
        oldChildIds: oldChildIds,
      );

      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.errorPrefix(e.toString()))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return PopScope(
      // 저장 중에는 시스템 back gesture 차단 — transaction 도중 빠져나가 잠재적 불일치 방지
      canPop: !_saving,
      child: Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? t.bundleEditTitle : t.bundleNewTitle),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(t.commonSave),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _nameController,
                    autofocus: !_isEditing,
                    decoration: InputDecoration(
                      labelText: t.bundleNameHint,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(t.bundlePickFoldersTitle,
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  if (_availableFolders.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(t.bundleNoAvailable),
                    )
                  else
                    ..._availableFolders.map((folder) {
                      final available = _isFolderAvailable(folder);
                      final selected = _selectedFolderIds.contains(folder.id);
                      return CheckboxListTile(
                        title: Text(folder.name),
                        subtitle: Text(available
                            ? t.cardCountSuffix(folder.cardCount)
                            : '${t.cardCountSuffix(folder.cardCount)} · ${t.bundleAlreadyIn}'),
                        value: selected,
                        enabled: available,
                        onChanged: available
                            ? (value) {
                                setState(() {
                                  if (value == true && folder.id != null) {
                                    _selectedFolderIds.add(folder.id!);
                                  } else if (folder.id != null) {
                                    _selectedFolderIds.remove(folder.id!);
                                  }
                                });
                              }
                            : null,
                        secondary: Icon(
                          Icons.folder,
                          color: available
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: 0.38),
                        ),
                      );
                    }),
                ],
              ),
            ),
      ),
    );
  }
}
