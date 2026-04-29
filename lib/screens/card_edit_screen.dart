import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../database/database_helper.dart';
import '../l10n/app_localizations.dart';
import '../models/card.dart';
import '../models/folder.dart';
import '../utils/constants.dart';
import '../widgets/image_viewer.dart';

class CardEditScreen extends StatefulWidget {
  final int folderId;
  final CardModel? existingCard;

  const CardEditScreen({
    super.key,
    required this.folderId,
    this.existingCard,
  });

  @override
  State<CardEditScreen> createState() => _CardEditScreenState();
}

class _CardEditScreenState extends State<CardEditScreen> {
  final _questionController = TextEditingController();
  final _answerController = TextEditingController();
  final _picker = ImagePicker();

  bool _finished = false;
  bool _saving = false;
  int _currentFolderId = 0;
  List<Folder> _folders = [];

  // 이미지 경로 리스트 (최대 5장)
  List<String?> _questionImages = List.filled(5, null);
  List<double?> _questionImageRatios = List.filled(5, null);
  List<String?> _answerImages = List.filled(5, null);
  List<double?> _answerImageRatios = List.filled(5, null);

  bool get _isEditing => widget.existingCard != null;

  @override
  void initState() {
    super.initState();
    _currentFolderId = widget.folderId;
    if (_isEditing) {
      final c = widget.existingCard!;
      _questionController.text = c.question;
      _answerController.text = c.answer;
      _finished = c.finished;
      _currentFolderId = c.folderId;
      _questionImages = [
        c.questionImagePath,
        c.questionImagePath2,
        c.questionImagePath3,
        c.questionImagePath4,
        c.questionImagePath5,
      ];
      _questionImageRatios = [
        c.questionImageRatio,
        c.questionImageRatio2,
        c.questionImageRatio3,
        c.questionImageRatio4,
        c.questionImageRatio5,
      ];
      _answerImages = [
        c.answerImagePath,
        c.answerImagePath2,
        c.answerImagePath3,
        c.answerImagePath4,
        c.answerImagePath5,
      ];
      _answerImageRatios = [
        c.answerImageRatio,
        c.answerImageRatio2,
        c.answerImageRatio3,
        c.answerImageRatio4,
        c.answerImageRatio5,
      ];
    }
    _loadFolders();
  }

  @override
  void dispose() {
    _questionController.dispose();
    _answerController.dispose();
    super.dispose();
  }

  Future<void> _loadFolders() async {
    final folders = await DatabaseHelper.instance.getNonBundleFolders();
    if (!mounted) return;
    setState(() {
      _folders = folders;
      // 현재 folderId가 로드된 폴더 목록에 없으면 첫 번째 폴더로 보정
      if (_folders.isNotEmpty && !_folders.any((f) => f.id == _currentFolderId)) {
        _currentFolderId = _folders.first.id ?? _currentFolderId;
      }
    });
  }

  Future<String> _copyImageToAppDir(String sourcePath) async {
    final dir = await getApplicationDocumentsDirectory();
    final imageDir = Directory(p.join(dir.path, AppConstants.imageDir));
    try {
      if (!await imageDir.exists()) {
        await imageDir.create(recursive: true);
      }
    } catch (e) {
      if (!await imageDir.exists()) rethrow;
    }
    final uuid = const Uuid().v4();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final fileName = 'R_$uuid-app-$ts.jpg';
    final destPath = p.join(imageDir.path, fileName);
    await File(sourcePath).copy(destPath);
    return destPath;
  }

