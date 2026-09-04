import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// SV사각형/Hue슬라이더의 고정 너비. AlertDialog의 content는 IntrinsicWidth로
/// 감싸이므로(intrinsic 치수를 지원 못 하는 LayoutBuilder를 못 쓴다), 폭을
/// 동적으로 재는 대신 고정값을 쓴다. 일반적인 폰/태블릿 다이얼로그 폭에 맞춘
/// 값이라 좁은 화면에서도 여유가 있다.
const double _pickerWidth = 260;

/// `#RRGGBB` 또는 `#AARRGGBB` 형식의 헥스 문자열을 [Color]로 파싱한다.
/// `#` 유무·6자리(RGB)/8자리(ARGB) 모두 허용. 형식이 맞지 않으면 예외를 던지지
/// 않고 조용히 `null`을 반환한다 — 호출부는 입력이 유효할 때만 반영하고, 그 외엔
/// 아무 것도 하지 않으면 된다(사용자가 타이핑 도중인 상태 포함).
Color? tryParseHexColor(String input) {
  var s = input.trim();
  if (s.startsWith('#')) s = s.substring(1);
  if (s.length != 6 && s.length != 8) return null;
  if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(s)) return null;
  final parsed = int.tryParse(s, radix: 16);
  if (parsed == null) return null;
  // 6자리는 알파를 생략한 것으로 보고 완전 불투명(0xFF)으로 채운다.
  return s.length == 6 ? Color(0xFF000000 | parsed) : Color(parsed);
}

/// 색(알파 포함)을 체커보드 배경 위에 그려서 반투명 여부를 눈으로 확인할 수
/// 있게 하는 미리보기 스와치. 다이얼로그 내부 미리보기와 설정 화면의 "커스텀
/// 색상 사용 중" 표시 스와치가 함께 쓴다.
class ColorSwatchPreview extends StatelessWidget {
  const ColorSwatchPreview({
    super.key,
    required this.color,
    this.size = 40,
  });

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: ClipOval(
        child: Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(painter: _CheckerPainter()),
            ColoredBox(color: color),
          ],
        ),
      ),
    );
  }
}

class _CheckerPainter extends CustomPainter {
  const _CheckerPainter();

  @override
  void paint(Canvas canvas, Size size) {
    const cell = 6.0;
    final light = Paint()..color = const Color(0xFFE0E0E0);
    final dark = Paint()..color = const Color(0xFFB0B0B0);
    final cols = (size.width / cell).ceil();
    final rows = (size.height / cell).ceil();
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < cols; x++) {
        final isLight = (x + y).isEven;
        canvas.drawRect(
          Rect.fromLTWH(x * cell, y * cell, cell, cell),
          isLight ? light : dark,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CheckerPainter oldDelegate) => false;
}

/// 채도(S)-명도(V) 사각형. 가로축=채도, 세로축=명도(위로 갈수록 밝음).
class _SvSquarePainter extends CustomPainter {
  const _SvSquarePainter({
    required this.hue,
    required this.saturation,
    required this.value,
  });

  final double hue;
  final double saturation;
  final double value;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final hueColor = HSVColor.fromAHSV(1.0, hue, 1.0, 1.0).toColor();

    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(colors: [Colors.white, hueColor])
            .createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black],
        ).createShader(rect),
    );

    final dot = Offset(saturation * size.width, (1 - value) * size.height);
    canvas.drawCircle(
      dot,
      8,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.drawCircle(
      dot,
      8,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _SvSquarePainter oldDelegate) =>
      oldDelegate.hue != hue ||
      oldDelegate.saturation != saturation ||
      oldDelegate.value != value;
}

/// 0~360 무지개 그라데이션 Hue 슬라이더 바.
class _HueBarPainter extends CustomPainter {
  const _HueBarPainter({required this.hue});

  final double hue;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(6));
    final colors = List<Color>.generate(
      7,
      (i) => HSVColor.fromAHSV(1.0, i * 60.0, 1.0, 1.0).toColor(),
    );
    canvas.drawRRect(
      rrect,
      Paint()..shader = LinearGradient(colors: colors).createShader(rect),
    );

    final x = (hue / 360.0).clamp(0.0, 1.0) * size.width;
    final thumb = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(x, size.height / 2),
        width: 4,
        height: size.height + 4,
      ),
      const Radius.circular(2),
    );
    canvas.drawRRect(thumb, Paint()..color = Colors.white);
    canvas.drawRRect(
      RRect.fromRectAndRadius(thumb.outerRect.deflate(1), const Radius.circular(2)),
      Paint()..color = Colors.black,
    );
  }

  @override
  bool shouldRepaint(covariant _HueBarPainter oldDelegate) =>
      oldDelegate.hue != hue;
}

