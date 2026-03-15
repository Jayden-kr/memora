package com.henry.amki_wang

import android.app.*
import android.content.*
import android.content.pm.ServiceInfo
import android.database.sqlite.SQLiteDatabase
import android.graphics.*
import android.os.*
import android.provider.Settings
import android.util.Log
import android.view.*
import android.widget.*
import androidx.core.app.NotificationCompat
import kotlin.math.abs

class LockScreenService : Service() {
    companion object {
        const val CHANNEL_ID = "lock_screen_channel"
        const val NOTIFICATION_ID = 1
        const val TAG = "LockScreenService"
    }

    private var screenReceiver: ScreenReceiver? = null
    @Volatile
    private var overlayView: View? = null
    private var windowManager: WindowManager? = null

    // 서비스 활성 상태 (Handler 콜백에서 체크)
    @Volatile
    private var isServiceActive = false

    // 백그라운드 스레드 (DB 쿼리, 이미지 디코딩용)
    @Volatile
    private var bgThread: HandlerThread? = null
    @Volatile
    private var bgHandler: Handler? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // Pretendard 폰트
    private var fontRegular: Typeface? = null
    private var fontBold: Typeface? = null

    private data class CardData(
        val id: Int,
        val question: String,
        val answer: String,
        val questionImages: List<String>,
        val answerImages: List<String>,
        val finished: Boolean
    )

    @Volatile private var cards: List<CardData> = emptyList()
    @Volatile private var currentIndex = 0

    // 설정
    private var folderIds: List<Int> = emptyList()
    private var finishedFilter: Int = -1
    private var randomOrder: Boolean = true
    private var reversed: Boolean = false
    private var bgColor: Int = 0xFF1A1A2E.toInt()

