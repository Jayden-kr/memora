import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// 덮어쓰기/충돌 알림 다이얼로그에서 사용하는 옵션 한 개
class OverwriteOption {
  final IconData icon;
  final String title;
  final String subtitle;
  final String value; // Navigator.pop() 시 반환되는 값
  final bool accent; // primaryContainer 색으로 강조

  const OverwriteOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    this.accent = false,
  });
}

/// 단어카드 중복 다이얼로그와 동일한 스타일의 덮어쓰기 알림.
/// 옵션 중 하나를 누르면 해당 [OverwriteOption.value]를 반환,
/// 취소 또는 다이얼로그 외부 탭 시 'cancel' 또는 null을 반환한다.
Future<String?> showOverwriteDialog({
  required BuildContext context,
  required String title,
  required String message,
  required List<OverwriteOption> options,
  String? cancelLabel,
}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final cancelText = cancelLabel ?? AppLocalizations.of(ctx).commonCancel;
      return Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Text(message, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 20),
              for (int i = 0; i < options.length; i++) ...[
                _OverwriteOptionTile(
                  option: options[i],
                  onTap: () => Navigator.pop(ctx, options[i].value),
                ),
                if (i < options.length - 1) const SizedBox(height: 8),
              ],
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx, 'cancel'),
                  child: Text(cancelText),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _OverwriteOptionTile extends StatelessWidget {
  final OverwriteOption option;
  final VoidCallback onTap;

  const _OverwriteOptionTile({
    required this.option,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = option.accent ? cs.primaryContainer : cs.surfaceContainerHighest;
    final fg = option.accent ? cs.onPrimaryContainer : cs.onSurface;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(option.icon, color: fg.withValues(alpha: 0.85), size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      option.title,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: fg,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    if (option.subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        option.subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: fg.withValues(alpha: 0.7),
                            ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
