import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/folder.dart';
import 'folder_icon_view.dart';

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
    // 사용자가 고른 아이콘/색이 있으면 그것을, 없으면 예전과 같은 기본(폴더/묶음 폴더 +
    // 테마 primary)을 그린다. 기본 색은 테마를 따라가고 고른 색은 고정이다.
    // 키 아이콘이든 글자('t:…') 아이콘이든 FolderIconView가 그린다.
    final icon = FolderIconView(
      icon: folder.icon,
      iconColor: folder.iconColor,
      isBundle: folder.isBundle,
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
          ? Text(AppLocalizations.of(context).folderTileBundle,
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
