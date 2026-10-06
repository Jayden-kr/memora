import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../models/folder.dart';
import '../utils/folder_icons.dart';
import 'color_picker_dialog.dart';
import 'folder_icon_view.dart';

/// 폴더 아이콘 선택 결과. `(icon: null, iconColor: null)`은 "기본값으로 되돌리기"다 —
/// 취소(다이얼로그가 `null`을 돌려줌)와는 다른 값이니 호출부가 둘을 섞지 말 것.
/// `icon`은 null(기본 폴더 아이콘) / 't:' + 직접 넣은 글자([Folder.iconTextPrefix]) 중 하나다.
typedef FolderIconChoice = ({String? icon, int? iconColor});

/// 폴더 아이콘·색 선택 다이얼로그. "저장"하면 고른 값을, "기본으로"를 누르면
/// `(icon: null, iconColor: null)`을, "취소"하거나 바깥을 탭하면 `null`을 반환한다.
/// 아이콘은 입력칸에 이모지·글자 1~2개를 직접 넣는다(입력이 있으면 't:'가 붙어 반환되고,
/// 비어 있으면 null = 기본 폴더 아이콘). 색은 둘 다 같이 쓴다.
///
/// 예전의 "기본 아이콘 24개 표"는 없앴다(사용자 요청 2026-10-06). 표의 키('star' 등)가
/// 저장돼 있던 폴더는 이제 기본 아이콘으로 그려지고, 이 다이얼로그는 그 폴더를 입력칸 비어 있는
/// 채로 열며 입력 없이 "저장"하면 `icon: null`을 돌려준다(= 키 정리; 그려지는 모양은 같다).
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

/// 아이콘 입력칸의 값 정리 규칙. 한 곳에 두고 두 길이 같이 쓴다 — 키보드 입력(입력
/// 포매터)과, 포매터를 안 거치는 변화(포커스를 잃거나 "완료"로 조합만 끝나는 경우:
/// 컨트롤러가 값을 직접 바꾼다 → State의 리스너).
///  - 공백은 전부 뺀다: 저장은 앞뒤 공백을 벗기므로("A "의 공백이 2글자 한도를 차지해
///    다음 글자를 막거나 " EN"이 ' E'로 잘리면 안 된다) 입력칸에는 공백이 남지 않게 한다.
///    입력칸 글자 = 저장될 글자라 maxLength 카운터도 맞는다.
///  - 처음 [Folder.iconTextMaxGraphemes]개 그래핌만 남긴다.
///  - 조합 중(にほん 변환 전 등)에는 건드리지 않는다 — 조합이 끝난 뒤에 자른다
///    (`MaxLengthEnforcement.truncateAfterCompositionEnds`와 같은 약속).
class _IconTextFormatter extends TextInputFormatter {
  const _IconTextFormatter();

  /// 조합 중인가. 빈 범위(-1,-1)나 접힌 범위는 조합이 아니다.
  static bool isComposing(TextEditingValue value) =>
      value.composing.isValid && !value.composing.isCollapsed;

  static bool _isSpace(int codeUnit) =>
      String.fromCharCode(codeUnit).trim().isEmpty;

  /// 정리한 값. 바꿀 게 없으면 받은 값 그대로(같은 객체)를 돌려준다 — 리스너가 그걸로
  /// "고쳤는가"를 판단한다.
  static TextEditingValue limit(TextEditingValue value) {
    if (isComposing(value)) return value;
    final text = value.text;

    // 공백을 빼면서 옛 오프셋 → 새 오프셋 표를 만든다(선택 위치를 따라가게).
    final kept = StringBuffer();
    final offsetMap = List<int>.filled(text.length + 1, 0);
    var keptLength = 0;
    for (var i = 0; i < text.length; i++) {
      offsetMap[i] = keptLength;
      final unit = text.codeUnitAt(i);
      if (_isSpace(unit)) continue;
      kept.writeCharCode(unit);
      keptLength++;
    }
    offsetMap[text.length] = keptLength;

    var result = kept.toString();
    final head = result.characters.take(Folder.iconTextMaxGraphemes).string;
    if (head.length != result.length) result = head;
    if (result == text) return value;

    // 엔진이 범위 밖 오프셋을 보내도(표 인덱스 RangeError 방지) 먼저 0..text.length로 누른다.
    int moved(int offset) => offset < 0
        ? offset
        : offsetMap[offset.clamp(0, text.length)].clamp(0, result.length);
    final selection = value.selection;
    return TextEditingValue(
      text: result,
      selection: TextSelection(
        baseOffset: moved(selection.baseOffset),
        extentOffset: moved(selection.extentOffset),
        affinity: selection.affinity,
        isDirectional: selection.isDirectional,
      ),
    );
  }

