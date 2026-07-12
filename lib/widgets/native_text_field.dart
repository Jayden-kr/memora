import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class NativeTextField extends StatefulWidget {
  final String initialText;
  final String? hint;
  final ValueChanged<String>? onChanged;
  final double fontSize;
  final int minLines;

  /// 네이티브 EditText의 포커스 획득/상실 보고. Flutter는 플랫폼 뷰 포커스를
  /// 모르므로, 상위(편집 화면)가 이 콜백으로 키보드 위 자동 스크롤을 수행한다.
  final ValueChanged<bool>? onFocusChanged;

  const NativeTextField({
    super.key,
    this.initialText = '',
    this.hint,
    this.onChanged,
    this.fontSize = 16,
    this.minLines = 3,
    this.onFocusChanged,
  });

  @override
  State<NativeTextField> createState() => NativeTextFieldState();
}

class NativeTextFieldState extends State<NativeTextField> {
  MethodChannel? _channel;
  String _currentText = '';
  /// 네이티브가 보고한 포커스 상태 (포커스 시 강조 테두리 표시에 사용).
  bool _focused = false;
  /// Native EditText가 측정한 dp 높이로 교체됨.
  /// 초기값은 native가 응답하기 전 첫 frame 동안만 사용되는 추정치.
  double _height = 80;
  // native에 마지막으로 적용한 테마 — creationParams는 view 생성 시 1회만
  // 적용되므로, 이후 런타임 테마 변경분은 이 값과 비교해 채널로 push한다.
  bool? _lastSentIsDark;
  int? _lastSentAccentColor;

  String get text => _currentText;

  @override
  void initState() {
    super.initState();
    _currentText = widget.initialText;
    // 초기 텍스트의 줄 수로 height 추정 — native 응답 전 깜빡임 최소화.
    // 빈 카드: 1줄(=gulf 같은 짧은 카드도 fit), 긴 답안 카드: N줄.
    int estimatedLines = 1;
    if (widget.initialText.isNotEmpty) {
      final newlineCount = '\n'.allMatches(widget.initialText).length;
      int wrappedLines = 0;
      for (final segment in widget.initialText.split('\n')) {
        // charsPerLine=30 휴리스틱 (한/영 mix 기준 평균)
        wrappedLines +=
            segment.isEmpty ? 1 : (segment.length / 30).ceil();
      }
      estimatedLines = wrappedLines > 0 ? wrappedLines : (newlineCount + 1);
    }
    _height =
        (widget.fontSize * 1.26 * estimatedLines + 16).clamp(40, 800);
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  Future<void> clearFocus() async {
    await _channel?.invokeMethod('clearFocus');
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final accentColor = colorScheme.primary.value;

    // OS 다크모드 토글 등 런타임 테마 변경 시 native EditText 색상 갱신.
    // creationParams는 view 생성 시 1회만 적용되므로 변경분은 채널로 push.
    if (_channel != null &&
        (isDark != _lastSentIsDark || accentColor != _lastSentAccentColor)) {
      _lastSentIsDark = isDark;
      _lastSentAccentColor = accentColor;
      _channel!.invokeMethod('setTheme', {
        'isDark': isDark,
        'accentColor': accentColor,
      });
    }

    return Container(
      height: _height,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        // 테두리 두께는 항상 2로 고정하고 색만 바꿔 포커스 시 레이아웃
        // 흔들림(리플로우) 없이 강조 링만 나타나게 한다.
        border: Border.all(
          color: _focused ? colorScheme.primary : Colors.transparent,
          width: 2,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: AndroidView(
        viewType: 'native-edit-text',
        gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
          Factory<EagerGestureRecognizer>(() => EagerGestureRecognizer()),
        },
        creationParams: {
          'text': widget.initialText,
          'hint': widget.hint ?? '',
          'isDark': isDark,
          'fontSize': widget.fontSize,
          'minLines': widget.minLines,
          'accentColor': accentColor,
        },
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: (int id) {
          _channel = MethodChannel('com.henry.memora/native_edit_$id');
          // creationParams로 이미 전달된 값 — 캐시에 반영해 중복 push 방지.
          _lastSentIsDark = isDark;
          _lastSentAccentColor = accentColor;
          _channel!.setMethodCallHandler((call) async {
            switch (call.method) {
              case 'onTextChanged':
                _currentText = call.arguments as String? ?? '';
                widget.onChanged?.call(_currentText);
              case 'onFocusChanged':
                final focused = call.arguments as bool? ?? false;
                if (!mounted) return;
                if (focused != _focused) setState(() => _focused = focused);
                widget.onFocusChanged?.call(focused);
              case 'onHeightChanged':
                final dp = (call.arguments as num?)?.toDouble();
                if (dp == null || !mounted) return;
                if ((dp - _height).abs() > 0.5) {
                  // native가 보고하는 dp는 setMaxLines(MAX_VALUE)로 무제한 —
                  // 초기 추정치(line 53)처럼 상한을 둬 텍스처 크기 폭주를 막는다.
                  // EditText는 view보다 내용이 길어도 내부 스크롤되므로 편집엔 지장 없음.
                  setState(() => _height = dp.clamp(40.0, 2000.0));
                }
            }
          });
        },
      ),
    );
  }
}
