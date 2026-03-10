import 'package:flutter/material.dart';

import '../models/card.dart';

class CardTile extends StatelessWidget {
  final CardModel card;
  final VoidCallback onTap;
  final VoidCallback onDismissed;

  const CardTile({
    super.key,
    required this.card,
    required this.onTap,
    required this.onDismissed,
  });

  @override
  Widget build(BuildContext context) {
    final hasImage =
        card.answerImagePaths.isNotEmpty || card.questionImagePaths.isNotEmpty;

    return Dismissible(
      key: ValueKey(card.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: Colors.red,
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) async {
        return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('카드 삭제'),
            content: const Text('이 카드를 삭제하시겠습니까?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('취소'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('삭제', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        );
      },
      onDismissed: (_) => onDismissed(),
      child: ListTile(
        leading: Icon(
          card.finished ? Icons.check_circle : Icons.circle_outlined,
          color: card.finished
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.outline,
        ),
        title: Text(
          card.question.isEmpty ? '(내용 없음)' : card.question,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: hasImage
            ? Icon(Icons.image,
                size: 18,
                color: Theme.of(context).colorScheme.onSurfaceVariant)
            : null,
        onTap: onTap,
      ),
    );
  }
}