/// 잠금화면 배경 커스텀 색상 다이얼로그를 띄운다. 사용자가 "적용"을 누르면
/// 선택한 색(알파 포함)의 ARGB int를, "취소"하거나 바깥을 탭하면 `null`을
/// 반환한다.
Future<int?> showColorPickerDialog({
  required BuildContext context,
  required int initialColor,
}) {
  return showDialog<int>(
    context: context,
    builder: (_) => _ColorPickerDialog(initialColor: initialColor),
  );
}

class _ColorPickerDialog extends StatefulWidget {
  const _ColorPickerDialog({required this.initialColor});

  final int initialColor;

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

/// ⚠️ 크래시 회귀 규율: 이 컨트롤러는 반드시 이 State가 소유하고 [dispose]에서만
/// 정리한다. `showDialog(...).whenComplete(() => controller.dispose())` 패턴은
/// 절대 쓰지 않는다 — 그 패턴이 push_notification_settings.dart의
/// `_PushRuleDialog` 문서 주석에 기록된 실제 크래시('_dependents.isEmpty': is
/// not true)의 원인이었다. Navigator.pop()이 반환하는 popped Future는 다이얼로그의
/// 퇴장(reverse) 애니메이션이 끝나기 전에 먼저 complete되므로, `.whenComplete()`로
/// dispose를 걸면 아직 화면에 남아 리빌드 중인 TextField가 이미 dispose된
/// controller를 참조하는 경합이 생긴다. State.dispose()는 Element가 실제로
/// unmount될 때(퇴장 애니메이션 완료 후)만 호출되므로 이 경합이 구조적으로
/// 성립하지 않는다.
class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late HSVColor _hsv;
  late final TextEditingController _hexController;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(Color(widget.initialColor));
    _hexController = TextEditingController(text: _hexFromHsv(_hsv));
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  String _hexFromHsv(HSVColor hsv) {
    final rgb = hsv.toColor().toARGB32() & 0x00FFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  void _updateFromSv(Offset local, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final s = (local.dx / size.width).clamp(0.0, 1.0);
    final v = (1.0 - local.dy / size.height).clamp(0.0, 1.0);
    setState(() {
      _hsv = _hsv.withSaturation(s).withValue(v);
      _hexController.text = _hexFromHsv(_hsv);
    });
  }

  void _updateFromHue(double dx, double width) {
    if (width <= 0) return;
    final hue = ((dx / width).clamp(0.0, 1.0) * 360.0).clamp(0.0, 360.0);
    setState(() {
      _hsv = _hsv.withHue(hue);
      _hexController.text = _hexFromHsv(_hsv);
    });
  }

  void _onHexChanged(String text) {
    final parsed = tryParseHexColor(text);
    if (parsed == null) return; // 무효 입력은 조용히 무시 — 에러 표시 없음.
    setState(() => _hsv = HSVColor.fromColor(parsed));
  }

  void _onOpacityChanged(double percent) {
    setState(() => _hsv = _hsv.withAlpha((percent / 100.0).clamp(0.0, 1.0)));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final previewColor = _hsv.toColor();
    final opacityPercent = (_hsv.alpha * 100).round();

    // 고정 크기를 쓴다(LayoutBuilder 대신) — AlertDialog는 내용을 IntrinsicWidth로
    // 감싸 크기를 재는데, LayoutBuilder는 intrinsic 치수 계산을 지원하지 않아서
    // "LayoutBuilder does not support returning intrinsic dimensions" 예외가
    // 난다. CustomPaint는 고정 size를 그대로 자기 intrinsic 크기로 보고하므로
    // 이 경로에서 안전하다.
    const svSize = Size(_pickerWidth, 180);
    const hueSize = Size(_pickerWidth, 28);

    return AlertDialog(
      title: Text(t.lockBgCustomColor),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onPanDown: (d) => _updateFromSv(d.localPosition, svSize),
              onPanUpdate: (d) => _updateFromSv(d.localPosition, svSize),
              child: CustomPaint(
                size: svSize,
                painter: _SvSquarePainter(
                  hue: _hsv.hue,
                  saturation: _hsv.saturation,
                  value: _hsv.value,
                ),
              ),
            ),
            const SizedBox(height: 16),
            GestureDetector(
              onPanDown: (d) => _updateFromHue(d.localPosition.dx, hueSize.width),
              onPanUpdate: (d) => _updateFromHue(d.localPosition.dx, hueSize.width),
              child: CustomPaint(
                size: hueSize,
                painter: _HueBarPainter(hue: _hsv.hue),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                ColorSwatchPreview(color: previewColor, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _hexController,
                    decoration: InputDecoration(
                      labelText: t.lockBgHexLabel,
                      hintText: '#RRGGBB',
                      isDense: true,
                    ),
                    onChanged: _onHexChanged,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(t.lockBgOpacity, style: Theme.of(context).textTheme.bodySmall),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: opacityPercent.toDouble(),
                    min: 0,
                    max: 100,
                    onChanged: _onOpacityChanged,
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text('$opacityPercent%', textAlign: TextAlign.end),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.commonCancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, previewColor.toARGB32()),
          child: Text(t.lockBgApply),
        ),
      ],
    );
  }
}