  Future<void> _pickImage(List<String?> images, List<double?> ratios) async {
    final t = AppLocalizations.of(context);
    final emptyIndex = images.indexWhere((img) => img == null);
    if (emptyIndex == -1) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.cardEditMaxImages)),
      );
      return;
    }

    // 카메라/갤러리 선택
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: Text(t.cardEditCamera),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: Text(t.cardEditGallery),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    final picked = await _picker.pickImage(source: source);
    if (picked == null || !mounted) return;

    String? savedPath;
    try {
      savedPath = await _copyImageToAppDir(picked.path);

      final bytes = await File(savedPath).readAsBytes();
      final decoded = await decodeImageFromList(bytes);
      final ratio = (decoded.width > 0 && decoded.height > 0)
          ? decoded.width / decoded.height
          : 1.0;

      if (!mounted) return;
      setState(() {
        images[emptyIndex] = savedPath;
        ratios[emptyIndex] = ratio;
      });
    } catch (e) {
      // 복사된 파일이 있으면 정리
      if (savedPath != null) {
        try { await File(savedPath).delete(); } catch (_) {}
      }
      if (!mounted) return;
      final t = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.cardEditImageLoadFail(e.toString()))),
      );
    }
  }

  /// 원본 카드에 포함된 경로인지 확인
  bool _isOriginalPath(String path) {
    if (!_isEditing) return false;
    final c = widget.existingCard!;
    return [
      c.questionImagePath, c.questionImagePath2, c.questionImagePath3,
      c.questionImagePath4, c.questionImagePath5,
      c.answerImagePath, c.answerImagePath2, c.answerImagePath3,
      c.answerImagePath4, c.answerImagePath5,
    ].contains(path);
  }

  void _removeImage(
      List<String?> images, List<double?> ratios, int index) {
    final path = images[index];
    setState(() {
      images[index] = null;
      ratios[index] = null;
    });
    // 새로 추가된 이미지(원본 카드에 없는 경로)는 즉시 삭제
    if (path != null && path.isNotEmpty && !_isOriginalPath(path)) {
      File(path).delete().ignore();
    }
  }

  /// 변경사항 폐기 시 새로 추가된 이미지 파일을 디스크에서 삭제 (orphan 방지)
  void _cleanupNewImages() {
    for (final path in [..._questionImages, ..._answerImages]) {
      if (path != null && path.isNotEmpty && !_isOriginalPath(path)) {
        File(path).delete().ignore();
      }
    }
  }

  /// 저장 시 원본 카드에 있었지만 현재 제거된 이미지 파일을 디스크에서 삭제
  Future<void> _cleanupRemovedImages() async {
    if (!_isEditing) return;
    final original = widget.existingCard!;
    final originalPaths = <String?>[
      original.questionImagePath, original.questionImagePath2,
      original.questionImagePath3, original.questionImagePath4,
      original.questionImagePath5,
      original.answerImagePath, original.answerImagePath2,
      original.answerImagePath3, original.answerImagePath4,
      original.answerImagePath5,
    ];
    final currentPaths = <String?>[
      ..._questionImages, ..._answerImages,
    ];
    for (final path in originalPaths) {
      if (path != null && path.isNotEmpty && !currentPaths.contains(path)) {
        try { await File(path).delete(); } catch (_) {}
      }
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final question = _questionController.text.trim();
    final answer = _answerController.text.trim();
    final hasImages = _questionImages.any((img) => img != null) ||
        _answerImages.any((img) => img != null);
    if (question.isEmpty && answer.isEmpty && !hasImages) {
      if (!mounted) return;
      final t = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.cardEditEmptyError)),
      );
      return;
    }

    setState(() => _saving = true);

    try {
      final now = DateTime.now();
      final offset = now.timeZoneOffset;
      final tzSign = offset.isNegative ? '-' : '+';
      final tzHours = offset.inHours.abs().toString().padLeft(2, '0');
      final tzMins =
          (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
      final modifiedStr =
          '${_monthName(now.month)} ${now.day.toString().padLeft(2, '0')}, ${now.year} '
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')} '
          'GMT$tzSign$tzHours:$tzMins';

      if (_isEditing) {
        final updated = widget.existingCard!.copyWith(
          folderId: _currentFolderId,
          question: question,
          answer: answer,
          questionImagePath: _questionImages[0],
          questionImageRatio: _questionImageRatios[0],
          questionImagePath2: _questionImages[1],
          questionImageRatio2: _questionImageRatios[1],
          questionImagePath3: _questionImages[2],
          questionImageRatio3: _questionImageRatios[2],
          questionImagePath4: _questionImages[3],
          questionImageRatio4: _questionImageRatios[3],
          questionImagePath5: _questionImages[4],
          questionImageRatio5: _questionImageRatios[4],
          answerImagePath: _answerImages[0],
          answerImageRatio: _answerImageRatios[0],
          answerImagePath2: _answerImages[1],
          answerImageRatio2: _answerImageRatios[1],
          answerImagePath3: _answerImages[2],
          answerImageRatio3: _answerImageRatios[2],
          answerImagePath4: _answerImages[3],
          answerImageRatio4: _answerImageRatios[3],
          answerImagePath5: _answerImages[4],
          answerImageRatio5: _answerImageRatios[4],
          finished: _finished,
          modified: modifiedStr,
        );
        final originalFolderId = widget.existingCard!.folderId;
        if (_currentFolderId != originalFolderId) {
          // 폴더 변경은 moveCard로 원자적 처리 (트랜잭션 내 card_count 갱신 포함)
          await DatabaseHelper.instance.moveCard(widget.existingCard!.id!, _currentFolderId);
          // 이동 후 나머지 필드 업데이트 (folderId는 이미 moveCard에서 변경됨)
          await DatabaseHelper.instance.updateCard(updated);
        } else {
          await DatabaseHelper.instance.updateCard(updated);
        }
        await _cleanupRemovedImages();
      } else {
        final uuid =
            '${const Uuid().v4()}-app-${DateTime.now().millisecondsSinceEpoch}';
        final maxSeq =
            await DatabaseHelper.instance.getMaxSequence(_currentFolderId);
        final card = CardModel(
          uuid: uuid,
          folderId: _currentFolderId,
          question: question,
          answer: answer,
          questionImagePath: _questionImages[0],
          questionImageRatio: _questionImageRatios[0],
          questionImagePath2: _questionImages[1],
          questionImageRatio2: _questionImageRatios[1],
          questionImagePath3: _questionImages[2],
          questionImageRatio3: _questionImageRatios[2],
          questionImagePath4: _questionImages[3],
          questionImageRatio4: _questionImageRatios[3],
          questionImagePath5: _questionImages[4],
          questionImageRatio5: _questionImageRatios[4],
          answerImagePath: _answerImages[0],
          answerImageRatio: _answerImageRatios[0],
          answerImagePath2: _answerImages[1],
          answerImageRatio2: _answerImageRatios[1],
          answerImagePath3: _answerImages[2],
          answerImageRatio3: _answerImageRatios[2],
          answerImagePath4: _answerImages[3],
          answerImageRatio4: _answerImageRatios[3],
          answerImagePath5: _answerImages[4],
          answerImageRatio5: _answerImageRatios[4],
          finished: _finished,
          sequence: maxSeq + 1,
          modified: modifiedStr,
        );
        await DatabaseHelper.instance.insertCard(card);
        await DatabaseHelper.instance
            .updateFolderCardCount(_currentFolderId);
      }

      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      final t = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.cardEditSaveFail(e.toString()))),
      );
    }
  }

  String _monthName(int month) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return months[month - 1];
  }

  bool _listChanged(List<String?> current, List<String?> original) {
    if (current.length != original.length) return true;
    for (int i = 0; i < current.length; i++) {
      if (current[i] != original[i]) return true;
    }
    return false;
  }

  bool get _hasChanges {
    final q = _questionController.text.trim();
    final a = _answerController.text.trim();
    if (_isEditing) {
      final c = widget.existingCard!;
      return q != c.question || a != c.answer ||
          _currentFolderId != c.folderId ||
          _finished != c.finished ||
          _listChanged(_questionImages, [
            c.questionImagePath, c.questionImagePath2,
            c.questionImagePath3, c.questionImagePath4,
            c.questionImagePath5,
          ]) ||
          _listChanged(_answerImages, [
            c.answerImagePath, c.answerImagePath2,
            c.answerImagePath3, c.answerImagePath4,
            c.answerImagePath5,
          ]);
    }
    return q.isNotEmpty || a.isNotEmpty ||
        _questionImages.any((img) => img != null) ||
        _answerImages.any((img) => img != null);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return PopScope(
      canPop: !_hasChanges,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final discard = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(t.cardEditDiscardTitle),
            content: Text(t.cardEditDiscardBody),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(t.commonCancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(t.cardEditDiscardLeave),
              ),
            ],
          ),
        );
        if (discard == true && context.mounted) {
          _cleanupNewImages();
          Navigator.pop(context);
        }
      },
      child: Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? t.cardEditTitleEdit : t.cardEditTitleNew),
        actions: [
          TextButton(
            onPressed: (_saving || _folders.isEmpty) ? null : _save,
            child: Text(t.commonSave),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 폴더 선택 드롭다운
            if (_folders.isNotEmpty)
              DropdownButtonFormField<int>(
                initialValue: _folders.any((f) => f.id == _currentFolderId)
                    ? _currentFolderId
                    : null,
                decoration: InputDecoration(
                  labelText: t.cardEditFolderLabel,
                  border: const OutlineInputBorder(),
                ),
                items: _folders.map((f) {
                  return DropdownMenuItem(
                    value: f.id,
                    child: Text(f.name),
                  );
                }).toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _currentFolderId = v);
                },
              ),
            const SizedBox(height: 16),

            // 앞면
            Text(t.cardEditFront,
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            TextField(
              controller: _questionController,
              minLines: 3,
              maxLines: null,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: t.cardEditFrontHint,
              ),
            ),
            const SizedBox(height: 8),
            _imageRow(_questionImages, _questionImageRatios),
            const SizedBox(height: 24),

            // 뒷면
            Text(t.cardEditBack,
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            TextField(
              controller: _answerController,
              minLines: 5,
              maxLines: null,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: t.cardEditBackHint,
              ),
            ),
            const SizedBox(height: 8),
            _imageRow(_answerImages, _answerImageRatios),
            const SizedBox(height: 24),
          ],
        ),
      ),
    ),
    );
  }

  Widget _imageRow(List<String?> images, List<double?> ratios) {
    final activeImages =
        images.asMap().entries.where((e) => e.value != null).toList();
    final canAdd = images.any((img) => img == null);

    return SizedBox(
      height: activeImages.isEmpty && !canAdd ? 0 : 80,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          ...activeImages.map((entry) {
            final index = entry.key;
            final path = entry.value!;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Stack(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ImageViewerScreen(imagePath: path),
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(
                        File(path),
                        height: 80,
                        width: 80,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          height: 80,
                          width: 80,
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          child: const Icon(Icons.broken_image),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: GestureDetector(
                      onTap: () => _removeImage(images, ratios, index),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.error,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.close,
                            size: 18,
                            color: Theme.of(context).colorScheme.onError),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
          if (canAdd)
            GestureDetector(
              onTap: () => _pickImage(images, ratios),
              child: Container(
                height: 80,
                width: 80,
                decoration: BoxDecoration(
                  border: Border.all(
                      color: Theme.of(context).colorScheme.outline),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.add_photo_alternate, size: 32),
              ),
            ),
        ],
      ),
    );
  }
}
