package com.henry.amki_wang

import android.app.*
import android.content.*
import android.content.pm.ServiceInfo
import android.database.sqlite.SQLiteDatabase
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.PixelFormat
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
    private var overlayView: View? = null
    private var windowManager: WindowManager? = null

    private data class CardData(
        val id: Int,
        val question: String,
        val answer: String,
        val questionImages: List<String>,
        val answerImages: List<String>,
        val finished: Boolean
    )

    private var cards: List<CardData> = emptyList()
    private var currentIndex = 0
    private var showingBack = false

    // 설정
    private var folderIds: List<Int> = emptyList()
    private var finishedFilter: Int = -1
    private var randomOrder: Boolean = true
    private var reversed: Boolean = false
    private var bgColor: Int = 0xFF1A1A2E.toInt()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "onCreate")
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "onStartCommand action=${intent?.action}")
        try {
            when (intent?.action) {
                "SHOW_OVERLAY" -> showOverlay()
                "STOP_SERVICE" -> {
                    setServiceRunning(false)
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                    return START_NOT_STICKY
                }
                else -> {
                    // START_SERVICE 또는 초기 시작
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
        }
        return START_STICKY
    }

    override fun onDestroy() {
        Log.d(TAG, "onDestroy")
        setServiceRunning(false)
        unregisterScreenReceiver()
        dismissOverlay()
        super.onDestroy()
    }

    private fun setServiceRunning(running: Boolean) {
        getSharedPreferences("lock_screen_prefs", MODE_PRIVATE)
            .edit().putBoolean("service_running", running).apply()
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
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(channel)
        }
    }

    private fun createNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, Class.forName("com.henry.amki_wang.MainActivity"))
        val pendingIntent = PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("암기왕 잠금화면")
            .setContentText("잠금화면 학습 활성화됨")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setSilent(true)
            .build()
    }

    private fun registerScreenReceiver() {
        if (screenReceiver != null) return
        screenReceiver = ScreenReceiver()
        val filter = IntentFilter(Intent.ACTION_SCREEN_OFF)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(screenReceiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(screenReceiver, filter)
        }
        Log.d(TAG, "ScreenReceiver registered")
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
        Log.d(TAG, "Settings loaded: folders=$folderIds, filter=$finishedFilter")
    }

    private fun loadCardsFromDb() {
        // Flutter sqflite stores DB in app_flutter/ (getApplicationDocumentsDirectory), not databases/
        val dbFile = java.io.File(filesDir, "app_flutter/amki_wang.db")
        if (!dbFile.exists()) {
            Log.w(TAG, "DB file not found: ${dbFile.path}")
            cards = emptyList()
            return
        }
        var db: SQLiteDatabase? = null
        try {
            db = SQLiteDatabase.openDatabase(dbFile.path, null, SQLiteDatabase.OPEN_READONLY)
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

            val cursor = db.query("cards", null, where, args, null, null, "sequence ASC")
            val result = mutableListOf<CardData>()
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
            cursor.close()
            cards = if (randomOrder) result.shuffled() else result
            Log.d(TAG, "Loaded ${cards.size} cards from DB")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load cards", e)
            cards = emptyList()
        } finally {
            db?.close()
        }
    }

    private fun showOverlay() {
        if (!Settings.canDrawOverlays(this)) {
            Log.w(TAG, "No overlay permission")
            return
        }
        if (overlayView != null) return

        loadSettings()
        loadCardsFromDb()
        if (cards.isEmpty()) {
            Log.w(TAG, "No cards to show")
            return
        }

        currentIndex = 0
        showingBack = false

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
            updateCardDisplay()
            Log.d(TAG, "Overlay shown with ${cards.size} cards")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to show overlay", e)
            overlayView = null
        }
    }

    private fun createOverlayLayout(): View {
        val density = resources.displayMetrics.density

        val root = FrameLayout(this).apply {
            setBackgroundColor(bgColor)
        }

        // 상단 바: 진행률
        val topBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding((16 * density).toInt(), (48 * density).toInt(), (16 * density).toInt(), (8 * density).toInt())
            gravity = Gravity.CENTER_VERTICAL
        }
        val progressText = TextView(this).apply {
            tag = "progressText"
            setTextColor(Color.WHITE)
            textSize = 14f
        }
        topBar.addView(progressText, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))

        // 카드 영역
        val cardContainer = FrameLayout(this).apply {
            tag = "cardContainer"
        }

        val scrollView = ScrollView(this).apply {
            tag = "cardScroll"
            setPadding((24 * density).toInt(), (24 * density).toInt(), (24 * density).toInt(), (24 * density).toInt())
        }
        val cardContent = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            tag = "cardContent"
        }
        val labelText = TextView(this).apply {
            tag = "labelText"
            setTextColor(Color.parseColor("#AAAAAA"))
            textSize = 12f
        }
        val mainText = TextView(this).apply {
            tag = "mainText"
            setTextColor(Color.WHITE)
            textSize = 22f
            setPadding(0, (16 * density).toInt(), 0, 0)
        }
        val imageContainer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            tag = "imageContainer"
            setPadding(0, (24 * density).toInt(), 0, 0)
        }
        val hintText = TextView(this).apply {
            tag = "hintText"
            setTextColor(Color.parseColor("#666666"))
            textSize = 12f
            gravity = Gravity.CENTER
            setPadding(0, (48 * density).toInt(), 0, 0)
        }
        cardContent.addView(labelText)
        cardContent.addView(mainText)
        cardContent.addView(imageContainer)
        cardContent.addView(hintText)
        scrollView.addView(cardContent)
        cardContainer.addView(scrollView, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT
        ))

        // 하단: 잠금 해제 안내
        val unlockBar = TextView(this).apply {
            tag = "unlockBar"
            text = "\u2191 위로 스와이프하여 잠금 해제"
            setTextColor(Color.parseColor("#888888"))
            textSize = 14f
            gravity = Gravity.CENTER
            setPadding(0, (16 * density).toInt(), 0, (32 * density).toInt())
        }

        root.addView(topBar, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.TOP
        ))
        root.addView(cardContainer, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT
        ).apply {
            topMargin = (80 * density).toInt()
            bottomMargin = (60 * density).toInt()
        })
        root.addView(unlockBar, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.BOTTOM
        ))

        setupGestures(root)

        return root
    }

    private fun setupGestures(view: View) {
        val gestureDetector = GestureDetector(this, object : GestureDetector.SimpleOnGestureListener() {
            private val SWIPE_THRESHOLD = 100
            private val SWIPE_VELOCITY_THRESHOLD = 100

            override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
                showingBack = !showingBack
                updateCardDisplay()
                return true
            }

            override fun onFling(e1: MotionEvent?, e2: MotionEvent, velocityX: Float, velocityY: Float): Boolean {
                if (e1 == null) return false
                val diffX = e2.x - e1.x
                val diffY = e2.y - e1.y

                if (abs(diffY) > abs(diffX) && diffY < -SWIPE_THRESHOLD && abs(velocityY) > SWIPE_VELOCITY_THRESHOLD) {
                    dismissOverlay()
                    return true
                }

                if (abs(diffX) > abs(diffY) && abs(diffX) > SWIPE_THRESHOLD && abs(velocityX) > SWIPE_VELOCITY_THRESHOLD) {
                    if (diffX < 0) {
                        if (currentIndex < cards.size - 1) {
                            currentIndex++
                            showingBack = false
                            updateCardDisplay()
                        }
                    } else {
                        if (currentIndex > 0) {
                            currentIndex--
                            showingBack = false
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
        if (cards.isEmpty()) return

        val card = cards[currentIndex]
        val isFront = !showingBack

        val text: String
        val images: List<String>
        val label: String
        if (isFront xor reversed) {
            text = card.question
            images = card.questionImages
            label = if (reversed) "정답" else "앞면"
        } else {
            text = card.answer
            images = card.answerImages
            label = if (reversed) "질문" else "뒷면"
        }

        root.findViewWithTag<TextView>("progressText")?.text =
            "${currentIndex + 1} / ${cards.size}"
        root.findViewWithTag<TextView>("labelText")?.text = label
        root.findViewWithTag<TextView>("mainText")?.text =
            if (text.isEmpty()) "(내용 없음)" else text
        root.findViewWithTag<TextView>("hintText")?.text =
            "탭하여 ${if (showingBack) "앞면" else "뒷면"} 보기"

        val imageContainer = root.findViewWithTag<LinearLayout>("imageContainer")
        imageContainer?.removeAllViews()
        if (images.isNotEmpty()) {
            val density = resources.displayMetrics.density
            for (path in images) {
                val file = java.io.File(path)
                if (!file.exists()) continue
                try {
                    val options = BitmapFactory.Options().apply {
                        inSampleSize = 2
                    }
                    val bitmap = BitmapFactory.decodeFile(path, options) ?: continue
                    val imageView = ImageView(this).apply {
                        setImageBitmap(bitmap)
                        scaleType = ImageView.ScaleType.FIT_CENTER
                        adjustViewBounds = true
                        val lp = LinearLayout.LayoutParams(
                            LinearLayout.LayoutParams.MATCH_PARENT,
                            LinearLayout.LayoutParams.WRAP_CONTENT
                        )
                        lp.bottomMargin = (12 * density).toInt()
                        layoutParams = lp
                    }
                    imageContainer?.addView(imageView)
                } catch (_: Exception) { }
            }
        }
    }

    private fun dismissOverlay() {
        overlayView?.let {
            try {
                windowManager?.removeView(it)
            } catch (_: Exception) {}
            overlayView = null
        }
    }
}
