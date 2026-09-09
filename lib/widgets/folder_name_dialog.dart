import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// 폴더 이름 입력 다이얼로그(생성/이름변경 공용) — [initialName]이 있으면 이름변경,
/// 없으면 생성 흐름이다. 홈 화면·묶음 폴더 화면의 생성/이름변경, 카드 목록의 "이동 중
/// 새 폴더 생성"(검증 콜백 포함), 로컬 파일 임포트의 새 폴더 생성이 모두 이 다이얼로그를
/// 쓴다.
///
/// StatefulWidget으로 만든 이유(중요): [TextEditingController]는 반드시
/// `State.dispose()`에서만 정리해야 한다 — Future 콜백(`.whenComplete()`나
/// `finally`)에 묶으면 Navigator.pop()이 반환하는 popped Future가 퇴장 애니메이션
/// 완료보다 먼저 끝나버려서, 아직 화면에 남아 리빌드 중인 TextField가 이미 dispose된
/// controller를 참조하는 경합이 생긴다(자세한 경위는
/// push_notification_settings.dart의 `_PushRuleDialog` 문서 참고).
class FolderNameDialog extends StatefulWidget {
  const FolderNameDialog({
    super.key,
    required this.title,
    required this.hint,
    required this.confirmLabel,
    this.initialName,
    this.validate,
  });

  final String title;
  final String hint;
  final String confirmLabel;
  final String? initialName;
  /// 확인 전에 이름을 검사한다. 오류 문구를 돌려주면 다이얼로그 안에 표시하고 닫지 않는다 —
  /// 모달 배리어 뒤 SnackBar로 알리면 사용자 눈엔 "아무 반응 없음"이었다(감사 Y1-04).
  final Future<String?> Function(String name)? validate;

  @override
  State<FolderNameDialog> createState() => _FolderNameDialogState();
}

class _FolderNameDialogState extends State<FolderNameDialog> {
  late final TextEditingController _controller;
  String? _errorText;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName ?? '');
  }

  Future<void> _submit() async {
    final name = _controller.text.trim();
    final validate = widget.validate;
    if (validate == null || name.isEmpty) {
      Navigator.pop(context, name);
      return;
    }
    setState(() => _checking = true);
    String? error;
    try {
      error = await validate(name);
    } catch (_) {
      // 검사 자체가 실패하면 버튼을 영구히 잠그는 대신 이름을 그대로 넘긴다 — 호출자가
      // insert 전에 exists 검사를 한 번 더 하므로(2차 방어) 거기서 처리된다.
      if (!mounted) return;
      Navigator.pop(context, name);
      return;
    }
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _errorText = error;
        _checking = false;
      });
      return;
    }
    Navigator.pop(context, name);
  }

  @override
  void dispose() {
    // 여기서만 dispose한다 — Element가 실제로 unmount될 때(=다이얼로그 퇴장 애니메이션이
    // 끝난 뒤)만 프레임워크가 이 메서드를 부르므로, 아직 마운트돼 리빌드 중인 TextField가
    // dispose된 controller를 참조할 여지가 구조적으로 없다.
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.hint, errorText: _errorText),
        onChanged: (_) {
          if (_errorText != null) setState(() => _errorText = null);
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.commonCancel),
        ),
        TextButton(
          onPressed: _checking ? null : _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
