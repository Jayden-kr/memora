package com.henry.memora

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
                    // 카드가 한 페이지보다 길면 card()가 next()를 호출해 이어 그린다 (버그 #26: 잘림 방지)
                    val (nc, ny) = card(cv!!, c, y) { next() }
                    cv = nc
                    y = ny
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
            } catch (e: Exception) {
                // 실패 시 불완전 PDF 파일 삭제
                try { java.io.File(outputPath).delete() } catch (_: Exception) {}
                throw e
            } finally {
                doc.close()
            }
        } finally {
            db.close()
        }
    }

    private fun measure(c: Card): Float {
        var h = PAD * 2 + 8f
        h += mTxt(c.question, 12f, fontB)
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

    // next: 현재 페이지에 다 안 들어갈 때 새 페이지 캔버스를 받아오는 콜백.
    // 카드가 페이지를 넘어갈 수 있으므로 sy+h가 아니라 실제로 그려진 (마지막 캔버스, y)를 반환한다.
    private fun card(cv: Canvas, c: Card, sy: Float, next: () -> Canvas): Pair<Canvas, Float> {
        var canvas = cv
        var y = sy
        val h = measure(c)
        canvas.drawRoundRect(M, y, PW - M, y + h, 4f, 4f, borderPaint)
        y += PAD

        var r = wrapPaged(canvas, c.question, M + PAD, y, 12f, fontB, next)
        canvas = r.first; y = r.second
        if (c.qImages.isNotEmpty()) {
            y += 4f
            if (y + IMG > PH - M) { canvas = next(); y = M }
            y = imgs(canvas, c.qImages, M + PAD, y)
        }

        y += 4f
        if (y > PH - M) { canvas = next(); y = M }
        ln(canvas, M + PAD, y, PW - M - PAD, y); y += 4f

        if (c.answer.isNotEmpty()) {
            r = wrapPaged(canvas, c.answer, M + PAD, y, 11f, fontR, next)
            canvas = r.first; y = r.second
        }
        if (c.aImages.isNotEmpty()) {
            y += 4f
            if (y + IMG > PH - M) { canvas = next(); y = M }
            y = imgs(canvas, c.aImages, M + PAD, y)
        }

        return canvas to y
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
        } catch (e: OutOfMemoryError) {
            Log.w(TAG, "OOM decoding image: $path", e)
            null
        } catch (e: Exception) {
            Log.w(TAG, "Failed to decode image: $path", e)
            null
        }
    }

    // 텍스트가 현재 페이지에 다 안 들어가면 next()로 새 페이지를 받아 줄 단위로 이어 그린다
    // (한 페이지보다 긴 카드가 잘리는 문제 방지, 버그 #26). 한 페이지에 다 들어가는 일반적인
    // 경우엔 한 번에 그려져서 기존 wrap()과 동일하게 동작한다.
    private fun wrapPaged(
        cv: Canvas, t: String, x: Float, y0: Float, s: Float, tf: Typeface,
        next: () -> Canvas, col: Int = Color.BLACK,
    ): Pair<Canvas, Float> {
        textPaint.textSize = s; textPaint.typeface = tf; textPaint.color = col
        val layout = StaticLayout.Builder.obtain(t, 0, t.length, textPaint, IW)
            .setAlignment(Layout.Alignment.ALIGN_NORMAL).setLineSpacing(0f, 1.3f).build()

        var canvas = cv
        var y = y0
        var line = 0
        val lineCount = layout.lineCount

        while (line < lineCount) {
            val top = if (line == 0) 0f else layout.getLineBottom(line - 1).toFloat()
            val firstLineH = layout.getLineBottom(line).toFloat() - top
            var avail = PH - M - y
            if (avail < firstLineH) { canvas = next(); y = M; avail = PH - M - y }

            var end = line
            while (end + 1 < lineCount && layout.getLineBottom(end + 1) - top <= avail) end++

            canvas.save()
            canvas.clipRect(x, y, x + IW, y + avail)
            canvas.translate(x, y - top)
            layout.draw(canvas)
            canvas.restore()

            y += layout.getLineBottom(end).toFloat() - top
            line = end + 1
        }
        return canvas to y
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
            File(dir, "app_flutter/memora.db"),
            File(context.filesDir, "app_flutter/memora.db"),
            context.getDatabasePath("memora.db"),
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
