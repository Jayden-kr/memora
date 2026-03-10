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
    this.onQuestionTap,
    this.onAnswerTap,
    this.onTap,
    this.onLongPress,
    this.onMenuAction,
  });

  @override
  State<CardTile> createState() => _CardTileState();
}

class _CardTileState extends State<CardTile>
    with SingleTickerProviderStateMixin {
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final answerVisible = !widget.isHidden || widget.isRevealed;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        onTap: widget.isSelectionMode ? widget.onTap : null,
        onLongPress: widget.onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
                      child: Text(
                        widget.card.question.isEmpty
                            ? '(내용 없음)'
                            : widget.card.question,
                        style: Theme.of(context)
                            .textTheme
                            .bodyLarge
                            ?.copyWith(fontWeight: FontWeight.bold),
                        maxLines: widget.isFolded ? 1 : null,
                        overflow: widget.isFolded
                            ? TextOverflow.ellipsis
                            : null,
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
              AnimatedCrossFade(
                firstChild: const SizedBox.shrink(),
                secondChild: _buildAnswerArea(colorScheme, answerVisible),
                crossFadeState: widget.isFolded
                    ? CrossFadeState.showFirst
                    : CrossFadeState.showSecond,
                duration: const Duration(milliseconds: 200),
              ),
            ],
          ),
        ),
      ),
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
              Text(
                widget.card.answer,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            if (widget.card.answerImagePaths.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SizedBox(
                  height: 60,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: widget.card.answerImagePaths.map((path) {
                      return Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.file(
                            File(path),
                            height: 60,
                            width: 60,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Container(
                              height: 60,
                              width: 60,
                              color: colorScheme.surfaceContainerHighest,
                              child: const Icon(Icons.broken_image, size: 20),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
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
