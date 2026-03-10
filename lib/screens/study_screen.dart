import 'dart:io';

import 'package:flutter/material.dart';

import '../database/database_helper.dart';
import '../models/card.dart';
import '../widgets/card_flip_widget.dart';
import '../widgets/image_viewer.dart';

class StudyScreen extends StatefulWidget {
  final int folderId;
  final String folderName;
  final int? finishedFilter; // null=전체, 0=암기 중, 1=암기 완료
  final bool randomOrder;
  final bool reversed; // true=정답→질문

  const StudyScreen({
    required this.folderId,
    required this.folderName,
    this.finishedFilter,
    this.randomOrder = false,
    this.reversed = false,
    super.key,
  });

  @override
  State<StudyScreen> createState() => _StudyScreenState();
}

class _StudyScreenState extends State<StudyScreen> {
  List<CardModel> _cards = [];
  bool _loading = true;
  int _currentIndex = 0;
  final PageController _pageController = PageController();
  final Map<int, GlobalKey<CardFlipWidgetState>> _flipKeys = {};

  @override
  void initState() {
    super.initState();
    _loadCards();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _loadCards() async {
    final cards = await DatabaseHelper.instance.getCardsByFolderId(
      widget.folderId,
      finished: widget.finishedFilter,
    );
    if (widget.randomOrder) {
      cards.shuffle();
    }
    setState(() {
      _cards = cards;
      _loading = false;
    });
  }

  GlobalKey<CardFlipWidgetState> _getFlipKey(int index) {
    return _flipKeys.putIfAbsent(index, () => GlobalKey<CardFlipWidgetState>());
  }

  void _toggleFinished() async {
    final card = _cards[_currentIndex];
    final updated = card.copyWith(finished: !card.finished);
    await DatabaseHelper.instance.updateCard(updated);
    setState(() {
      _cards[_currentIndex] = updated;
    });
  }

  Widget _buildSide({
    required String text,
    required List<String> images,
    required String label,
    required String flipHint,
  }) {
    return SizedBox.expand(
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
                flipHint,
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

  Widget _buildFront(CardModel card) {
    final text = widget.reversed ? card.answer : card.question;
    final images =
        widget.reversed ? card.answerImagePaths : card.questionImagePaths;
    final label = widget.reversed ? '정답' : '앞면';
    return _buildSide(
      text: text,
      images: images,
      label: label,
      flipHint: '탭하여 뒷면 보기',
    );
  }

  Widget _buildBack(CardModel card) {
    final text = widget.reversed ? card.question : card.answer;
    final images =
        widget.reversed ? card.questionImagePaths : card.answerImagePaths;
    final label = widget.reversed ? '질문' : '뒷면';
    return _buildSide(
      text: text,
      images: images,
      label: label,
      flipHint: '탭하여 앞면 보기',
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_cards.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
          title: Text(widget.folderName),
        ),
        body: const Center(
          child: Text('학습할 카드가 없습니다'),
        ),
      );
    }

    final currentCard = _cards[_currentIndex];

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('${_currentIndex + 1} / ${_cards.length}'),
        actions: [
          IconButton(
            icon: Icon(
              currentCard.finished
                  ? Icons.check_circle
                  : Icons.check_circle_outline,
              color: currentCard.finished
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            tooltip: currentCard.finished ? '암기 완료 해제' : '암기 완료',
            onPressed: _toggleFinished,
          ),
        ],
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: _cards.length,
        onPageChanged: (index) {
          // 이전 페이지 앞면으로 리셋
          _flipKeys[_currentIndex]?.currentState?.resetToFront();
          setState(() {
            _currentIndex = index;
          });
        },
        itemBuilder: (context, index) {
          final card = _cards[index];
          return CardFlipWidget(
            key: _getFlipKey(index),
            front: _buildFront(card),
            back: _buildBack(card),
          );
        },
      ),
    );
  }
}
