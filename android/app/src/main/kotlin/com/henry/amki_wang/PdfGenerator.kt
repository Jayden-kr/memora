package com.henry.amki_wang

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.graphics.*
import android.graphics.pdf.PdfDocument
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.util.Log
import java.io.File
import java.io.FileOutputStream

class PdfGenerator(private val context: Context) {
    companion object {
        private const val TAG = "PdfGenerator"
        private const val PW = 595   // A4 72dpi
        private const val PH = 842
        private const val M = 40f    // margin
        private const val CW = PW - 2 * M
        private const val IMG = 70f
        private const val PAD = 8f
        private const val IW = (CW - 2 * PAD).toInt()  // inner width for text
    }

    private var fontR: Typeface = Typeface.DEFAULT
    private var fontB: Typeface = Typeface.DEFAULT_BOLD

    // 재사용 Paint/TextPaint (GC 압박 방지)
    private val textPaint = TextPaint().apply { isAntiAlias = true }
    private val borderPaint = Paint().apply { style = Paint.Style.STROKE; color = Color.parseColor("#BDBDBD"); strokeWidth = 0.5f }
    private val linePaint = Paint().apply { color = Color.LTGRAY; strokeWidth = 0.5f }

    private data class Card(
        val question: String, val answer: String,
        val qImages: List<String>, val aImages: List<String>,
    )

    fun generate(
        outputPath: String,
        folderId: Int,
        folderIndex: Int = 0,
        totalFolders: Int = 1,
        onProgress: (current: Int, total: Int, message: String) -> Unit,
    ) {
        loadFonts()
        val db = openDb() ?: throw Exception("DB not found")
        try {
            val name = folderName(db, folderId) ?: "Folder"
            val cards = loadCards(db, folderId)
            val n = cards.size

            val doc = PdfDocument()
            try {
                var pn = 0
                var y = 0f
                var pg: PdfDocument.Page? = null
                var cv: Canvas? = null

                fun next(): Canvas {
                    pg?.let { doc.finishPage(it) }
                    pn++
                    val info = PdfDocument.PageInfo.Builder(PW, PH, pn).create()
                    pg = doc.startPage(info)
                    y = M
                    return pg!!.canvas
                }

                cv = next()
                // Header
                y = txt(cv, name, M, y, 22f, fontB)
                y += 2f
                y = txt(cv, "카드 ${n}장", M, y, 11f, fontR, Color.GRAY)
                y += 4f
                ln(cv, M, y, PW - M, y)
                y += 12f

                for ((i, c) in cards.withIndex()) {
                    val h = measure(c)
                    if (y + h > PH - M && y > M + 10f) {
                        cv = next()
                    }
                    y = card(cv!!, c, y)
                    y += 10f

                    if (i % 20 == 0 || i == n - 1) {
                        onProgress(i + 1, n, "$name (${i + 1}/$n)")
                        // 전체 진행률 계산: (완료 폴더 + 현재 폴더 진행률) / 전체 폴더 수
                        val overallPercent = ((folderIndex + (i + 1).toFloat() / n) / totalFolders * 100).toInt()
                        ImportExportService.updateProgress(
                            context, "Export 진행 중",
                            "$name (${i + 1}/$n) — ${folderIndex + 1}/$totalFolders",
                            overallPercent, 100, "export"
                        )
                    }
                }

                pg?.let { doc.finishPage(it) }

                onProgress(n, n, "PDF 저장 중...")
                val savePercent = ((folderIndex + 1).toFloat() / totalFolders * 100).toInt()
                ImportExportService.updateProgress(context, "Export 진행 중", "$name — PDF 저장 중...", savePercent, 100, "export")
                FileOutputStream(outputPath).use { doc.writeTo(it) }
                Log.d(TAG, "PDF saved: $outputPath ($pn pages, $n cards)")
            } finally {
                doc.close()
            }
        } finally {
            db.close()
        }
    }

    private fun measure(c: Card): Float {
        var h = PAD * 2 + 8f
        h += mTxt(c.question.ifEmpty { "(내용 없음)" }, 12f, fontB)
        if (c.qImages.isNotEmpty()) h += IMG + 4f
        h += 8f // divider
        if (c.answer.isNotEmpty()) h += mTxt(c.answer, 11f, fontR)
        if (c.aImages.isNotEmpty()) h += IMG + 4f
        return h
    }

    private fun mTxt(t: String, s: Float, tf: Typeface): Float {
        textPaint.textSize = s; textPaint.typeface = tf
        return StaticLayout.Builder.obtain(t, 0, t.length, textPaint, IW)
            .setLineSpacing(0f, 1.3f).build().height.toFloat()
    }

