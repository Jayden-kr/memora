import 'package:flutter/material.dart';

import '../database/database_helper.dart';
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
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('묶음 이름을 입력하세요.')),
      );
      return;
    }

    setState(() => _saving = true);

    try {
      if (_isEditing) {
        // 이름 변경 시 중복 체크
        if (name != widget.existingBundle!.name) {
          final existing = await DatabaseHelper.instance.getFolderByName(name);
          if (existing != null) {
            if (!mounted) return;
            setState(() => _saving = false);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('이미 "$name" 폴더가 있습니다.')),
            );
            return;
          }
        }

        // 기존 묶음 수정
        await DatabaseHelper.instance.updateFolder(
          widget.existingBundle!.copyWith(
            name: name,
            folderCount: _selectedFolderIds.length,
          ),
        );

        // 기존 하위 폴더 해제
        final oldChildren = await DatabaseHelper.instance
            .getChildFolders(widget.existingBundle!.id!);
        for (final child in oldChildren) {
          if (!_selectedFolderIds.contains(child.id)) {
            await DatabaseHelper.instance
                .updateFolder(child.copyWith(parentFolderId: null));
          }
        }

        // 새 하위 폴더 설정
        for (final folderId in _selectedFolderIds) {
          final folder = await DatabaseHelper.instance.getFolderById(folderId);
          if (folder != null) {
            await DatabaseHelper.instance.updateFolder(
              folder.copyWith(parentFolderId: widget.existingBundle!.id),
            );
          }
        }
      } else {
        // 새 묶음 생성
        final existing = await DatabaseHelper.instance.getFolderByName(name);
        if (existing != null) {
          if (!mounted) return;
          setState(() => _saving = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('이미 "$name" 폴더가 있습니다.')),
          );
          return;
        }

        final maxSeq = await DatabaseHelper.instance.getMaxFolderSequence();
        final bundleFolder = Folder(
          name: name,
          isBundle: true,
          folderCount: _selectedFolderIds.length,
          sequence: maxSeq + 1,
        );
        final bundleId =
            await DatabaseHelper.instance.insertFolder(bundleFolder);

        // 하위 폴더 설정
        for (final folderId in _selectedFolderIds) {
          final folder = await DatabaseHelper.instance.getFolderById(folderId);
          if (folder != null) {
            await DatabaseHelper.instance.updateFolder(
              folder.copyWith(parentFolderId: bundleId),
            );
          }
        }
      }

      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('에러: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? '묶음 폴더 편집' : '묶음 폴더 만들기'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('저장'),
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
                    decoration: const InputDecoration(
                      labelText: '묶음 이름',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text('포함할 폴더 선택',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  if (_availableFolders.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('선택할 수 있는 폴더가 없습니다.'),
                    )
                  else
                    ..._availableFolders.map((folder) {
                      final available = _isFolderAvailable(folder);
                      final selected = _selectedFolderIds.contains(folder.id);
                      return CheckboxListTile(
                        title: Text(folder.name),
                        subtitle: Text(available
                            ? '${folder.cardCount}장'
                            : '${folder.cardCount}장 · 다른 묶음에 포함됨'),
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
    );
  }
}
