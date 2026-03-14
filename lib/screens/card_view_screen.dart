import 'dart:io';

import 'package:flutter/material.dart';

import '../database/database_helper.dart';
import '../models/card.dart';
import '../widgets/image_viewer.dart';
import 'card_edit_screen.dart';

/// 알림 탭 시 카드 내용을 바로 보여주는 화면
class CardViewScreen extends StatefulWidget {
  final CardModel card;
  final String? folderName;

  const CardViewScreen({
    super.key,
    required this.card,
    this.folderName,
  });

  @override
  State<CardViewScreen> createState() => _CardViewScreenState();
}

class _CardViewScreenState extends State<CardViewScreen> {
  late CardModel _card;
  String? _folderName;
  bool _answerRevealed = false;

  @override
  void initState() {
    super.initState();
    _card = widget.card;
    _folderName = widget.folderName;
  }

  Future<void> _editCard() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CardEditScreen(
          folderId: _card.folderId,
          existingCard: _card,
        ),
      ),
    );
    // 편집 후 카드 데이터 갱신
    final updated = await DatabaseHelper.instance.getCardById(_card.id!);
    if (!mounted || updated == null) return;

    // 폴더 변경 시 새 폴더명 조회
    if (updated.folderId != _card.folderId) {
      final folder =
          await DatabaseHelper.instance.getFolderById(updated.folderId);
      if (!mounted) return;
      setState(() {
        _card = updated;
        _folderName = folder?.name;
      });
      return;
    }
    setState(() => _card = updated);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(_folderName ?? '카드'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: '편집',
            onPressed: _editCard,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Question
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Question',
                      style: textTheme.labelMedium?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    SelectableText(
                      _card.question.isEmpty ? '(내용 없음)' : _card.question,
                      style: textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    // Question images
                    if (_card.questionImagePaths.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: _buildImages(_card.questionImagePaths, colorScheme),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Answer (탭해서 보기)
            GestureDetector(
              onTap: () => setState(() => _answerRevealed = !_answerRevealed),
              child: Card(
                color: _answerRevealed
                    ? null
                    : colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Answer',
                            style: textTheme.labelMedium?.copyWith(
                              color: colorScheme.primary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          if (!_answerRevealed)
                            Text(
                              '탭하여 정답 보기',
                              style: textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                        ],
                      ),
                      if (_answerRevealed) ...[
                        const SizedBox(height: 12),
                        SelectableText(
                          _card.answer.isEmpty ? '(내용 없음)' : _card.answer,
                          style: textTheme.bodyLarge,
                        ),
                        // Answer images
                        if (_card.answerImagePaths.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: _buildImages(
                                _card.answerImagePaths, colorScheme),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImages(List<String> paths, ColorScheme colorScheme) {
    return Column(
      children: paths.map((path) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: GestureDetector(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ImageViewerScreen(imagePath: path),
                ),
              );
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(
                File(path),
                width: double.infinity,
                fit: BoxFit.fitWidth,
                errorBuilder: (_, e, s) => Container(
                  height: 80,
                  width: double.infinity,
                  color: colorScheme.surfaceContainerHighest,
                  child: const Icon(Icons.broken_image, size: 28),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