    private fun card(cv: Canvas, c: Card, sy: Float): Float {
        var y = sy
        val h = measure(c)
        cv.drawRoundRect(M, y, PW - M, y + h, 4f, 4f, borderPaint)
        y += PAD

        y = wrap(cv, c.question.ifEmpty { "(내용 없음)" }, M + PAD, y, 12f, fontB)
        if (c.qImages.isNotEmpty()) { y += 4f; y = imgs(cv, c.qImages, M + PAD, y) }

        y += 4f; ln(cv, M + PAD, y, PW - M - PAD, y); y += 4f

        if (c.answer.isNotEmpty()) y = wrap(cv, c.answer, M + PAD, y, 11f, fontR)
        if (c.aImages.isNotEmpty()) { y += 4f; y = imgs(cv, c.aImages, M + PAD, y) }

        return sy + h
    }

    private fun imgs(cv: Canvas, paths: List<String>, x: Float, y: Float): Float {
        var dx = x
        for (p in paths) {
            val bm = thumb(p) ?: continue
            val rh = (IMG * bm.height.toFloat() / bm.width.toFloat()).coerceAtMost(IMG)
            cv.drawBitmap(bm, null, RectF(dx, y, dx + IMG, y + rh), null)
            bm.recycle()
            dx += IMG + 6f
            if (dx + IMG > PW - M) break
        }
        return y + IMG
    }

    private fun thumb(path: String): Bitmap? {
        val f = File(path)
        if (!f.exists()) return null
        return try {
            val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(f.path, o)
            if (o.outWidth <= 0 || o.outHeight <= 0) return null
            var ss = 1
            while (o.outWidth / ss > 140) ss *= 2
            o.inJustDecodeBounds = false
            o.inSampleSize = ss
            BitmapFactory.decodeFile(f.path, o)
        } catch (_: OutOfMemoryError) { null }
        catch (_: Exception) { null }
    }

    private fun wrap(cv: Canvas, t: String, x: Float, y: Float, s: Float, tf: Typeface, col: Int = Color.BLACK): Float {
        textPaint.textSize = s; textPaint.typeface = tf; textPaint.color = col
        val l = StaticLayout.Builder.obtain(t, 0, t.length, textPaint, IW)
            .setAlignment(Layout.Alignment.ALIGN_NORMAL).setLineSpacing(0f, 1.3f).build()
        cv.save(); cv.translate(x, y); l.draw(cv); cv.restore()
        return y + l.height
    }

    private fun txt(cv: Canvas, t: String, x: Float, y: Float, s: Float, tf: Typeface, col: Int = Color.BLACK): Float {
        textPaint.textSize = s; textPaint.typeface = tf; textPaint.color = col
        cv.drawText(t, x, y + s, textPaint)
        return y + s + 4f
    }

    private fun ln(cv: Canvas, x1: Float, y1: Float, x2: Float, y2: Float) {
        cv.drawLine(x1, y1, x2, y2, linePaint)
    }

    private fun loadFonts() {
        try {
            fontR = Typeface.createFromAsset(context.assets, "fonts/Pretendard-Regular.otf")
            fontB = Typeface.createFromAsset(context.assets, "fonts/Pretendard-Bold.otf")
        } catch (_: Exception) {}
    }

    private fun openDb(): SQLiteDatabase? {
        val dir = context.applicationInfo.dataDir
        for (c in listOf(
            File(dir, "app_flutter/amki_wang.db"),
            File(context.filesDir, "app_flutter/amki_wang.db"),
            context.getDatabasePath("amki_wang.db"),
        )) { if (c.exists()) {
            val db = SQLiteDatabase.openDatabase(c.path, null, SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS)
            try { db.enableWriteAheadLogging() } catch (_: Exception) {}
            return db
        } }
        return null
    }

    private fun folderName(db: SQLiteDatabase, id: Int): String? {
        db.query("folders", arrayOf("name"), "id=?", arrayOf(id.toString()), null, null, null).use {
            if (it.moveToFirst()) return it.getString(0)
        }
        return null
    }

    private fun loadCards(db: SQLiteDatabase, folderId: Int): List<Card> {
        val r = mutableListOf<Card>()
        val columns = arrayOf("question", "answer",
            "question_image_path", "question_image_path_2", "question_image_path_3", "question_image_path_4", "question_image_path_5",
            "answer_image_path", "answer_image_path_2", "answer_image_path_3", "answer_image_path_4", "answer_image_path_5")
        db.query("cards", columns, "folder_id=?", arrayOf(folderId.toString()), null, null, "sequence ASC").use { c ->
            while (c.moveToNext()) {
                val qi = mutableListOf<String>(); val ai = mutableListOf<String>()
                for (s in listOf("", "_2", "_3", "_4", "_5")) {
                    c.getColumnIndex("question_image_path$s").let { i -> if (i >= 0) c.getString(i)?.takeIf { it.isNotEmpty() }?.let { qi.add(it) } }
                    c.getColumnIndex("answer_image_path$s").let { i -> if (i >= 0) c.getString(i)?.takeIf { it.isNotEmpty() }?.let { ai.add(it) } }
                }
                r.add(Card(
                    question = c.getString(c.getColumnIndexOrThrow("question")) ?: "",
                    answer = c.getString(c.getColumnIndexOrThrow("answer")) ?: "",
                    qImages = qi, aImages = ai,
                ))
            }
        }
        return r
    }
}