    // Coral Orange 테마 색상
    private val coralPrimary = Color.parseColor("#FF6B6B")
    private val coralLight = Color.parseColor("#FFA8A8")
    private val textWhite = Color.parseColor("#F5F5F5")
    private val textGray = Color.parseColor("#AAAAAA")
    private val textDimGray = Color.parseColor("#666666")

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "onCreate")
        isServiceActive = true
        windowManager = getSystemService(WINDOW_SERVICE) as? WindowManager
        createNotificationChannel()
        loadFonts()
    }

    private fun loadFonts() {
        try {
            fontRegular = Typeface.createFromAsset(assets, "fonts/Pretendard-Regular.otf")
            fontBold = Typeface.createFromAsset(assets, "fonts/Pretendard-Bold.otf")
            Log.d(TAG, "Pretendard fonts loaded")
        } catch (e: Exception) {
            Log.w(TAG, "Failed to load Pretendard fonts, using default", e)
            fontRegular = Typeface.DEFAULT
            fontBold = Typeface.DEFAULT_BOLD
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "onStartCommand action=${intent?.action}")
        try {
            when (intent?.action) {
                "SHOW_OVERLAY" -> {
                    showOverlay()
                    return START_NOT_STICKY
                }
                "RECREATE_NOTIFICATION" -> {
                    // 알림이 스와이프로 제거된 경우 → 다시 표시
                    val notification = createNotification()
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                        startForeground(
                            NOTIFICATION_ID,
                            notification,
                            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                        )
                    } else {
                        startForeground(NOTIFICATION_ID, notification)
                    }
                    return START_STICKY
                }
                "STOP_SERVICE" -> {
                    setServiceRunning(false)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        stopForeground(STOP_FOREGROUND_REMOVE)
                    } else {
                        @Suppress("DEPRECATION")
                        stopForeground(true)
                    }
                    stopSelf()
                    return START_NOT_STICKY
                }
                else -> {
                    loadSettings()
                    val notification = createNotification()
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                        startForeground(
                            NOTIFICATION_ID,
                            notification,
                            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                        )
                    } else {
                        startForeground(NOTIFICATION_ID, notification)
                    }
                    Log.d(TAG, "startForeground OK")
                    setServiceRunning(true)
                    registerScreenReceiver()
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "onStartCommand error", e)
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onDestroy() {
        Log.d(TAG, "onDestroy")
        isServiceActive = false
        setServiceRunning(false)
        unregisterScreenReceiver()
        dismissOverlay()
        fontRegular = null
        fontBold = null
        // 대기 중인 콜백 제거 → 서비스 GC 지연 방지
        mainHandler.removeCallbacksAndMessages(null)
        bgHandler?.removeCallbacksAndMessages(null)
        bgThread?.quitSafely()
        bgThread = null
        bgHandler = null
        super.onDestroy()
    }

    private fun setServiceRunning(running: Boolean) {
        getSharedPreferences("lock_screen_prefs", MODE_PRIVATE)
            .edit().putBoolean("service_running", running).commit()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "잠금화면 학습",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "잠금화면 카드 표시 서비스"
                setShowBadge(false)
            }
            val nm = getSystemService(NotificationManager::class.java) ?: return
            nm.createNotificationChannel(channel)
        }
    }

    private fun createNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // 알림이 스와이프로 제거되면 서비스가 다시 알림을 생성
        val recreateIntent = Intent(this, LockScreenService::class.java).apply {
            action = "RECREATE_NOTIFICATION"
        }
        val deletePendingIntent = PendingIntent.getService(
            this, 100, recreateIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Memora")
            .setContentText("잠금화면 학습 활성화")
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(pendingIntent)
            .setDeleteIntent(deletePendingIntent)
            .setOngoing(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun registerScreenReceiver() {
        if (screenReceiver != null) return
        screenReceiver = ScreenReceiver()
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(screenReceiver, filter, RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(screenReceiver, filter)
            }
            Log.d(TAG, "ScreenReceiver registered")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to register ScreenReceiver", e)
            screenReceiver = null
        }
    }

    private fun unregisterScreenReceiver() {
        screenReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (_: Exception) {}
            screenReceiver = null
        }
    }

    private fun loadSettings() {
        val prefs = getSharedPreferences("lock_screen_prefs", MODE_PRIVATE)
        folderIds = prefs.getString("folder_ids", "")
            ?.split(",")
            ?.filter { it.isNotEmpty() }
            ?.mapNotNull { it.toIntOrNull() }
            ?: emptyList()
        finishedFilter = prefs.getInt("finished_filter", -1)
        randomOrder = prefs.getBoolean("random_order", true)
        reversed = prefs.getBoolean("reversed", false)
        bgColor = prefs.getInt("bg_color", 0xFF1A1A2E.toInt())
        Log.d(TAG, "Settings loaded: folders=$folderIds, filter=$finishedFilter, bg=$bgColor")
    }

    /**
     * DB 파일을 찾는다. Flutter path_provider 버전에 따라 경로가 다를 수 있으므로
     * 여러 경로를 시도한다.
     */
    private fun findDbFile(): java.io.File? {
        val dataDir = applicationInfo.dataDir
        val candidates = listOf(
            java.io.File(dataDir, "app_flutter/amki_wang.db"),
            java.io.File(filesDir, "app_flutter/amki_wang.db"),
            java.io.File(filesDir, "amki_wang.db"),
            getDatabasePath("amki_wang.db")
        )
        for (candidate in candidates) {
            Log.d(TAG, "Trying DB path: ${candidate.path} exists=${candidate.exists()}")
            if (candidate.exists()) return candidate
        }
        Log.e(TAG, "DB file not found in any candidate path!")
        return null
    }

    private fun loadCardsFromDb() {
        val dbFile = findDbFile()
        if (dbFile == null) {
            cards = emptyList()
            return
        }
        Log.d(TAG, "Using DB: ${dbFile.path}")

        var db: SQLiteDatabase? = null
        try {
            db = SQLiteDatabase.openDatabase(dbFile.path, null, SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS)
            val whereParts = mutableListOf<String>()
            val whereArgs = mutableListOf<String>()

            if (folderIds.isNotEmpty()) {
                val placeholders = folderIds.joinToString(",") { "?" }
                whereParts.add("folder_id IN ($placeholders)")
                whereArgs.addAll(folderIds.map { it.toString() })
            }
            if (finishedFilter >= 0) {
                whereParts.add("finished = ?")
                whereArgs.add(finishedFilter.toString())
            }

            val where = if (whereParts.isNotEmpty()) whereParts.joinToString(" AND ") else null
            val args = if (whereArgs.isNotEmpty()) whereArgs.toTypedArray() else null

            val result = mutableListOf<CardData>()
            db.query("cards", null, where, args, null, null, "sequence ASC").use { cursor ->
                while (cursor.moveToNext()) {
                    val qImages = mutableListOf<String>()
                    val aImages = mutableListOf<String>()
                    for (suffix in listOf("", "_2", "_3", "_4", "_5")) {
                        cursor.getColumnIndex("question_image_path$suffix").let { idx ->
                            if (idx >= 0) cursor.getString(idx)?.let { qImages.add(it) }
                        }
                        cursor.getColumnIndex("answer_image_path$suffix").let { idx ->
                            if (idx >= 0) cursor.getString(idx)?.let { aImages.add(it) }
                        }
                    }
                    result.add(CardData(
                        id = cursor.getInt(cursor.getColumnIndexOrThrow("id")),
                        question = cursor.getString(cursor.getColumnIndexOrThrow("question")) ?: "",
                        answer = cursor.getString(cursor.getColumnIndexOrThrow("answer")) ?: "",
                        questionImages = qImages,
                        answerImages = aImages,
                        finished = cursor.getInt(cursor.getColumnIndexOrThrow("finished")) == 1
                    ))
                }
            }
            cards = if (randomOrder) result.shuffled() else result
            Log.d(TAG, "Loaded ${cards.size} cards from DB")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load cards", e)
            cards = emptyList()
        } finally {
            db?.close()
        }
    }

    @Synchronized
    private fun ensureBgThread() {
        if (!isServiceActive) return
        if (bgThread == null) {
            bgThread = HandlerThread("LockScreenBG").apply { start() }
            bgHandler = Handler(bgThread!!.looper)
        }
    }

    private fun showOverlay() {
        if (!Settings.canDrawOverlays(this)) {
            Log.w(TAG, "No overlay permission")
            return
        }
        if (overlayView != null) {
            Log.d(TAG, "Overlay already showing, skip")
            return
        }

        loadSettings()

        // DB 쿼리를 백그라운드 스레드에서 실행하여 ANR 방지
        ensureBgThread()
        bgHandler?.post {
            if (!isServiceActive) return@post
            loadCardsFromDb()
            mainHandler.post {
                if (!isServiceActive) return@post
                if (cards.isEmpty()) {
                    Log.w(TAG, "No cards to show")
                    return@post
                }
                showOverlayOnMainThread()
            }
        }
    }

    private fun showOverlayOnMainThread() {
        if (overlayView != null) return

        currentIndex = 0

        overlayView = createOverlayLayout()

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE,
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_TRANSLUCENT_STATUS or
                WindowManager.LayoutParams.FLAG_TRANSLUCENT_NAVIGATION,
            PixelFormat.TRANSLUCENT
        )

        try {
            windowManager?.addView(overlayView, params)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to add overlay view", e)
            overlayView = null
            return
        }
        try {
            updateCardDisplay()
            Log.d(TAG, "Overlay shown with ${cards.size} cards")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to update card display", e)
            // View was added, so still functional; don't null out overlayView
        }
    }

    private fun createOverlayLayout(): View {
        val density = resources.displayMetrics.density

        val root = FrameLayout(this).apply {
            setBackgroundColor(bgColor)
        }

        // ─── Coral 프로그레스 바 ───
        val progressBar = View(this).apply {
            tag = "progressBar"
            setBackgroundColor(coralPrimary)
        }
        val progressBarBg = FrameLayout(this).apply {
            tag = "progressBarBg"
            setBackgroundColor(Color.parseColor("#33FFFFFF"))
            addView(progressBar, FrameLayout.LayoutParams(0, dp(2)))
        }

        // ─── 카드 영역 ───
        val scrollView = ScrollView(this).apply {
            tag = "cardScroll"
            setPadding(dp(24), dp(10), dp(24), dp(8))
            isVerticalScrollBarEnabled = false
        }

        val cardContent = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            tag = "cardContent"
        }

        // QUESTION 라벨
        val labelText = TextView(this).apply {
            tag = "labelText"
            setTextColor(coralPrimary)
            textSize = 11f
            typeface = fontBold
            isAllCaps = true
            letterSpacing = 0.1f
        }

        // Question 텍스트
        val mainText = TextView(this).apply {
            tag = "mainText"
            setTextColor(textWhite)
            textSize = 17f
            typeface = fontRegular
            setPadding(0, dp(6), 0, 0)
            setLineSpacing(dp(2).toFloat(), 1f)
        }

        // 질문 이미지 컨테이너
        val imageContainer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            tag = "imageContainer"
            setPadding(0, dp(10), 0, 0)
        }

        // ─── Answer 구분선 ───
        val answerDivider = View(this).apply {
            setBackgroundColor(Color.parseColor("#33FFFFFF"))
        }

        // ANSWER 라벨
        val answerLabel = TextView(this).apply {
            tag = "answerLabel"
            setTextColor(coralPrimary)
            textSize = 11f
            typeface = fontBold
            isAllCaps = true
            letterSpacing = 0.1f
        }

        // Answer 텍스트
        val answerText = TextView(this).apply {
            tag = "answerText"
            setTextColor(textWhite)
            textSize = 17f
            typeface = fontRegular
            setPadding(0, dp(6), 0, 0)
            setLineSpacing(dp(2).toFloat(), 1f)
        }

        // Answer 이미지 컨테이너
        val answerImageContainer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            tag = "answerImageContainer"
            setPadding(0, dp(10), 0, 0)
        }

        cardContent.addView(labelText)
        cardContent.addView(mainText)
        cardContent.addView(imageContainer)
        cardContent.addView(answerDivider, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, dp(1)).apply {
            topMargin = dp(16)
            bottomMargin = dp(12)
        })
        // Answer 영역을 감싸는 컨테이너 (좌우 스와이프 → 카드 넘기기)
        val answerContainer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            tag = "answerContainer"
        }
        answerContainer.addView(answerLabel)
        answerContainer.addView(answerText)
        answerContainer.addView(answerImageContainer)

        val cardGesture = GestureDetector(this, object : GestureDetector.SimpleOnGestureListener() {
            override fun onFling(e1: MotionEvent?, e2: MotionEvent, velocityX: Float, velocityY: Float): Boolean {
                if (e1 == null) return false
                val diffX = e2.x - e1.x
                val diffY = e2.y - e1.y
                if (abs(diffX) > abs(diffY) && abs(diffX) > 100 && abs(velocityX) > 100) {
                    if (diffX < 0 && currentIndex < cards.size - 1) {
                        currentIndex++
                        updateCardDisplay()
                    } else if (diffX > 0 && currentIndex > 0) {
                        currentIndex--
                        updateCardDisplay()
                    }
                    return true
                }
                return false
            }
        })
        answerContainer.setOnTouchListener { _, event ->
            // fling 감지만 시도하고 항상 false 반환하여 ScrollView 스크롤 허용
            cardGesture.onTouchEvent(event)
            false
        }

        cardContent.addView(answerContainer)
        scrollView.addView(cardContent)

        // ─── 하단: 스와이프 잠금 해제 ───
        val bottomContainer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
        }

        val bottomDivider = View(this).apply {
            setBackgroundColor(coralPrimary)
        }
        bottomContainer.addView(bottomDivider, LinearLayout.LayoutParams(dp(40), dp(3)).apply {
            gravity = Gravity.CENTER_HORIZONTAL
            bottomMargin = dp(8)
        })

        val swipeHint = TextView(this).apply {
            text = "좌우로 스와이프하여 잠금 해제"
            setTextColor(textDimGray)
            textSize = 11f
            typeface = fontRegular
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, dp(48))
        }
        bottomContainer.addView(swipeHint)

        // 하단 영역 좌우 스와이프 → 잠금 해제
        val unlockGesture = GestureDetector(this, object : GestureDetector.SimpleOnGestureListener() {
            override fun onFling(e1: MotionEvent?, e2: MotionEvent, velocityX: Float, velocityY: Float): Boolean {
                if (e1 == null) return false
                val diffX = e2.x - e1.x
                if (abs(diffX) > 80 && abs(velocityX) > 80) {
                    dismissOverlay()
                    return true
                }
                return false
            }
        })
        bottomContainer.setOnTouchListener { _, event ->
            unlockGesture.onTouchEvent(event)
            true
        }

        // ─── 조합 ───
        root.addView(progressBarBg, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, dp(2)
        ).apply { topMargin = dp(44) })

        root.addView(scrollView, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT
        ).apply {
            topMargin = dp(48)
            bottomMargin = dp(76)
        })

        root.addView(bottomContainer, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.BOTTOM
        ))

        setupGestures(root)
        return root
    }

    private fun dp(value: Int): Int {
        return (value * resources.displayMetrics.density).toInt()
    }

    private fun setupGestures(view: View) {
        val gestureDetector = GestureDetector(this, object : GestureDetector.SimpleOnGestureListener() {
            private val SWIPE_THRESHOLD = 100
            private val SWIPE_VELOCITY_THRESHOLD = 100

            override fun onFling(e1: MotionEvent?, e2: MotionEvent, velocityX: Float, velocityY: Float): Boolean {
                if (e1 == null) return false
                val diffX = e2.x - e1.x
                val diffY = e2.y - e1.y

                // 좌우 스와이프 → 카드 넘기기
                if (abs(diffX) > abs(diffY) && abs(diffX) > SWIPE_THRESHOLD && abs(velocityX) > SWIPE_VELOCITY_THRESHOLD) {
                    if (diffX < 0) {
                        if (currentIndex < cards.size - 1) {
                            currentIndex++
                            updateCardDisplay()
                        }
                    } else {
                        if (currentIndex > 0) {
                            currentIndex--
                            updateCardDisplay()
                        }
                    }
                    return true
                }
                return false
            }
        })

        view.setOnTouchListener { _, event ->
            gestureDetector.onTouchEvent(event)
            true
        }
    }

    private fun updateCardDisplay() {
        val root = overlayView ?: return
        val localCards = cards // @Volatile 로컬 캡처 (스레드 간 재할당 안전)
        if (localCards.isEmpty()) return
        if (currentIndex >= localCards.size) currentIndex = 0

        val card = localCards[currentIndex]

        // reversed 모드: 질문/답 순서 바꿈
        val qText: String; val aText: String
        val qImages: List<String>; val aImages: List<String>
        val qLabel: String; val aLabel: String
        if (!reversed) {
            qText = card.question; aText = card.answer
            qImages = card.questionImages; aImages = card.answerImages
            qLabel = "QUESTION"; aLabel = "ANSWER"
        } else {
            qText = card.answer; aText = card.question
            qImages = card.answerImages; aImages = card.questionImages
            qLabel = "ANSWER"; aLabel = "QUESTION"
        }

        // 프로그레스 바 업데이트
        val progressBarBg = root.findViewWithTag<FrameLayout>("progressBarBg")
        val progressBar = root.findViewWithTag<View>("progressBar")
        if (progressBarBg != null && progressBar != null) {
            progressBarBg.post {
                val totalWidth = progressBarBg.width
                val progress = if (localCards.size > 1) {
                    (totalWidth * (currentIndex + 1).toFloat() / localCards.size).toInt()
                } else {
                    totalWidth
                }
                val lp = progressBar.layoutParams
                if (lp != null) {
                    lp.width = progress
                    progressBar.layoutParams = lp
                } else {
                    progressBar.layoutParams = FrameLayout.LayoutParams(progress, dp(2))
                }
            }
        }

        // Question 섹션
        root.findViewWithTag<TextView>("labelText")?.text = qLabel
        root.findViewWithTag<TextView>("mainText")?.text =
            if (qText.isEmpty()) "(내용 없음)" else qText
        loadImages(root.findViewWithTag("imageContainer"), qImages)

        // Answer 섹션
        root.findViewWithTag<TextView>("answerLabel")?.text = aLabel
        root.findViewWithTag<TextView>("answerText")?.text =
            if (aText.isEmpty()) "(내용 없음)" else aText
        loadImages(root.findViewWithTag("answerImageContainer"), aImages)
    }

    private fun recycleViewBitmaps(view: android.view.View) {
        if (view is ImageView) {
            val drawable = view.drawable
            view.setImageDrawable(null)
            // 메인 스레드에서 drawable 해제 후 recycle — draw 파이프라인에서 제거된 상태이므로 안전
            if (drawable is android.graphics.drawable.BitmapDrawable) {
                val bitmap = drawable.bitmap
                if (bitmap != null && !bitmap.isRecycled) {
                    bitmap.recycle()
                }
            }
        }
        if (view is android.view.ViewGroup) {
            for (i in 0 until view.childCount) {
                val child = view.getChildAt(i) ?: continue
                recycleViewBitmaps(child)
            }
        }
    }

    private fun loadImages(container: LinearLayout?, images: List<String>) {
        // 이전 Bitmap 재활용 후 뷰 제거
        container?.let { c ->
            for (i in 0 until c.childCount) {
                recycleViewBitmaps(c.getChildAt(i))
            }
        }
        container?.removeAllViews()
        if (images.isEmpty() || container == null) return
        val screenWidth = maxOf(resources.displayMetrics.widthPixels, 360)
        val service = this

        // 이미지 디코딩을 백그라운드 스레드에서 실행하여 ANR 방지
        ensureBgThread()
        bgHandler?.post {
            if (!isServiceActive) return@post
            val bitmaps = mutableListOf<Bitmap>()
            var totalBytes = 0L
            val maxTotalBytes = 48L * 1024 * 1024  // 48 MB cap for all images
            for (path in images) {
                if (!isServiceActive) break
                if (totalBytes >= maxTotalBytes) break
                val file = java.io.File(path)
                if (!file.exists()) continue
                try {
                    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    BitmapFactory.decodeFile(path, bounds)
                    // 무효한 이미지 dimensions 스킵 (무한루프/크래시 방지)
                    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) continue
                    var sampleSize = 1
                    val imgWidth = bounds.outWidth
                    while (imgWidth / sampleSize > screenWidth) {
                        sampleSize *= 2
                    }
                    val options = BitmapFactory.Options().apply {
                        inSampleSize = sampleSize
                        inPreferredConfig = Bitmap.Config.RGB_565  // 2 bytes/pixel vs 4
                    }
                    BitmapFactory.decodeFile(path, options)?.let { bmp ->
                        totalBytes += bmp.byteCount
                        if (totalBytes > maxTotalBytes) {
                            bmp.recycle()
                        } else {
                            bitmaps.add(bmp)
                        }
                    }
                } catch (_: Exception) { }
            }
            // 메인 스레드에서 ImageView에 세팅
            mainHandler.post {
                // 서비스 파괴 후 또는 container 제거 후: bitmap 정리
                if (!isServiceActive || container.parent == null) {
                    bitmaps.forEach { if (!it.isRecycled) it.recycle() }
                    return@post
                }
                for (bitmap in bitmaps) {
                    val imageView = ImageView(service).apply {
                        setImageBitmap(bitmap)
                        scaleType = ImageView.ScaleType.FIT_CENTER
                        adjustViewBounds = true
                        val lp = LinearLayout.LayoutParams(
                            LinearLayout.LayoutParams.MATCH_PARENT,
                            LinearLayout.LayoutParams.WRAP_CONTENT
                        )
                        lp.bottomMargin = dp(8)
                        layoutParams = lp
                    }
                    container.addView(imageView)
                }
            }
        }
    }

    private fun dismissOverlay() {
        overlayView?.let { view ->
            // 먼저 drawable 참조 해제 (setImageDrawable(null))
            val bitmapsToRecycle = collectBitmaps(view)
            try {
                windowManager?.removeView(view)
            } catch (_: Exception) {}
            overlayView = null
            // removeView 후 다음 프레임에서 bitmap recycle (draw pipeline 완료 보장)
            mainHandler.post {
                bitmapsToRecycle.forEach { bmp ->
                    if (!bmp.isRecycled) bmp.recycle()
                }
            }
        }
    }

    /** drawable 참조 해제하고, recycle 할 bitmap 목록 반환 */
    private fun collectBitmaps(view: View): List<Bitmap> {
        val bitmaps = mutableListOf<Bitmap>()
        if (view is ImageView) {
            val drawable = view.drawable
            view.setImageDrawable(null)
            if (drawable is android.graphics.drawable.BitmapDrawable) {
                drawable.bitmap?.let { if (!it.isRecycled) bitmaps.add(it) }
            }
        }
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                view.getChildAt(i)?.let { bitmaps.addAll(collectBitmaps(it)) }
            }
        }
        return bitmaps
    }
}
