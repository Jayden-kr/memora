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

    private val editText: EditText = EditText(context).apply {
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
    private val textWatcher = object : TextWatcher {
        override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
        override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
        override fun afterTextChanged(s: Editable?) {
            channel.invokeMethod("onTextChanged", s?.toString() ?: "")
            scheduleHeightReport()
        }
    }

    init {
        editText.addTextChangedListener(textWatcher)
        // 첫 layout 직후 초기 height 보고
        editText.post(heightReportRunnable)

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

    override fun getView(): View = editText

    override fun dispose() {
        channel.setMethodCallHandler(null)
        editText.removeCallbacks(heightReportRunnable)
        editText.removeTextChangedListener(textWatcher)
    }
}
