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

  /// 글자 한 개가 칸(box)에서 차지하는 비율(글자 크기 = box × 이 값). 글자 한 개는
  /// 줄 높이 1.0(아래 style)이라 문단 높이가 정확히 이 비율이고, 칸을 넘치는 2글자·긴
  /// 이모지만 FittedBox가 줄인다. 눈대중 값 — 글자 모양마다 1px 안팎 차이가 나니 기기에서
  /// 보고 조정할 수 있다. 테스트(folder_icon_view_test)가 이 상수를 읽어 "주변 글자
  /// 스타일과 무관하게 이 비율로 그려지는가"를 보므로 값을 바꿔도 테스트는 그대로다.
  static const double glyphScale = 0.8;

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
      // ⚠️ 줄 높이·글자 간격을 주변 스타일에 맡기지 않는다. 폴더 행(ListTile leading은
      // labelSmall: 높이 1.45·간격 0.5)이나 다이얼로그(bodyMedium)에서 상속받으면 줄 상자가
      // 글자보다 28% 크거나 글자가 벌어져 FittedBox가 늘 줄이므로, 한 글자가 칸의 69%밖에
      // 못 채운다(기기에서 확인). 높이 1.0 + 위아래 균등 배분이면 줄 상자 = 글자 크기고,
      // 폰트 ascent+descent가 더 큰 이모지·히브리어는 위아래로 고르게 삐져나올 뿐 잘리지
      // 않는다(FittedBox는 자르지 않는다).
      textHeightBehavior: const TextHeightBehavior(
        applyHeightToFirstAscent: true,
        applyHeightToLastDescent: true,
        leadingDistribution: TextLeadingDistribution.even,
      ),
      style: TextStyle(
        fontSize: box * glyphScale,
        fontWeight: FontWeight.w700,
        height: 1.0,
        letterSpacing: 0,
        leadingDistribution: TextLeadingDistribution.even,
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
