import 'package:flutter/material.dart';

import '../models/folder.dart';

class FolderTile extends StatelessWidget {
  final Folder folder;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final int? reorderIndex;
  final bool isSelecting;
  final bool isSelected;

  const FolderTile({
    super.key,
    required this.folder,
    required this.onTap,
    this.onLongPress,
    this.reorderIndex,
    this.isSelecting = false,
    this.isSelected = false,
  });

  @override
  Widget build(BuildContext context) {
    final icon = Icon(
      folder.isBundle ? Icons.folder_special : Icons.folder,
      color: Theme.of(context).colorScheme.primary,
    );

    return ListTile(
      leading: isSelecting
          ? Checkbox(
              value: isSelected,
              onChanged: (_) => onTap(),
            )
          : reorderIndex != null
              ? ReorderableDragStartListener(
                  index: reorderIndex!,
                  child: icon,
                )
              : icon,
      title: Text(folder.name),
      subtitle: folder.isBundle
          ? Text('묶음 폴더',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ))
          : null,
      trailing: Text(
        folder.isBundle ? '${folder.folderCount}' : '${folder.cardCount}',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
      selected: isSelected,
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}
