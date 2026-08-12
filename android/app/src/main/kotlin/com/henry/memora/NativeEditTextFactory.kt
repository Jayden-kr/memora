package com.henry.memora

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.text.Editable
import android.text.TextWatcher
import android.util.TypedValue
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.flutter.plugin.common.StandardMessageCodec

class NativeEditTextFactory(
    private val messenger: BinaryMessenger
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val params = args as? Map<*, *> ?: emptyMap<String, Any>()
        return NativeEditTextView(context, viewId, messenger, params)
    }
}

class NativeEditTextView(
    context: Context,
    private val viewId: Int,
    messenger: BinaryMessenger,
    params: Map<*, *>
) : PlatformView {

    private val density: Float = context.resources.displayMetrics.density
    private var lastReportedHeightDp: Double = -1.0
    private var heightPostScheduled: Boolean = false
    private var lastCaretTopDp: Double = -1.0
    private var lastCaretBottomDp: Double = -1.0
    private var caretPostScheduled: Boolean = false

    // editText 초기화 중(setText 등)에도 onSelectionChanged가 불린다. 그 시점엔
    // channel이 아직 없으므로, init 블록에서 이 플래그를 연 뒤부터만 보고한다.
    private var ready: Boolean = false

    /**
     * 커서 위치 변화를 Dart에 알리기 위한 EditText.
     * EditText에는 selection 리스너가 없어 onSelectionChanged를 오버라이드한다.
     */
    private inner class CaretAwareEditText(ctx: Context) : EditText(ctx) {
        override fun onSelectionChanged(selStart: Int, selEnd: Int) {
            super.onSelectionChanged(selStart, selEnd)
            scheduleCaretReport()
        }
    }

    private val editText: EditText = CaretAwareEditText(context).apply {
        val initialText = params["text"] as? String ?: ""
        val hint = params["hint"] as? String ?: ""
        val isDark = params["isDark"] as? Boolean ?: false
        val fontSize = (params["fontSize"] as? Number)?.toFloat() ?: 16f
        val accentArgb = (params["accentColor"] as? Number)?.toLong() ?: 0xFFFF6B6B

        setText(initialText)
        setHint(hint)
        // 카드 내용에 정확히 fit: minLines=1로 두고 lineCount에 따라 자동 wrap
        setMinLines(1)
        setMaxLines(Integer.MAX_VALUE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSize)
        // 기존 1.4f에서 10% 축소
        setLineSpacing(0f, 1.26f)
        setBackgroundColor(Color.TRANSPARENT)
        val pad = (8 * context.resources.displayMetrics.density).toInt()
        setPadding(pad, pad, pad, pad)
        gravity = android.view.Gravity.TOP or android.view.Gravity.START
        inputType = EditorInfo.TYPE_CLASS_TEXT or
                EditorInfo.TYPE_TEXT_FLAG_MULTI_LINE or
                EditorInfo.TYPE_TEXT_FLAG_CAP_SENTENCES
        imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI

        isFocusable = true
        isFocusableInTouchMode = true
        isLongClickable = true

        if (isDark) {
            setTextColor(Color.parseColor("#E0E0E0"))
            setHintTextColor(Color.parseColor("#808080"))
        } else {
            setTextColor(Color.parseColor("#1C1B1F"))
            setHintTextColor(Color.parseColor("#909090"))
        }

        typeface = Typeface.create("sans-serif", Typeface.NORMAL)

        val rgb = accentArgb.toInt() and 0x00FFFFFF
        highlightColor = rgb or 0x40000000
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            textCursorDrawable?.setTint(accentArgb.toInt())
            textSelectHandle?.setTint(accentArgb.toInt())
            textSelectHandleLeft?.setTint(accentArgb.toInt())
            textSelectHandleRight?.setTint(accentArgb.toInt())
        }
    }

    private val channel = MethodChannel(messenger, "com.henry.memora/native_edit_$viewId")

    // dispose 시 cleanup하기 위해 reference 보관
    private val heightReportRunnable = Runnable {
        heightPostScheduled = false
        reportHeight()
    }
    private val caretReportRunnable = Runnable {
        caretPostScheduled = false
        reportCaret()
    }
    private val textWatcher = object : TextWatcher {
        override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
        override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
        override fun afterTextChanged(s: Editable?) {
            channel.invokeMethod("onTextChanged", s?.toString() ?: "")
            scheduleHeightReport()
            // 줄바꿈으로 커서 줄이 밀려도 selection index는 그대로일 수 있다.
            scheduleCaretReport()
        }
    }

    init {
        ready = true
        editText.addTextChangedListener(textWatcher)
        // 첫 layout 직후 초기 height 보고
        editText.post(heightReportRunnable)

        // 포커스 변경을 Dart에 보고 — Flutter는 네이티브 뷰 포커스를 모르므로
        // (일반 TextField와 달리) 키보드 등장 시 자동 스크롤이 일어나지 않는다.
        // Dart 쪽에서 이 이벤트로 포커스된 필드를 키보드 위로 스크롤한다.
        editText.setOnFocusChangeListener { _, hasFocus ->
            try {
                channel.invokeMethod("onFocusChanged", hasFocus)
            } catch (_: Throwable) {
                // dispose 직후 등 — 무시
            }
            if (hasFocus) {
                // 캐시를 비워 포커스 직후 한 번은 반드시 보고되게 한다.
                lastCaretTopDp = -1.0
                lastCaretBottomDp = -1.0
                scheduleCaretReport()
            }
        }

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setText" -> {
                    val text = call.arguments as? String ?: ""
                    editText.setText(text)
                    editText.setSelection(text.length)
                    result.success(null)
                }
                "getText" -> {
                    result.success(editText.text.toString())
                }
                "clearFocus" -> {
                    editText.clearFocus()
                    result.success(null)
                }
                "setTheme" -> {
                    val isDark = call.argument<Boolean>("isDark") ?: false
                    val accentArgb = (call.argument<Number>("accentColor"))?.toLong() ?: 0xFFFF6B6B
                    applyTheme(isDark, accentArgb)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * 런타임 테마 변경(OS 다크모드 토글 등) 시 Dart의 'setTheme' 호출로 실행.
     * init 블록의 초기 색상 적용과 동일한 로직 — editText가 이미 생성된 뒤
     * 다시 적용해야 하므로 별도 메서드로 분리.
     */
    private fun applyTheme(isDark: Boolean, accentArgb: Long) {
        if (isDark) {
            editText.setTextColor(Color.parseColor("#E0E0E0"))
            editText.setHintTextColor(Color.parseColor("#808080"))
        } else {
            editText.setTextColor(Color.parseColor("#1C1B1F"))
            editText.setHintTextColor(Color.parseColor("#909090"))
        }
        val rgb = accentArgb.toInt() and 0x00FFFFFF
        editText.highlightColor = rgb or 0x40000000
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            editText.textCursorDrawable?.setTint(accentArgb.toInt())
            editText.textSelectHandle?.setTint(accentArgb.toInt())
            editText.textSelectHandleLeft?.setTint(accentArgb.toInt())
            editText.textSelectHandleRight?.setTint(accentArgb.toInt())
        }
    }

    /**
     * 텍스트 변경마다 다음 frame에 한 번만 measure → Dart에 dp 전달.
     * 중복 schedule 방지를 위해 flag로 coalesce.
     */
    private fun scheduleHeightReport() {
        if (heightPostScheduled) return
        heightPostScheduled = true
        editText.post(heightReportRunnable)
    }

    private fun reportHeight() {
        val lineHeight = editText.lineHeight
        if (lineHeight <= 0) return
        val actualLines = editText.lineCount.coerceAtLeast(1)
        val px = actualLines * lineHeight + editText.paddingTop + editText.paddingBottom
        val dp = px.toDouble() / density
        // 동일 값 재전송 억제 (Dart side filter도 있지만 여기서도 짧게 컷)
        if (kotlin.math.abs(dp - lastReportedHeightDp) < 0.5) return
        lastReportedHeightDp = dp
        try {
            channel.invokeMethod("onHeightChanged", dp)
        } catch (_: Throwable) {
            // dispose 직후 등 — 무시
        }
    }

    /**
     * 커서가 놓인 줄의 세로 범위(필드 상단 기준 dp)를 Dart에 알린다.
     *
     * 필드 전체가 아니라 '커서 줄'을 기준으로 보내는 이유: 내용이 길어 필드가
     * 화면보다 커지면 필드 기준 스크롤은 엉뚱한 곳(필드 끝)으로 튄다. 타이핑 중
     * 실제로 보여야 하는 건 커서가 있는 줄뿐이다.
     */
    private fun scheduleCaretReport() {
        if (!ready || caretPostScheduled) return
        caretPostScheduled = true
        // layout이 갱신된 다음 프레임에 측정한다.
        editText.post(caretReportRunnable)
    }

    private fun reportCaret() {
        // 포커스가 없으면 사용자가 편집 중이 아니다 — 화면을 건드리지 않는다.
        if (!editText.isFocused) return
        // 범위 선택 중에는 보고하지 않는다. 드래그로 선택을 늘리는 동안 화면이
        // 따라 스크롤되면 손가락 밑의 글자가 밀려 선택 끝이 다시 움직이고,
        // 그게 또 스크롤을 부르는 되먹임이 생긴다. 타이핑(커서가 한 점일 때)만
        // 따라간다.
        if (editText.selectionStart != editText.selectionEnd) return
        val layout = editText.layout ?: return
        val sel = editText.selectionEnd.coerceIn(0, editText.text?.length ?: 0)
        val line = layout.getLineForOffset(sel)
        val topDp = (layout.getLineTop(line) + editText.paddingTop).toDouble() / density
        val bottomDp = (layout.getLineBottom(line) + editText.paddingTop).toDouble() / density
        // 같은 줄에서 좌우로만 움직인 경우는 스크롤할 이유가 없다.
        if (kotlin.math.abs(topDp - lastCaretTopDp) < 0.5 &&
            kotlin.math.abs(bottomDp - lastCaretBottomDp) < 0.5) return
        lastCaretTopDp = topDp
        lastCaretBottomDp = bottomDp
        try {
            channel.invokeMethod("onCaretChanged", mapOf("top" to topDp, "bottom" to bottomDp))
        } catch (_: Throwable) {
            // dispose 직후 등 — 무시
        }
    }

    override fun getView(): View = editText

    override fun dispose() {
        ready = false
        channel.setMethodCallHandler(null)
        editText.onFocusChangeListener = null
        editText.removeCallbacks(heightReportRunnable)
        editText.removeCallbacks(caretReportRunnable)
        editText.removeTextChangedListener(textWatcher)
    }
}
