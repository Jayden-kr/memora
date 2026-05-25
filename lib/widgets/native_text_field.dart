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

  const NativeTextField({
    super.key,
    this.initialText = '',
    this.hint,
    this.onChanged,
    this.fontSize = 16,
    this.minLines = 3,
  });

  @override
  State<NativeTextField> createState() => NativeTextFieldState();
}

class NativeTextFieldState extends State<NativeTextField> {
  MethodChannel? _channel;
  String _currentText = '';
  double _height = 120;

  String get text => _currentText;

  @override
  void initState() {
    super.initState();
    _currentText = widget.initialText;
    _recalcHeight(_currentText);
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  void _recalcHeight(String text) {
    final charsPerLine = 30;
    final newlineCount = '\n'.allMatches(text).length;
    int wrappedLines = 0;
    for (final segment in text.split('\n')) {
      wrappedLines += segment.isEmpty ? 1 : (segment.length / charsPerLine).ceil();
    }
    final totalLines = wrappedLines > 0 ? wrappedLines : newlineCount + 1;
    final contentLines = totalLines < widget.minLines ? widget.minLines : totalLines;
    final lineHeight = widget.fontSize * 1.4 + 4;
    _height = (contentLines * lineHeight + 32).clamp(80, 800);
  }

  Future<void> clearFocus() async {
    await _channel?.invokeMethod('clearFocus');
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final accentColor = colorScheme.primary.value;

    return Container(
      height: _height,
      decoration: BoxDecoration(
        border: Border.all(color: colorScheme.outline),
        borderRadius: BorderRadius.circular(4),
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
          _channel!.setMethodCallHandler((call) async {
            if (call.method == 'onTextChanged') {
              _currentText = call.arguments as String? ?? '';
              if (!mounted) return;
              final oldHeight = _height;
              _recalcHeight(_currentText);
              if ((_height - oldHeight).abs() > 1) {
                setState(() {});
              }
              widget.onChanged?.call(_currentText);
            }
          });
        },
      ),
    );
  }
}
