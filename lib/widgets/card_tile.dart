import 'dart:io';

import 'package:flutter/material.dart';

import '../models/card.dart';

class CardTile extends StatefulWidget {
  final CardModel card;
  final bool isFolded;
  final bool isHidden;
  final bool isRevealed;
  final bool isSelectionMode;
  final bool isSelected;
  final bool isHighlighted;
  final int? cardNumber;
  final String? searchQuery;
  final VoidCallback? onQuestionTap;
  final VoidCallback? onAnswerTap;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final void Function(String action)? onMenuAction;

  const CardTile({
    super.key,
    required this.card,
    this.isFolded = false,
    this.isHidden = false,
    this.isRevealed = false,
    this.isSelectionMode = false,
    this.isSelected = false,
    this.isHighlighted = false,
    this.cardNumber,
    this.searchQuery,
    this.onQuestionTap,
    this.onAnswerTap,
    this.onTap,
    this.onLongPress,
    this.onMenuAction,
  });

  @override
  State<CardTile> createState() => _CardTileState();
}

class _CardTileState extends State<CardTile> {
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final answerVisible = !widget.isHidden || widget.isRevealed;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: null,
      shape: widget.isHighlighted
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: colorScheme.primary, width: 2.5),
            )
          : null,
      child: InkWell(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Card number
              if (widget.cardNumber != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '#${widget.cardNumber}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
              // Question row
              Row(
                children: [
                  if (widget.isSelectionMode)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Icon(
                        widget.isSelected
                            ? Icons.check_circle
                            : Icons.circle_outlined,
                        color: widget.isSelected
                            ? colorScheme.primary
                            : colorScheme.outline,
                      ),
                    ),
                  Expanded(
                    child: GestureDetector(
                      onTap: widget.onQuestionTap,
                      behavior: HitTestBehavior.opaque,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildHighlightedText(
                            widget.card.question.isEmpty &&
                                    widget.card.questionImagePaths.isEmpty
                                ? '(내용 없음)'
                                : widget.card.question,
                            widget.searchQuery,
                            const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: widget.isFolded ? 1 : null,
                            overflow: widget.isFolded
                                ? TextOverflow.ellipsis
                                : null,
                          ),
                          if (!widget.isFolded &&
                              widget.card.questionImagePaths.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Column(
                                children:
                                    widget.card.questionImagePaths.map((path) {
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: Image.file(
                                        File(path),
                                        width: double.infinity,
                                        fit: BoxFit.fitWidth,
                                        cacheWidth: 600,
                                        gaplessPlayback: true,
                                        errorBuilder: (_, _, _) => Container(
                                          height: 80,
                                          width: double.infinity,
                                          color: colorScheme
                                              .surfaceContainerHighest,
                                          child: const Icon(Icons.broken_image,
                                              size: 28),
                                        ),
                                      ),
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (!widget.isSelectionMode && widget.onMenuAction != null)
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.more_vert, size: 20),
                      onSelected: widget.onMenuAction,
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('편집')),
                        PopupMenuItem(value: 'duplicate', child: Text('복제')),
                        PopupMenuItem(value: 'move', child: Text('다른 폴더로 이동')),
                        PopupMenuItem(
                          value: 'delete',
                          child:
                              Text('삭제', style: TextStyle(color: Colors.red)),
                        ),
                      ],
                    ),
                ],
              ),
              // Answer area (collapsible)
              if (!widget.isFolded)
                _buildAnswerArea(colorScheme, answerVisible),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHighlightedText(
    String text,
    String? query,
    TextStyle style, {
    int? maxLines,
    TextOverflow? overflow,
  }) {
    if (query == null || query.isEmpty) {
      return Text(text, style: style, maxLines: maxLines, overflow: overflow);
    }

    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final highlightColor = Theme.of(context).colorScheme.primary;
    final spans = <TextSpan>[];
    int start = 0;

    while (true) {
      final index = lowerText.indexOf(lowerQuery, start);
      if (index == -1) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (index > start) {
        spans.add(TextSpan(text: text.substring(start, index)));
      }
      spans.add(TextSpan(
        text: text.substring(index, index + query.length),
        style: TextStyle(backgroundColor: highlightColor),
      ));
      start = index + (query.length > 0 ? query.length : 1);
    }

    return Text.rich(
      TextSpan(style: style, children: spans),
      maxLines: maxLines,
      overflow: overflow ?? TextOverflow.clip,
    );
  }

  Widget _buildAnswerArea(ColorScheme colorScheme, bool answerVisible) {
    return GestureDetector(
      onTap: widget.onAnswerTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 16),
          if (answerVisible) ...[
            if (widget.card.answer.isNotEmpty)
              _buildHighlightedText(
                widget.card.answer,
                widget.searchQuery,
                const TextStyle(fontSize: 16),
              ),
            if (widget.card.answerImagePaths.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  children: widget.card.answerImagePaths.map((path) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(
                          File(path),
                          width: double.infinity,
                          fit: BoxFit.fitWidth,
                          cacheWidth: 600,
                          errorBuilder: (_, _, _) => Container(
                            height: 80,
                            width: double.infinity,
                            color: colorScheme.surfaceContainerHighest,
                            child: const Icon(Icons.broken_image, size: 28),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
          ] else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '탭하여 정답 보기',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
              ),
            ),
        ],
      ),
    );
  }
}