  static String _withoutSpaces(String text) {
    final buffer = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      if (!_isSpace(unit)) buffer.writeCharCode(unit);
    }
    return buffer.toString();
  }

  /// 키보드 입력. 조합 중이 아닐 때 공백을 뺀 새 값이 한도를 넘으면:
  ///  - 거부하는 경우는 딱 하나: 옛 값(공백 뺀)이 이미 한도(2글자)에 차 있고 옛 선택이
  ///    접혀 있을 때(= 가득 찬 칸에 끼워 넣기만 하는 입력). 이번 입력을 거부하고 옛 값(과
  ///    커서)을 그대로 둔다 — 기본 길이 제한기와 같은 느낌: "AB" 앞/중간/뒤에 "C"를 쳐도
  ///    "AB"가 유지된다.
  ///  - 그 밖에는 [limit]으로 앞 2글자로 자른다(기본 길이 제한기가 여러 글자 편집을 자르는
  ///    것과 같다): 빈 칸에 "ABC" 붙여넣기 → "AB", "A"에 "BC" 붙여넣기 → "AB",
  ///    "AB" 전체 선택 후 "XYZ" 붙여넣기 → "XY".
  /// ⚠️ 조합 중 값은 거부하지 않는다 — 새 값이 조합 중이면(にほん 변환 전 3글자 등)
  /// [limit]이 그대로 두고, 옛 값이 조합 중이면 옛 값(조합 범위 포함)을 키보드로 되돌려
  /// 보내지 않도록 거부하지 않고 [limit]으로 넘긴다.
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    if (!isComposing(newValue) &&
        !isComposing(oldValue) &&
        oldValue.selection.isCollapsed &&
        _withoutSpaces(newValue.text).characters.length >
            Folder.iconTextMaxGraphemes &&
        _withoutSpaces(oldValue.text).characters.length ==
            Folder.iconTextMaxGraphemes) {
      return oldValue;
    }
    return limit(newValue);
  }
}

class _FolderIconDialog extends StatefulWidget {
  const _FolderIconDialog({required this.folder});

  final Folder folder;

  @override
  State<_FolderIconDialog> createState() => _FolderIconDialogState();
}

/// ⚠️ 크래시 회귀 규율: 입력칸 컨트롤러는 반드시 이 State가 소유하고 [dispose]에서만
/// 정리한다. `showDialog(...).whenComplete(() => controller.dispose())` 패턴은 쓰지 않는다 —
/// 퇴장 애니메이션이 끝나기 전에 Future가 먼저 complete돼 화면에 남은 TextField가 이미
/// dispose된 컨트롤러를 참조한다(color_picker_dialog.dart의 같은 주석 참고).
class _FolderIconDialogState extends State<_FolderIconDialog> {
  // 저장돼 있던 값에서 출발한다. 정상 글자 아이콘('t:…')이면 글자를 입력칸에 채운다. 그 밖의
  // 저장값(예전 표의 키 'star' 등, 다른 버전이 만든 모르는 키, 규칙을 어긴 't:…')은 입력칸을
  // 비운 채 열고 미리보기는 기본 폴더 아이콘이다 — 그렇게 그려지는 값이 곧 화면에 보이는 값이라서다.
  // 입력 없이 "저장"하면 `icon: null`이 돌아온다(키 정리, 그려지는 모양은 같다).
  late int? _color = widget.folder.iconColor;

  // 직접 입력칸. 비어 있으면(공백만은 없는 것으로 본다) 기본 폴더 아이콘(null)이다.
  late final TextEditingController _textController;

  // 미리보기에 마지막으로 보여준 "쓸 수 있는" 값. 입력이 쓸 수 없는 동안(3글자 이상으로
  // 조합 중·안 보이는 글자 등) 미리보기가 기본 폴더로 깜빡 바뀌지 않고 이 값을 유지한다.
  // 오류는 입력칸의 errorText와 저장 버튼으로만 알린다.
  late String? _lastValidResult;

  // 리스너가 값을 고치는 동안 자기 자신을 다시 부르지 않게 하는 깃발.
  bool _fixing = false;

  @override
  void initState() {
    super.initState();
    final text = Folder.iconTextOf(widget.folder.icon);
    // onChanged가 아니라 리스너: 한글·일본어 조합(IME)이 끝나는 변화와 글자 삭제까지 같은
    // 경로로 받아 미리보기·저장 버튼을 갱신한다.
    _textController = TextEditingController(text: text ?? '')
      ..addListener(_onTextChanged);
    _lastValidResult = _result;
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    if (_fixing) return;
    // 포매터는 키보드 입력만 거친다. 포커스를 잃거나 "완료"로 조합이 확정 없이 끝나면
    // 컨트롤러가 조합 표시만 지우고(포매터 안 거침) 길이가 넘는 글자가 그대로 남으니
    // 여기서 같은 규칙으로 자른다.
    final value = _textController.value;
    final limited = _IconTextFormatter.limit(value);
    if (!identical(limited, value)) {
      _fixing = true;
      try {
        _textController.value = limited;
      } finally {
        _fixing = false;
      }
    }
    if (!_typedInvalid) _lastValidResult = _result;
    setState(() {});
  }

