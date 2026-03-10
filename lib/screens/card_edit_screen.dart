import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../database/database_helper.dart';
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
  int _currentFolderId = 0;

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
  }

  @override
  void dispose() {
    _questionController.dispose();
    _answerController.dispose();
    super.dispose();
  }

  Future<String> _copyImageToAppDir(String sourcePath) async {
    final dir = await getApplicationDocumentsDirectory();
    final imageDir = Directory(p.join(dir.path, AppConstants.imageDir));
    if (!await imageDir.exists()) {
      await imageDir.create(recursive: true);
    }
    final uuid = const Uuid().v4();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final fileName = 'R_$uuid-app-$ts.jpg';
    final destPath = p.join(imageDir.path, fileName);
    await File(sourcePath).copy(destPath);
    return destPath;
  }

  Future<void> _pickImage(List<String?> images, List<double?> ratios) async {
    // 빈 슬롯 찾기
    final emptyIndex = images.indexWhere((img) => img == null);
    if (emptyIndex == -1) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('이미지는 최대 5장까지 추가할 수 있습니다.')),
      );
      return;
    }

    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;

    final savedPath = await _copyImageToAppDir(picked.path);

    // 이미지 비율 계산
    final bytes = await File(savedPath).readAsBytes();
    final decoded = await decodeImageFromList(bytes);
    final ratio = decoded.width / decoded.height;

    setState(() {
      images[emptyIndex] = savedPath;
      ratios[emptyIndex] = ratio;
    });
  }

  void _removeImage(
      List<String?> images, List<double?> ratios, int index) {
    setState(() {
      images[index] = null;
      ratios[index] = null;
    });
  }

  Future<void> _save() async {
    final question = _questionController.text.trim();
    final answer = _answerController.text.trim();
    if (question.isEmpty && answer.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('앞면 또는 뒷면을 입력하세요.')),
      );
      return;
    }

    final now = DateTime.now();
    final modifiedStr =
        '${_monthName(now.month)} ${now.day.toString().padLeft(2, '0')}, ${now.year} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')} '
        'GMT+09:00';

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
      await DatabaseHelper.instance.updateCard(updated);

      // 폴더 이동한 경우 양쪽 card_count 갱신
      if (_currentFolderId != widget.folderId) {
        await DatabaseHelper.instance.moveCard(updated.id!, _currentFolderId);
        await DatabaseHelper.instance
            .updateFolderCardCount(widget.folderId);
        await DatabaseHelper.instance
            .updateFolderCardCount(_currentFolderId);
      }
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
  }

  String _monthName(int month) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return months[month - 1];
  }

  Future<void> _showFolderPicker() async {
    final folders = await DatabaseHelper.instance.getAllFolders();
    if (!mounted) return;
    final selected = await showDialog<Folder>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('폴더 이동'),
        children: folders.map((f) {
          return SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, f),
            child: Text(f.name),
          );
        }).toList(),
      ),
    );
    if (selected != null) {
      setState(() => _currentFolderId = selected.id!);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? '카드 편집' : '새 카드'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('저장'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 앞면
            Text('앞면 (Question)',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            TextField(
              controller: _questionController,
              minLines: 3,
              maxLines: null,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '질문을 입력하세요',
              ),
            ),
            const SizedBox(height: 8),
            _imageRow(_questionImages, _questionImageRatios),
            const SizedBox(height: 24),

            // 뒷면
            Text('뒷면 (Answer)',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            TextField(
              controller: _answerController,
              minLines: 5,
              maxLines: null,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '정답을 입력하세요',
              ),
            ),
            const SizedBox(height: 8),
            _imageRow(_answerImages, _answerImageRatios),
            const SizedBox(height: 24),

            // 암기 상태
            SwitchListTile(
              title: const Text('암기 완료'),
              value: _finished,
              onChanged: (v) => setState(() => _finished = v),
            ),

            // 폴더 이동
            ListTile(
              leading: const Icon(Icons.folder),
              title: const Text('폴더 이동'),
              onTap: _showFolderPicker,
            ),
          ],
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
                          color: Colors.grey[300],
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
                        decoration: const BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.close,
                            size: 18, color: Colors.white),
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
                  border: Border.all(color: Colors.grey),
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
