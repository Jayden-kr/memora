import 'dart:io';

import 'package:flutter/material.dart';

import '../models/card.dart';
import '../widgets/image_viewer.dart';
import 'card_edit_screen.dart';

class CardViewScreen extends StatefulWidget {
  final CardModel card;

  const CardViewScreen({super.key, required this.card});

  @override
  State<CardViewScreen> createState() => _CardViewScreenState();
}

class _CardViewScreenState extends State<CardViewScreen> {
  bool _showAnswer = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: () async {
              final navigator = Navigator.of(context);
              await navigator.push(
                MaterialPageRoute(
                  builder: (_) => CardEditScreen(
                    folderId: widget.card.folderId,
                    existingCard: widget.card,
                  ),
                ),
              );
              if (mounted) navigator.pop();
            },
          ),
        ],
      ),
      body: GestureDetector(
        onTap: () => setState(() => _showAnswer = !_showAnswer),
        behavior: HitTestBehavior.opaque,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: _showAnswer ? _buildAnswer() : _buildQuestion(),
        ),
      ),
    );
  }

  Widget _buildQuestion() {
    return _buildSide(
      key: const ValueKey('question'),
      text: widget.card.question,
      images: widget.card.questionImagePaths,
      label: '앞면',
    );
  }

  Widget _buildAnswer() {
    return _buildSide(
      key: const ValueKey('answer'),
      text: widget.card.answer,
      images: widget.card.answerImagePaths,
      label: '뒷면',
    );
  }

  Widget _buildSide({
    required Key key,
    required String text,
    required List<String> images,
    required String label,
  }) {
    return SizedBox.expand(
      key: key,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            Text(
              text.isEmpty ? '(내용 없음)' : text,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            if (images.isNotEmpty) ...[
              const SizedBox(height: 24),
              ...images.map((path) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: GestureDetector(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ImageViewerScreen(imagePath: path),
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.file(
                          File(path),
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => Container(
                            height: 200,
                            color: Colors.grey[300],
                            child: const Center(
                                child: Icon(Icons.broken_image, size: 48)),
                          ),
                        ),
                      ),
                    ),
                  )),
            ],
            const SizedBox(height: 48),
            Center(
              child: Text(
                '탭하여 ${_showAnswer ? '앞면' : '뒷면'} 보기',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
