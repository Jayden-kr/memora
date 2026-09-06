package com.henry.memora

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.graphics.*
import android.graphics.pdf.PdfDocument
import android.media.ExifInterface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.text.TextUtils
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
        // PDF 본문·진행 알림 문구도 앱 설정 언어를 따른다(시스템 언어 아님).
        val res = AppLang.wrap(context)
        val db = openDb() ?: throw Exception("DB not found")
        try {
            val name = DbReadRetry.run(TAG) { folderName(db, folderId) } ?: "Folder"
            val cards = DbReadRetry.run(TAG) { loadCards(db, folderId) }
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
                y = txt(cv, name, M, y, 22f, fontB, maxWidth = CW)
                y += 2f
                y = txt(cv, res.getString(R.string.pdf_card_count, n), M, y, 11f, fontR, Color.GRAY)
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
                            context, res.getString(R.string.ie_exporting),
                            "$name (${i + 1}/$n) — ${folderIndex + 1}/$totalFolders",
                            overallPercent, 100, "export"
                        )
                    }
                }

                pg?.let { doc.finishPage(it) }

                val savingPdf = res.getString(R.string.ie_saving_pdf)
                onProgress(n, n, savingPdf)
                val savePercent = ((folderIndex + 1).toFloat() / totalFolders * 100).toInt()
                ImportExportService.updateProgress(context, res.getString(R.string.ie_exporting), "$name — $savingPdf", savePercent, 100, "export")
                FileOutputStream(outputPath).use { doc.writeTo(it) }
                Log.d(TAG, "PDF saved: $outputPath ($pn pages, $n cards)")
            } catch (e: Throwable) {
                // 실패 시 불완전 PDF 파일 삭제 (OOM 같은 Error도 — 안 잡으면 잘린 PDF가 남았다, D9-06)
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

        // 호출자는 이 y에 카드 간격(10f)을 더한다. 페이지를 안 넘겼으면 테두리 박스 바닥(sy+h)을
        // 돌려줘야 다음 카드가 이 박스와 겹치지 않는다 — 내용 끝 y는 박스 바닥보다 PAD*2 위라서
        // 그대로 돌려주면 다음 박스가 6pt 겹친다(#26 수정 때 반환값을 바꾸며 생긴 회귀).
        // 페이지를 넘겼으면 박스는 첫 페이지에만 그려져 있으니 새 페이지의 내용 끝 + PAD.
        return canvas to (if (canvas === cv) sy + h else y + PAD)
    }

    private fun imgs(cv: Canvas, paths: List<String>, x: Float, y: Float): Float {
        var dx = x
        for (p in paths) {
            val bm = thumb(p) ?: continue
            // IMG×IMG 셀 안에 비율을 유지해 맞춘다(contain). 예전엔 폭을 IMG로 고정하고 높이만
            // 클램프해서 세로(portrait) 사진이 정사각형으로 찌그러졌다. 셀 전진 폭은 그대로.
            val scale = minOf(IMG / bm.width.toFloat(), IMG / bm.height.toFloat())
            val rw = bm.width * scale
            val rh = bm.height * scale
            cv.drawBitmap(bm, null, RectF(dx, y, dx + rw, y + rh), null)
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
            val raw = BitmapFactory.decodeFile(f.path, o) ?: return null
            applyExifOrientation(f.path, raw)
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

    /** 카메라 사진의 EXIF 회전을 적용한다. Flutter(Image.file)는 디코더가 EXIF를 존중하지만
     *  BitmapFactory는 무시하므로, 이걸 안 하면 앱에선 똑바로 보이는 사진이 PDF에서만 눕는다.
     *  회전에 실패(OOM)하면 원본을 그대로 쓴다 — 없는 것보다 눕는 게 낫다. */
    private fun applyExifOrientation(path: String, bm: Bitmap): Bitmap {
        val orientation = try {
            ExifInterface(path).getAttributeInt(
                ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        } catch (_: Exception) { ExifInterface.ORIENTATION_NORMAL }
        val m = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> m.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> m.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> m.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> m.preScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> m.preScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> { m.postRotate(90f); m.preScale(-1f, 1f) }
            ExifInterface.ORIENTATION_TRANSVERSE -> { m.postRotate(270f); m.preScale(-1f, 1f) }
            else -> return bm
        }
        return try {
            val rotated = Bitmap.createBitmap(bm, 0, 0, bm.width, bm.height, m, true)
            if (rotated !== bm) bm.recycle()
            rotated
        } catch (e: OutOfMemoryError) {
            Log.w(TAG, "OOM rotating image: $path", e)
            bm
        }
    }

    private fun txt(cv: Canvas, t: String, x: Float, y: Float, s: Float, tf: Typeface, col: Int = Color.BLACK, maxWidth: Float? = null): Float {
        textPaint.textSize = s; textPaint.typeface = tf; textPaint.color = col
        // 폴더 이름처럼 길이 제한이 없는 문자열은 페이지 밖으로 잘려 나가지 않게 말줄임(…).
        val shown = if (maxWidth != null)
            TextUtils.ellipsize(t, textPaint, maxWidth, TextUtils.TruncateAt.END).toString()
        else t
        cv.drawText(shown, x, y + s, textPaint)
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
            // 읽기 전용 핸들엔 enableWriteAheadLogging()이 무효 — 대신 잠금(BUSY) 시 짧게 재시도(D8-05).
            return DbReadRetry.run(TAG) {
                SQLiteDatabase.openDatabase(c.path, null, SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS)
            }
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
