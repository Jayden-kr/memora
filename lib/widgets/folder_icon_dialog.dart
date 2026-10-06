import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/folder.dart';
import '../utils/folder_icons.dart';
import 'color_picker_dialog.dart';

/// 폴더 아이콘 선택 결과. `(icon: null, iconColor: null)`은 "기본값으로 되돌리기"다 —
/// 취소(다이얼로그가 `null`을 돌려줌)와는 다른 값이니 호출부가 둘을 섞지 말 것.
typedef FolderIconChoice = ({String? icon, int? iconColor});

/// 폴더 아이콘·색 선택 다이얼로그. "저장"하면 고른 값을, "기본으로"를 누르면
/// `(icon: null, iconColor: null)`을, "취소"하거나 바깥을 탭하면 `null`을 반환한다.
///
/// 홈 화면(일반/묶음 폴더)과 묶음 안 폴더 목록이 같이 쓴다. DB에 쓰는 일은 하지
/// 않는다 — 호출부가 `DatabaseHelper.updateFolderIcon`으로 저장한다.
Future<FolderIconChoice?> showFolderIconDialog({
  required BuildContext context,
  required Folder folder,
}) {
  return showDialog<FolderIconChoice>(
    context: context,
    builder: (_) => _FolderIconDialog(folder: folder),
  );
}

/// 아이콘 키 → 사용자에게 읽어줄 이름(툴팁·접근성 라벨). 표에 없는 키(다른 버전이 만든
/// 값)는 `null`이라 라벨이 붙지 않는다.
///
/// ⚠️ [folderIcons]에 아이콘을 추가하면 여기와 두 arb(app_ko/app_en)의 `folderIconName*`
/// 키도 같이 추가할 것 — 이름이 없는 아이콘 버튼은 스크린리더가 "버튼"으로만 읽는다
/// (테스트: folder_icon_dialog_test의 "모든 키에 이름이 있다").
String? folderIconName(AppLocalizations t, String key) => switch (key) {
      'book' => t.folderIconNameBook,
      'language' => t.folderIconNameLanguage,
      'star' => t.folderIconNameStar,
      'heart' => t.folderIconNameHeart,
      'school' => t.folderIconNameSchool,
      'science' => t.folderIconNameScience,
      'music' => t.folderIconNameMusic,
      'work' => t.folderIconNameWork,
      'idea' => t.folderIconNameIdea,
      'flag' => t.folderIconNameFlag,
      'bookmark' => t.folderIconNameBookmark,
      'math' => t.folderIconNameMath,
      'code' => t.folderIconNameCode,
      'globe' => t.folderIconNameGlobe,
      'mind' => t.folderIconNameMind,
      'history' => t.folderIconNameHistory,
      'art' => t.folderIconNameArt,
      'sports' => t.folderIconNameSports,
      'travel' => t.folderIconNameTravel,
      'medical' => t.folderIconNameMedical,
      'pets' => t.folderIconNamePets,
      'food' => t.folderIconNameFood,
      'chat' => t.folderIconNameChat,
      'home' => t.folderIconNameHome,
      _ => null,
    };

class _FolderIconDialog extends StatefulWidget {
  const _FolderIconDialog({required this.folder});

  final Folder folder;

  @override
  State<_FolderIconDialog> createState() => _FolderIconDialogState();
}

class _FolderIconDialogState extends State<_FolderIconDialog> {
  // 저장돼 있던 값에서 출발한다. 이 앱 버전이 모르는 키(다른 버전이 만든 값)가 들어
  // 있어도 사용자가 다른 아이콘을 고르기 전까지는 그대로 돌려준다 — 색만 바꾸고
  // 저장했는데 아이콘 키가 조용히 지워지면 안 된다.
  late String? _icon = widget.folder.icon;
  late int? _color = widget.folder.iconColor;

  Future<void> _pickColor() async {
    final scheme = Theme.of(context).colorScheme;
    // 투명도는 의미가 없으니 슬라이더를 감춘다(결과는 항상 불투명).
    final picked = await showColorPickerDialog(
      context: context,
      initialColor: _color ?? scheme.primary.toARGB32(),
      showOpacity: false,
    );
    if (!mounted) return;
    if (picked == null) return;
    setState(() => _color = picked);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final shownColor = folderIconColor(_color, scheme);

    // 폭은 화면에 맞춘다: AlertDialog의 insetPadding 40×2 + contentPadding 24×2 =
    // 128dp를 뺀 값. 아이콘은 GridView/LayoutBuilder가 아니라 Wrap으로 깐다 —
    // AlertDialog는 content를 IntrinsicWidth로 감싸 크기를 재는데 둘 다 intrinsic
    // 치수 계산을 지원하지 않아 예외가 난다(color_picker_dialog.dart와 같은 이유).
    // 폭이 한 줄 아이콘 수를 정하고 넘치면 줄바꿈이라 좁은 화면·가로 모드에서도 잘리지 않는다.
    final width = (MediaQuery.sizeOf(context).width - 128).clamp(120.0, 288.0);

    return AlertDialog(
      // 제목+내용을 통째로 스크롤 영역에 넣는다(액션 줄만 고정). content 안에 따로
      // SingleChildScrollView를 두면 큰 글자 크기·낮은 화면에서 제목이 스크롤되지 않고
      // 고정 영역(제목+액션)이 화면을 다 먹어 오버플로가 난다. SizedBox가 고정 폭을 주므로
      // 이 경로의 IntrinsicWidth 측정도 안전하다.
      scrollable: true,
      title: Text(t.folderIconTitle),
      content: SizedBox(
        width: width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              children: [
                for (final entry in folderIcons.entries)
                  IconButton(
                    key: ValueKey('folderIconOption_${entry.key}'),
                    // 아이콘만 있는 버튼이라 이름을 안 붙이면 스크린리더가 "버튼"으로만
                    // 읽는다(길게 누르면 이름이 뜨기도 한다).
                    tooltip: folderIconName(t, entry.key),
                    isSelected: entry.key == _icon,
                    // 고른 아이콘만 고른 색(없으면 테마색)으로 미리 보여주고 테두리로
                    // 표시한다. 나머지는 기본 아이콘색이라 선택된 것이 한눈에 보인다.
                    icon: Icon(
                      entry.value,
                      color: entry.key == _icon ? shownColor : null,
                    ),
                    style: entry.key == _icon
                        ? IconButton.styleFrom(
                            side: BorderSide(color: scheme.primary, width: 2),
                          )
                        : null,
                    onPressed: () => setState(() => _icon = entry.key),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            InkWell(
              key: const ValueKey('folderIconColorRow'),
              borderRadius: BorderRadius.circular(8),
              onTap: _pickColor,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    ColorSwatchPreview(color: shownColor, size: 32),
                    const SizedBox(width: 12),
                    Expanded(child: Text(t.folderIconColor)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop<FolderIconChoice>(
            context,
            (icon: null, iconColor: null),
          ),
          child: Text(t.folderIconReset),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.commonCancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop<FolderIconChoice>(
            context,
            (icon: _icon, iconColor: _color),
          ),
          child: Text(t.commonSave),
        ),
      ],
    );
  }
}
