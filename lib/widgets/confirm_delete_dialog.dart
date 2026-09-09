import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// 삭제 확인 다이얼로그(카드/폴더/파일 공용). true를 반환하면 삭제 확정, 취소 또는
/// 다이얼로그 밖 탭이면 false.
Future<bool> confirmDelete(
  BuildContext context, {
  required String title,
  required String message,
  String? confirmLabel,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final t = AppLocalizations.of(ctx);
      return AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              confirmLabel ?? t.commonDelete,
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      );
    },
  );
  return ok == true;
}
