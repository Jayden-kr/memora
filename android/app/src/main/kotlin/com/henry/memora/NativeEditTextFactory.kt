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

    private val editText: EditText = EditText(context).apply {
        val initialText = params["text"] as? String ?: ""
        val hint = params["hint"] as? String ?: ""
        val minLinesParam = (params["minLines"] as? Number)?.toInt() ?: 3
        val isDark = params["isDark"] as? Boolean ?: false
        val fontSize = (params["fontSize"] as? Number)?.toFloat() ?: 16f
        val accentArgb = (params["accentColor"] as? Number)?.toLong() ?: 0xFFFF6B6B

        setText(initialText)
        setHint(hint)
        setMinLines(minLinesParam)
        setMaxLines(Integer.MAX_VALUE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSize)
        setLineSpacing(0f, 1.4f)
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

    init {
        editText.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
            override fun afterTextChanged(s: Editable?) {
                channel.invokeMethod("onTextChanged", s?.toString() ?: "")
            }
        })

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
                else -> result.notImplemented()
            }
        }
    }

    override fun getView(): View = editText

    override fun dispose() {
        channel.setMethodCallHandler(null)
    }
}
