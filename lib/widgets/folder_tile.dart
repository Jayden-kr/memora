import 'package:flutter/material.dart';

import '../models/folder.dart';

class FolderTile extends StatelessWidget {
  final Folder folder;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const FolderTile({
    super.key,
    required this.folder,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        folder.isBundle ? Icons.folder_special : Icons.folder,
        color: Theme.of(context).colorScheme.primary,
      ),
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
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}
