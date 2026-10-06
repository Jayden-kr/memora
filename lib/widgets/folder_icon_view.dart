import 'package:flutter/material.dart';

import '../models/folder.dart';
import '../utils/folder_icons.dart';

/// 폴더 아이콘을 그리는 유일한 자리. 저장값([Folder.icon])이 키(또는 null)면 머티리얼
/// 아이콘을, 't:' + 글자([Folder.iconTextOf])면 그 이모지·글자를 아이콘 칸 크기로 그린다.
/// 폴더를 그리는 모든 자리(폴더 행·묶음 편집 목록 등)가 이 위젯을 거치니, 그리는 규칙
/// (색·비활성·크기)은 여기만 고치면 된다.
class FolderIconView extends StatelessWidget {
  const FolderIconView({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.isBundle,
    this.enabled = true,
    this.size,
  });

  /// 저장된 아이콘 값(null / 키 / 't:' + 글자).
  final String? icon;

  /// 저장된 아이콘 색 ARGB. null이면 테마 기본색.
  final int? iconColor;

  /// 기본 아이콘(키가 없거나 모를 때)을 폴더로 할지 묶음 폴더로 할지.
  final bool isBundle;

  /// false = 고를 수 없는 항목(묶음 편집에서 이미 다른 묶음에 있는 폴더): 색 대신
  /// onSurface 38% 회색으로 그린다.
  final bool enabled;

  /// null이면 주변 IconTheme 크기(보통 24).
  final double? size;

  // 글자는 칸(box)의 이 비율로 시작해 FittedBox가 넘치면 줄인다. 눈대중 시작값 — 글자
  // 모양마다 1px 안팎 차이가 나므로 기기에서 보고 조정할 수 있다. 테스트는 "칸 안에
  // 들어감"만 보고 이 값 자체는 고정하지 않는다.
  static const double _glyphScale = 0.8;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final disabled = scheme.onSurface.withValues(alpha: 0.38);
    final text = Folder.iconTextOf(icon);
    if (text == null) {
      return Icon(
        folderIconData(icon, isBundle: isBundle),
        color: enabled ? folderIconColor(iconColor, scheme) : disabled,
        size: size,
      );
    }

    final box = size ?? IconTheme.of(context).size ?? 24.0;
    Widget glyph = Text(
      text,
      key: const ValueKey('folderIconGlyph'),
      maxLines: 1,
      softWrap: false,
      textScaler: TextScaler.noScaling, // 아이콘처럼 글자 크기 설정과 무관(칸 고정)
      style: TextStyle(
        fontSize: box * _glyphScale,
        fontWeight: FontWeight.w700,
        // ⚠️ 비활성일 땐 불투명으로 그리고 아래 필터가 38%를 한 번만 입힌다(이중 감쇠 금지).
        color: enabled ? folderIconColor(iconColor, scheme) : scheme.onSurface,
      ),
    );
    if (!enabled) {
      // 컬러 이모지는 글자색을 무시한다 → 모양만 남긴 회색 실루엣으로 만든다(아이콘과
      // 같은 "못 고른다" 표시를 이모지에도 같은 세기로).
      glyph = ColorFiltered(
        colorFilter: ColorFilter.mode(disabled, BlendMode.srcIn),
        child: glyph,
      );
    }
    // 글자는 장식이다: Icon도 라벨 없이 읽히지 않고, 폴더 이름은 제목이 읽는다.
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: box,
        child: Center(
          child: FittedBox(fit: BoxFit.scaleDown, child: glyph),
        ),
      ),
    );
  }
}
