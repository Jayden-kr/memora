package com.henry.memora

import android.animation.ValueAnimator
import android.app.*
import android.content.*
import android.content.pm.ServiceInfo
import android.database.sqlite.SQLiteDatabase
import android.graphics.*
import android.os.*
import android.provider.Settings
import android.util.Log
import android.view.*
import android.view.animation.LinearInterpolator
import android.view.animation.OvershootInterpolator
import android.widget.*
import androidx.core.app.NotificationCompat
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.abs
import kotlin.math.sin

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
        val folderId: Int,
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

    // 하단 막대: 지렁이 울렁임 + 슬라이드 압축 모션
    @Volatile
    private var bottomBarIdleAnimator: ValueAnimator? = null
    @Volatile
    private var bottomBarSlideAnimator: ValueAnimator? = null
    private var bottomBarDragStartX = 0f
    private var bottomBarIsDragging = false
    private var lastFrameTimeMs = 0L

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
        } catch (e: Throwable) { // Exception + Error (OOM 포함)
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
                    // startForegroundService로 시작된 경우 반드시 startForeground 호출 필요 (Android 12+ 크래시 방지)
                    val notification = createNotification()
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                        startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
                    } else {
                        startForeground(NOTIFICATION_ID, notification)
                    }
                    showOverlay()
                    // START_STICKY 유지: SHOW_OVERLAY가 마지막 onStartCommand일 때도
                    // OS kill 후 서비스가 자동 재시작되어야 함 (START_NOT_STICKY면 영구 중단)
                    return START_STICKY
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
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("navigate_to", "lock_screen_settings")
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 1, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // 알림이 스와이프로 제거되면 서비스가 다시 알림을 생성
        val recreateIntent = Intent(this, LockScreenService::class.java).apply {
            action = "RECREATE_NOTIFICATION"
        }
        val deletePendingIntent = PendingIntent.getForegroundService(
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
            java.io.File(dataDir, "app_flutter/memora.db"),
            java.io.File(filesDir, "app_flutter/memora.db"),
            java.io.File(filesDir, "memora.db"),
            getDatabasePath("memora.db")
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
            try { db.enableWriteAheadLogging() } catch (_: Exception) {} // WAL 모드: Flutter sqflite와 동시 읽기 허용
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
            val columns = arrayOf("id", "folder_id", "question", "answer", "finished",
                "question_image_path", "question_image_path_2", "question_image_path_3", "question_image_path_4", "question_image_path_5",
                "answer_image_path", "answer_image_path_2", "answer_image_path_3", "answer_image_path_4", "answer_image_path_5")
            db.query("cards", columns, where, args, null, null, "sequence ASC").use { cursor ->
                while (cursor.moveToNext()) {
                    val qImages = mutableListOf<String>()
                    val aImages = mutableListOf<String>()
                    for (suffix in listOf("", "_2", "_3", "_4", "_5")) {
                        cursor.getColumnIndex("question_image_path$suffix").let { idx ->
                            if (idx >= 0) cursor.getString(idx)?.takeIf { it.isNotEmpty() }?.let { qImages.add(it) }
                        }
                        cursor.getColumnIndex("answer_image_path$suffix").let { idx ->
                            if (idx >= 0) cursor.getString(idx)?.takeIf { it.isNotEmpty() }?.let { aImages.add(it) }
                        }
                    }
                    result.add(CardData(
                        id = cursor.getInt(cursor.getColumnIndexOrThrow("id")),
                        folderId = cursor.getInt(cursor.getColumnIndexOrThrow("folder_id")),
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
            // 부분적으로 추가된 뷰 정리 시도
            try { windowManager?.removeView(overlayView) } catch (_: Exception) {}
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
                    val localCards = cards // snapshot to prevent race
                    synchronized(this@LockScreenService) {
                        if (diffX < 0 && currentIndex < localCards.size - 1) {
                            currentIndex++
                            updateCardDisplay()
                        } else if (diffX > 0 && currentIndex > 0) {
                            currentIndex--
                            updateCardDisplay()
                        }
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

        // ─── 하단: 지렁이 울렁임 막대 + 슬라이드 압축 + 페인트 방울 ───
        val bottomContainer = FrameLayout(this).apply {
            tag = "bottomContainer"
        }

        val wormBar = WormBarView(this).apply {
            tag = "wormBarView"
        }
        bottomContainer.addView(wormBar, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.BOTTOM
        ))

        // idle 울렁임 애니메이션 + 드래그 인터랙션
        startBottomBarIdleAnimation(wormBar)
        setupBottomBarDrag(bottomContainer, wormBar)

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

    /**
     * 현재 표시 중인 카드를 편집 화면으로 열기.
     * 잠금화면을 dismiss하고 MainActivity를 시작하면서 cardId/folderId를 extra로 전달.
     */
    private fun openCurrentCardForEditing() {
        val localCards = cards
        if (localCards.isEmpty() || currentIndex >= localCards.size) {
            dismissOverlay()
            return
        }
        val card = localCards[currentIndex]
        try {
            val intent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra("navigate_to_edit_card", true)
                putExtra("card_id", card.id)
                putExtra("folder_id", card.folderId)
            }
            startActivity(intent)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to open edit screen", e)
        }
        dismissOverlay()
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
                    val localCards = cards // @Volatile snapshot
                    synchronized(this@LockScreenService) {
                        if (diffX < 0) {
                            if (currentIndex < localCards.size - 1) {
                                currentIndex++
                                updateCardDisplay()
                            }
                        } else {
                            if (currentIndex > 0) {
                                currentIndex--
                                updateCardDisplay()
                            }
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
        synchronized(this) {
            if (currentIndex >= localCards.size) currentIndex = 0
        }

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

    private val imageLoadGeneration = AtomicInteger(0)

    private fun loadImages(container: LinearLayout?, images: List<String>) {
        val generation = imageLoadGeneration.incrementAndGet() // 세대 토큰으로 구 콜백 무효화
        // 이전 Bitmap을 drawable 해제 후 다음 프레임에서 recycle (draw pipeline 완료 보장)
        container?.let { c ->
            val oldBitmaps = mutableListOf<Bitmap>()
            for (i in 0 until c.childCount) {
                val child = c.getChildAt(i)
                if (child is ImageView) {
                    val drawable = child.drawable
                    child.setImageDrawable(null)
                    if (drawable is android.graphics.drawable.BitmapDrawable) {
                        drawable.bitmap?.let { if (!it.isRecycled) oldBitmaps.add(it) }
                    }
                }
            }
            c.removeAllViews()
            if (oldBitmaps.isNotEmpty()) {
                mainHandler.post { oldBitmaps.forEach { if (!it.isRecycled) it.recycle() } }
            }
        }
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
                // 세대 불일치 (새 loadImages 호출됨) 또는 서비스 파괴 시: bitmap 정리
                if (generation != imageLoadGeneration.get() || !isServiceActive || container.parent == null) {
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

    // ───────────────────────────────────────────────────────
    // 하단 막대: 지렁이 울렁임 + 슬라이드 압축 + 페인트 방울
    // ───────────────────────────────────────────────────────

    /** dp(Int): 픽셀 정수 / dp(Float): 픽셀 Float (Custom View 내부에서 사용) */
    private fun dp(value: Float): Float {
        return value * resources.displayMetrics.density
    }

    private fun startBottomBarIdleAnimation(view: WormBarView) {
        if (!isServiceActive) return
        bottomBarIdleAnimator?.cancel()
        lastFrameTimeMs = SystemClock.uptimeMillis()
        val animator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 1000L
            repeatCount = ValueAnimator.INFINITE
            interpolator = LinearInterpolator()
            addUpdateListener {
                if (!isServiceActive) {
                    cancel()
                    return@addUpdateListener
                }
                val now = SystemClock.uptimeMillis()
                var dt = (now - lastFrameTimeMs).toFloat()
                lastFrameTimeMs = now
                if (dt > 100f) dt = 16f // 큰 갭 클램프 (백그라운드 후 복귀 등)
                view.update(dt)
            }
        }
        bottomBarIdleAnimator = animator
        animator.start()
    }

    private fun stopBottomBarIdleAnimation() {
        bottomBarIdleAnimator?.cancel()
        bottomBarIdleAnimator = null
        bottomBarSlideAnimator?.cancel()
        bottomBarSlideAnimator = null
    }

    private fun setupBottomBarDrag(container: FrameLayout, view: WormBarView) {
        val touchSlop = dp(4).toFloat()
        val maxDragDistance = dp(60).toFloat()    // 이만큼 가면 progress = ±1
        val swipeThreshold = dp(50).toFloat()     // 이상이면 액션 발동

        container.setOnTouchListener { _, event ->
            when (event.action and MotionEvent.ACTION_MASK) {
                MotionEvent.ACTION_DOWN -> {
                    bottomBarSlideAnimator?.cancel()
                    bottomBarDragStartX = event.rawX
                    bottomBarIsDragging = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - bottomBarDragStartX
                    if (!bottomBarIsDragging && abs(dx) > touchSlop) {
                        bottomBarIsDragging = true
                    }
                    if (bottomBarIsDragging) {
                        view.slideProgress = (dx / maxDragDistance).coerceIn(-1f, 1f)
                    }
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    val dx = event.rawX - bottomBarDragStartX
                    val wasDragging = bottomBarIsDragging
                    bottomBarIsDragging = false
                    if (wasDragging && abs(dx) > swipeThreshold) {
                        completeBottomBarAction(view, dx)
                    } else {
                        snapBackBottomBar(view)
                    }
                    true
                }
                else -> false
            }
        }
    }

    private fun snapBackBottomBar(view: WormBarView) {
        bottomBarSlideAnimator?.cancel()
        val animator = ValueAnimator.ofFloat(view.slideProgress, 0f).apply {
            duration = 320L
            interpolator = OvershootInterpolator(1.6f)
            addUpdateListener {
                view.slideProgress = it.animatedValue as Float
            }
        }
        bottomBarSlideAnimator = animator
        animator.start()
    }

    private fun completeBottomBarAction(view: WormBarView, dx: Float) {
        val direction = if (dx > 0) 1f else -1f
        bottomBarSlideAnimator?.cancel()
        val animator = ValueAnimator.ofFloat(view.slideProgress, direction).apply {
            duration = 200L
            addUpdateListener {
                view.slideProgress = it.animatedValue as Float
            }
            addListener(object : android.animation.AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: android.animation.Animator) {
                    if (direction > 0) {
                        dismissOverlay()
                    } else {
                        openCurrentCardForEditing()
                    }
                }
            })
        }
        bottomBarSlideAnimator = animator
        animator.start()
    }

    /**
     * 지렁이처럼 울렁이는 막대 + 슬라이드 압축 + 페인트 방울 잔상.
     * 모든 그리기는 Canvas로 처리 (Path + Circle).
     * - slideProgress: -1f (좌측 압축) ~ 0f (idle) ~ +1f (우측 압축)
     * - 막대는 원래 막대기 영역(dp64) 안에서만 압축. 한쪽 끝 고정 + 반대편이 줄어듦.
     * - 잔 방울도 막대 영역 X 범위 안에서만 형성 → 짧게 떨어지며 사라짐.
     */
    private inner class WormBarView(context: Context) : View(context) {
        init {
            // BlurMaskFilter는 hardware acceleration에서 작동 안 함 → SW layer 필요
            setLayerType(LAYER_TYPE_SOFTWARE, null)
        }

        private val barPaint = Paint().apply {
            color = coralPrimary
            isAntiAlias = true
            style = Paint.Style.FILL
        }
        // 막대 주변 부드러운 광채 (Coral glow) — 어두운 배경에서 모던한 느낌
        private val glowPaint = Paint().apply {
            color = coralPrimary
            isAntiAlias = true
            style = Paint.Style.FILL
            alpha = 110
            maskFilter = BlurMaskFilter(dp(7f), BlurMaskFilter.Blur.NORMAL)
        }

        private val barWidthPx: Float = dp(64f)
        private val barThicknessPx: Float = dp(8f)
        private val waveAmpPx: Float = dp(2.31f)           // 울렁임 진폭
        private val bottomMarginPx: Float = dp(54f)        // 화면 하단 ~ 막대 중심 거리
        private val topPadPx: Float = dp(28f)              // wave 위쪽 여유

        var wormPhase: Float = 0f
        var slideProgress: Float = 0f

        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
            val w = MeasureSpec.getSize(widthMeasureSpec)
            // glow blur(dp7)가 위로 퍼지는 공간 + 막대 + 하단 margin
            val h = (topPadPx + barThicknessPx + bottomMarginPx + dp(12f)).toInt()
            setMeasuredDimension(w, h)
        }

        fun update(dtMs: Float) {
            // wormPhase 진행 (다중 sin 합성에 곱해질 시간 인자라 큰 주기로 reset)
            val absP = abs(slideProgress)
            val baseSpeed = 0.0028f // rad/ms
            wormPhase += baseSpeed * (1f - absP * 0.5f) * dtMs
            val largePeriod = (Math.PI * 1000).toFloat()
            if (wormPhase > largePeriod) wormPhase -= largePeriod

            invalidate()
        }

        override fun onDraw(canvas: Canvas) {
            val centerX = width / 2f
            val centerY = height - bottomMarginPx

            val absP = abs(slideProgress)
            val originalLeft = centerX - barWidthPx / 2f
            val originalRight = centerX + barWidthPx / 2f

            // ─── 막대 retreat: slideProgress 반대 방향 끝이 손가락 쪽으로 끌려옴(거의 끝까지 압축). 두께는 유지 ───
            val maxRetreatPx = dp(58f)   // barWidthPx(dp64) 대비 거의 끝까지
            val retreatAmount = absP * maxRetreatPx
            val barLeft: Float
            val barRight: Float
            if (slideProgress > 0f) {
                barLeft = originalLeft + retreatAmount
                barRight = originalRight
            } else {
                barLeft = originalLeft
                barRight = originalRight - retreatAmount
            }
            val barLength = barRight - barLeft

            // ─── 막대 본체: closed path (위/아래 곡선 + 양 끝 cap) — fill paint ───
            val effectiveAmp = waveAmpPx * (1f - absP * 0.30f)
            val baseHalfT = barThicknessPx / 2f
            val segments = 36
            val timeA = 1.00f; val cyclesA = 1.5f; val phaseA = 0.0f; val wA = 0.40f
            val timeB = 0.65f; val cyclesB = 0.9f; val phaseB = 1.3f; val wB = 0.25f
            val timeC = 1.45f; val cyclesC = 2.7f; val phaseC = 2.7f; val wC = 0.15f
            val timeD = 0.42f; val cyclesD = 0.5f; val phaseD = 4.1f; val wD = 0.12f
            val timeE = 1.85f; val cyclesE = 3.6f; val phaseE = 5.3f; val wE = 0.08f

            fun waveAt(frac: Float): Float {
                val thetaA = (wormPhase * timeA + frac * (Math.PI * 2 * cyclesA).toFloat() + phaseA).toDouble()
                val thetaB = (wormPhase * timeB + frac * (Math.PI * 2 * cyclesB).toFloat() + phaseB).toDouble()
                val thetaC = (wormPhase * timeC + frac * (Math.PI * 2 * cyclesC).toFloat() + phaseC).toDouble()
                val thetaD = (wormPhase * timeD + frac * (Math.PI * 2 * cyclesD).toFloat() + phaseD).toDouble()
                val thetaE = (wormPhase * timeE + frac * (Math.PI * 2 * cyclesE).toFloat() + phaseE).toDouble()
                val raw = (sin(thetaA) * wA + sin(thetaB) * wB + sin(thetaC) * wC +
                           sin(thetaD) * wD + sin(thetaE) * wE).toFloat()
                val edgeFalloff = sin(frac.toDouble() * Math.PI).toFloat()
                return raw * effectiveAmp * edgeFalloff
            }

            val barPath = Path()

            // 위쪽 곡선 (좌→우) — 두께 일정
            for (i in 0..segments) {
                val frac = i / segments.toFloat()
                val x = barLeft + barLength * frac
                val cY = centerY + waveAt(frac)
                val topY = cY - baseHalfT
                if (i == 0) barPath.moveTo(x, topY) else barPath.lineTo(x, topY)
            }

            // 우측 끝 cap (반원)
            val rightCY = centerY + waveAt(1f)
            barPath.arcTo(
                barRight - baseHalfT, rightCY - baseHalfT,
                barRight + baseHalfT, rightCY + baseHalfT,
                -90f, 180f, false
            )

            // 아래쪽 곡선 (우→좌)
            for (i in segments downTo 0) {
                val frac = i / segments.toFloat()
                val x = barLeft + barLength * frac
                val cY = centerY + waveAt(frac)
                val botY = cY + baseHalfT
                barPath.lineTo(x, botY)
            }

            // 좌측 끝 cap
            val leftCY = centerY + waveAt(0f)
            barPath.arcTo(
                barLeft - baseHalfT, leftCY - baseHalfT,
                barLeft + baseHalfT, leftCY + baseHalfT,
                90f, 180f, false
            )

            barPath.close()
            // 1. glow 먼저 (blur)
            canvas.drawPath(barPath, glowPaint)
            // 2. 본체 위에
            canvas.drawPath(barPath, barPaint)
        }
    }

    private fun dismissOverlay() {
        stopBottomBarIdleAnimation()
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