  /// 공백이 아닌 글자를 입력했는가(공백만 있으면 입력 안 한 것 — 기본 아이콘이다).
  bool get _hasTyped => _textController.text.trim().isNotEmpty;

  /// 입력을 저장 형태(앞뒤 공백 제거)로 다듬은 글자. 입력이 없거나 쓸 수 없으면 null.
  String? get _typed =>
      _hasTyped ? Folder.normalizeIconText(_textController.text) : null;

  /// 입력은 했는데 쓸 수 없다(3글자 이상·안 보이는 글자 등) → 저장 불가.
  bool get _typedInvalid => _hasTyped && _typed == null;

  /// 저장·미리보기에 쓸 아이콘 값. 입력이 있으면 't:' + 글자(쓸 수 없으면 null), 비어
  /// 있으면 null(기본 폴더 아이콘).
  String? get _result => _hasTyped && _typed != null
      ? '${Folder.iconTextPrefix}$_typed'
      : null;

  /// 미리보기에 그릴 값: 쓸 수 없는 입력 중이면 마지막으로 쓸 수 있던 값을 그대로 둔다.
  String? get _previewIcon => _typedInvalid ? _lastValidResult : _result;

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
    // 128dp를 뺀 값. AlertDialog는 content를 IntrinsicWidth로 감싸 크기를 재는데
    // GridView/LayoutBuilder는 intrinsic 치수 계산을 지원하지 않아 예외가 난다
    // (color_picker_dialog.dart와 같은 이유) — 고정 폭 SizedBox 안에서 Row/Expanded만 쓴다.
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
            // 직접 입력: 미리보기(저장될 모양 그대로) + 입력칸. 이 Row가 intrinsic 치수를
            // 안 물어도 되는 건 바깥 SizedBox가 고정 폭을 주기 때문이다. 새 GridView/
            // LayoutBuilder를 여기 넣지 말 것(위 폭 규칙).
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: FolderIconView(
                    key: const ValueKey('folderIconPreview'),
                    icon: _previewIcon,
                    iconColor: _color,
                    isBundle: widget.folder.isBundle,
                    size: 32,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    key: const ValueKey('folderIconTextField'),
                    controller: _textController,
                    // 글자 수는 그래핌(🇮🇱·👍🏽·א 하나가 1) 기준. 안드로이드 기본 `enforced`는
                    // 조합 중에도 잘라 にほん→日本 같은 변환을 깨뜨리니 조합이 끝난 뒤에 자른다.
                    maxLength: Folder.iconTextMaxGraphemes,
                    maxLengthEnforcement:
                        MaxLengthEnforcement.truncateAfterCompositionEnds,
                    // 줄바꿈·탭 등 제어문자는 아예 못 넣게 한다(저장 규칙과 같은 집합). 이어서
                    // 공백 제거 + 2글자 자르기(_IconTextFormatter). maxLength는 카운터 표시와
                    // 조합 중 처리를 위해 둔다 — 입력칸에 공백이 없으니 카운터가 저장될 글자 수와 맞는다.
                    // enableSuggestions는 끄지 않는다 — 끄면 이모지 패널·CJK 조합이 막힌다.
                    inputFormatters: [
                      FilteringTextInputFormatter.deny(
                        RegExp(r'[\u0000-\u001F\u007F-\u009F\u2028\u2029]'),
                      ),
                      const _IconTextFormatter(),
                    ],
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: t.folderIconTextLabel,
                      hintText: t.folderIconTextHint,
                      // 조합 중(にほん처럼 확정 전)에는 오류를 띄우지 않는다 — 저장 버튼만
                      // 막고, 조합이 끝나 규칙에 맞게 잘리면 사라진다.
                      errorText: _typedInvalid &&
                              !_IconTextFormatter.isComposing(
                                  _textController.value)
                          ? t.folderIconTextInvalid
                          : null,
                      errorMaxLines: 2,
                      isDense: true,
                    ),
                  ),
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
          // 쓸 수 없는 입력(3글자 이상·안 보이는 글자·조합 중 초과)이면 저장을 막는다.
          onPressed: _typedInvalid
              ? null
              : () => Navigator.pop<FolderIconChoice>(
                    context,
                    (icon: _result, iconColor: _color),
                  ),
          child: Text(t.commonSave),
        ),
      ],
    );
  }
}
