package com.henry.memora

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.henry.memora/lockscreen"
    private val IMPORT_EXPORT_CHANNEL = "com.henry.memora/import_export"
    private val APP_LANG_CHANNEL = "com.henry.memora/app_lang"
    private val TAG = "AmkiWang"
    // 고유값 사용: record 플러그인이 1001을 RECORD_AUDIO에 하드코딩해 충돌하므로 피한다.
    private val REQUEST_CODE_WRITE_STORAGE = 20259

    private var importExportChannel: MethodChannel? = null
    // saveToDownloads가 WRITE_EXTERNAL_STORAGE 런타임 요청으로 중단된 동안 보관하는 인자.
    // onRequestPermissionsResult에서 권한 승인 시 이걸로 저장을 재개한다.
    private var pendingSaveToDownloads: Triple<String, String, MethodChannel.Result>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        flutterEngine.platformViewsController.registry
            .registerViewFactory(
                "native-edit-text",
                NativeEditTextFactory(flutterEngine.dartExecutor.binaryMessenger)
            )

        // Cold start: 알림 탭으로 앱이 시작된 경우 payload를 Flutter에 전달하기 위해 저장
        val initialPayload = intent?.getStringExtra("notification_payload")
        intent?.removeExtra("notification_payload")
        val initialNavigateTo = intent?.getStringExtra("navigate_to")
        intent?.removeExtra("navigate_to")
        // Cold start: 잠금화면에서 좌측 슬라이드로 카드 편집 진입한 경우
        val initialEditCard = if (intent?.getBooleanExtra("navigate_to_edit_card", false) == true) {
            val cId = intent.getIntExtra("card_id", -1)
            val fId = intent.getIntExtra("folder_id", -1)
            intent.removeExtra("navigate_to_edit_card")
            intent.removeExtra("card_id")
            intent.removeExtra("folder_id")
            if (cId > 0 && fId > 0) Pair(fId, cId) else null
        } else null

        // 앱 언어 미러링. Flutter(LocaleService)가 언어를 정하거나 바꿀 때마다 호출한다.
        // 네이티브 알림/채널/PDF는 시스템 언어가 아니라 이 값을 따른다.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_LANG_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setLanguage" -> {
                        // lang=null → 시스템 언어 따라가기
                        AppLang.save(this, call.argument<String>("lang"))
                        applyLanguageToRunningServices(AppLang.current(this))
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // Import/Export Foreground Service MethodChannel
        val ieChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, IMPORT_EXPORT_CHANNEL)
        importExportChannel = ieChannel
        ieChannel.setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "startService" -> {
                            val res = AppLang.wrap(this)
                            val title = call.argument<String>("title")
                                ?: res.getString(R.string.ie_processing)
                            val type = call.argument<String>("type") ?: "import"
                            // 알림을 즉시 표시 (foreground service 시작 전)
                            ImportExportService.updateProgress(
                                this, title, res.getString(R.string.ie_preparing), 0, 0, type
                            )
                            val intent = Intent(this, ImportExportService::class.java)
                            intent.putExtra("title", title)
                            intent.putExtra("type", type)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
                        }
                        "updateProgress" -> {
                            val title = call.argument<String>("title") ?: ""
                            val message = call.argument<String>("message") ?: ""
                            val progress = call.argument<Int>("progress") ?: 0
                            val max = call.argument<Int>("max") ?: 0
                            val type = call.argument<String>("type") ?: "import"
                            ImportExportService.updateProgress(this, title, message, progress, max, type)
                            result.success(true)
                        }
                        "complete" -> {
                            val title = call.argument<String>("title")
                                ?: AppLang.wrap(this).getString(R.string.ie_done)
                            val message = call.argument<String>("message") ?: ""
                            val type = call.argument<String>("type") ?: "import"
                            // Stop foreground service
                            val stopIntent = Intent(this, ImportExportService::class.java)
                            stopIntent.action = "STOP"
                            try {
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                    startForegroundService(stopIntent)
                                } else {
                                    startService(stopIntent)
                                }
                            } catch (e: Exception) {
                                Log.w(TAG, "Failed to send STOP to ImportExportService: ${e.message}")
                            }
                            // Show completion notification
                            ImportExportService.showComplete(this, title, message, type)
                            result.success(true)
                        }
                        "cancel" -> {
                            val stopIntent = Intent(this, ImportExportService::class.java)
                            stopIntent.action = "STOP"
                            try {
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                    startForegroundService(stopIntent)
                                } else {
                                    startService(stopIntent)
                                }
                            } catch (e: Exception) {
                                Log.w(TAG, "Failed to send STOP to ImportExportService: ${e.message}")
                            }
                            result.success(true)
                        }
                        "generatePdf" -> {
                            val outputPath = call.argument<String>("outputPath")
                            val folderId = call.argument<Int>("folderId")
                            if (outputPath == null || folderId == null) {
                                result.error("ERROR", "outputPath and folderId required", null)
                                return@setMethodCallHandler
                            }
                            val folderIndex = call.argument<Int>("folderIndex") ?: 0
                            val totalFolders = call.argument<Int>("totalFolders") ?: 1
                            val channel = ieChannel
                            Thread {
                                try {
                                    PdfGenerator(this).generate(
                                        outputPath = outputPath,
                                        folderId = folderId,
                                        folderIndex = folderIndex,
                                        totalFolders = totalFolders,
                                        onProgress = { current, total, message ->
                                            runOnUiThread {
                                                channel?.invokeMethod("pdfProgress", mapOf(
                                                    "current" to current,
                                                    "total" to total,
                                                    "message" to message,
                                                ))
                                            }
                                        }
                                    )
                                    runOnUiThread {
                                        try { result.success(true) }
                                        catch (e2: Exception) { Log.w(TAG, "Result already replied", e2) }
                                    }
                                } catch (e: Exception) {
                                    Log.e(TAG, "PDF generation failed", e)
                                    runOnUiThread {
                                        try { result.error("PDF_ERROR", e.message, null) }
                                        catch (e2: Exception) { Log.w(TAG, "Result already replied", e2) }
                                    }
                                }
                            }.start()
                        }
                        "moveToBackground" -> {
                            moveTaskToBack(true)
                            result.success(true)
                        }
                        "saveToDownloads" -> {
                            val sourcePath = call.argument<String>("sourcePath")
                            val fileName = call.argument<String>("fileName")
                            if (sourcePath == null || fileName == null) {
                                result.error("ERROR", "sourcePath and fileName required", null)
                                return@setMethodCallHandler
                            }
                            // Android 9 이하(API 28-)는 공개 Downloads 폴더에 직접 쓰므로
                            // WRITE_EXTERNAL_STORAGE 런타임 권한이 필요하다 (Q+는 MediaStore 경유라 불필요).
                            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
                                ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE)
                                != PackageManager.PERMISSION_GRANTED) {
                                Log.d(TAG, "WRITE_EXTERNAL_STORAGE 미승인, 런타임 요청 후 재개")
                                pendingSaveToDownloads = Triple(sourcePath, fileName, result)
                                ActivityCompat.requestPermissions(
                                    this,
                                    arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                                    REQUEST_CODE_WRITE_STORAGE
                                )
                                return@setMethodCallHandler
                            }
                            performSaveToDownloads(sourcePath, fileName, result)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "ImportExport MethodChannel error: ${call.method}", e)
                    result.error("ERROR", e.message, e.stackTraceToString())
                }
            }

        // Push Notification Interval Service MethodChannel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.henry.memora/push_notif")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "startService" -> {
                            val args = call.arguments as? Map<String, Any?> ?: emptyMap()
                            val intent = Intent(this, PushNotificationService::class.java).apply {
                                putExtra("lang", (args["lang"] as? String) ?: "ko")
                                // rulesCsv는 "인자가 있을 때만" 기록 — 없으면 서비스가 prefs의
                                // 기존 값을 그대로 쓴다(LockScreenService.saveSettings와 동일
                                // 규율). 무조건 기본값(빈 문자열)을 넣으면, 이 키를 안 싣는
                                // startService 호출 경로가 향후 생겼을 때 사용자의 규칙이
                                // 조용히 지워진다.
                                (args["rulesCsv"] as? String)?.let { putExtra("rulesCsv", it) }
                            }
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
                        }
                        "stopService" -> {
                            try {
                                val intent = Intent(this, PushNotificationService::class.java)
                                intent.action = PushNotificationService.ACTION_STOP
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                    startForegroundService(intent)
                                } else {
                                    startService(intent)
                                }
                            } catch (e: Exception) {
                                // push_notif_prefs는 :push 프로세스와 공유되는 파일이다. SharedPreferences는
                                // 프로세스별로 전체 맵을 메모리에 캐시했다가 commit() 시 통째로 다시 쓰므로,
                                // 여기서 메인 프로세스가 커밋하면 :push가 그 사이 기록한 최신 스케줄
                                // (nextFireTime 등)을 되돌려버릴 수 있다 — prefs는 건드리지 않고 로그만 남긴다.
                                Log.w(TAG, "Failed to send STOP to PushNotificationService: ${e.message}")
                            }
                            result.success(true)
                        }
                        "isRunning" -> {
                            val prefs = getSharedPreferences("push_notif_prefs", MODE_PRIVATE)
                            result.success(prefs.getBoolean("running", false))
                        }
                        "requestBatteryOptimization" -> {
                            try {
                                val pm = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
                                if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                                    @Suppress("BatteryLife")
                                    val intent = Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                                    intent.data = android.net.Uri.parse("package:$packageName")
                                    startActivity(intent)
                                    result.success(false)
                                } else {
                                    result.success(true) // 이미 제외됨
                                }
                            } catch (e: Exception) {
                                result.error("ERROR", e.message, null)
                            }
                        }
                        "canScheduleExactAlarms" -> {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                                val am = getSystemService(AlarmManager::class.java)
                                result.success(am?.canScheduleExactAlarms() ?: true)
                            } else {
                                result.success(true) // API 31 미만은 항상 허용
                            }
                        }
                        "openExactAlarmSettings" -> {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                                try {
                                    val intent = Intent(android.provider.Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
                                        .setData(android.net.Uri.parse("package:$packageName"))
                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    startActivity(intent)
                                } catch (e: Exception) {
                                    Log.w(TAG, "ACTION_REQUEST_SCHEDULE_EXACT_ALARM 열기 실패, 앱 설정으로 폴백: ${e.message}")
                                    try {
                                        val fallback = Intent(
                                            android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                            android.net.Uri.parse("package:$packageName")
                                        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                        startActivity(fallback)
                                    } catch (e2: Exception) {
                                        Log.e(TAG, "앱 설정 화면 열기도 실패: ${e2.message}")
                                    }
                                }
                            }
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "PushNotif MethodChannel error: ${call.method}", e)
                    result.error("ERROR", e.message, e.stackTraceToString())
                }
            }

        // Lock Screen MethodChannel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "startService" -> {
                            val settings = call.arguments as? Map<String, Any?> ?: emptyMap()
                            saveSettings(settings)
                            startLockScreenService()
                            result.success(true)
                        }
                        "stopService" -> {
                            stopLockScreenService()
                            result.success(true)
                        }
                        "saveSettings" -> {
                            val settings = call.arguments as? Map<String, Any?> ?: emptyMap()
                            saveSettings(settings)
                            result.success(true)
                        }
                        "isRunning" -> {
                            result.success(isServiceRunning())
                        }
                        "canDrawOverlays" -> {
                            result.success(Settings.canDrawOverlays(this))
                        }
                        "requestOverlayPermission" -> {
                            val intent = Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                android.net.Uri.parse("package:$packageName")
                            )
                            startActivity(intent)
                            result.success(true)
                        }
                        "getSettings" -> {
                            result.success(loadSettings())
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "MethodChannel error: ${call.method}", e)
                    result.error("ERROR", e.message, e.stackTraceToString())
                }
            }

        // Cold start: 알림 탭으로 앱 시작된 경우 Flutter 준비 후 payload 전달
        if (initialPayload != null) {
            val parts = initialPayload.split(":")
            if (parts.size >= 2) {
                val folderId = parts[0].toIntOrNull()
                val cardId = parts[1].toIntOrNull()
                if (folderId != null && cardId != null) {
                    Log.d(TAG, "Cold start push payload: $initialPayload")
                    // Flutter 엔진이 준비될 때까지 재시도 (저사양 기기에서 1500ms 부족 가능)
                    val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
                    val payload = mapOf("folderId" to folderId, "cardId" to cardId)
                    var retryCount = 0
                    val maxRetries = 5
                    var retryRef: Runnable? = null
                    val retryRunnable = object : Runnable {
                        override fun run() {
                            try {
                                val channel = importExportChannel
                                if (channel != null) {
                                    val self = retryRef ?: return
                                    channel.invokeMethod("navigateToPushCard", payload, object : MethodChannel.Result {
                                        override fun success(result: Any?) {
                                            Log.d(TAG, "Cold start nav succeeded")
                                        }
                                        override fun error(code: String, message: String?, details: Any?) {
                                            Log.w(TAG, "Cold start nav error: $code $message")
                                        }
                                        override fun notImplemented() {
                                            // Dart handler not registered yet → retry
                                            retryCount++
                                            if (retryCount < maxRetries) {
                                                Log.d(TAG, "Cold start nav notImplemented, retry $retryCount/$maxRetries")
                                                mainHandler.postDelayed(self, 500)
                                            } else {
                                                Log.w(TAG, "Cold start nav: gave up after $maxRetries retries")
                                            }
                                        }
                                    })
                                } else {
                                    retryCount++
                                    if (retryCount < maxRetries) {
                                        mainHandler.postDelayed(this, 500)
                                    }
                                }
                            } catch (e: Exception) {
                                Log.w(TAG, "Cold start nav failed (activity destroyed?): ${e.message}")
                            }
                        }
                    }
                    retryRef = retryRunnable
                    mainHandler.postDelayed(retryRunnable, 300)
                }
            }
        }

        // Cold start: 잠금화면 좌측 슬라이드 → 카드 편집 화면 네비게이션
        if (initialEditCard != null) {
            val (fId, cId) = initialEditCard
            Log.d(TAG, "Cold start edit card: folder=$fId card=$cId")
            val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
            val payload = mapOf("folderId" to fId, "cardId" to cId)
            var retryCount = 0
            val maxRetries = 5
            var retryRef: Runnable? = null
            val retryRunnable = object : Runnable {
                override fun run() {
                    try {
                        val channel = importExportChannel
                        if (channel != null) {
                            val self = retryRef ?: return
                            channel.invokeMethod("navigateToEditCard", payload, object : MethodChannel.Result {
                                override fun success(result: Any?) {
                                    Log.d(TAG, "Cold start edit nav succeeded")
                                }
                                override fun error(code: String, message: String?, details: Any?) {
                                    Log.w(TAG, "Cold start edit nav error: $code $message")
                                }
                                override fun notImplemented() {
                                    retryCount++
                                    if (retryCount < maxRetries) {
                                        mainHandler.postDelayed(self, 500)
                                    }
                                }
                            })
                        } else {
                            retryCount++
                            if (retryCount < maxRetries) {
                                mainHandler.postDelayed(this, 500)
                            }
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "Cold start edit nav failed: ${e.message}")
                    }
                }
            }
            retryRef = retryRunnable
            mainHandler.postDelayed(retryRunnable, 300)
        }

        // Cold start: 포그라운드 서비스 상주 알림 탭 → 설정 화면 네비게이션
        if (initialNavigateTo != null) {
            Log.d(TAG, "Cold start navigate_to: $initialNavigateTo")
            val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
            var retryCount = 0
            val maxRetries = 5
            var retryRef: Runnable? = null
            val retryRunnable = object : Runnable {
                override fun run() {
                    try {
                        val channel = importExportChannel
                        if (channel != null) {
                            val self = retryRef ?: return
                            channel.invokeMethod("navigateToSettings", initialNavigateTo, object : MethodChannel.Result {
                                override fun success(result: Any?) {
                                    Log.d(TAG, "Cold start navigateToSettings succeeded")
                                }
                                override fun error(code: String, message: String?, details: Any?) {
                                    Log.w(TAG, "Cold start navigateToSettings error: $code $message")
                                }
                                override fun notImplemented() {
                                    retryCount++
                                    if (retryCount < maxRetries) {
                                        Log.d(TAG, "Cold start navigateToSettings notImplemented, retry $retryCount/$maxRetries")
                                        mainHandler.postDelayed(self, 500)
                                    }
                                }
                            })
                        } else {
                            retryCount++
                            if (retryCount < maxRetries) {
                                mainHandler.postDelayed(this, 500)
                            }
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "Cold start navigateToSettings failed: ${e.message}")
                    }
                }
            }
            retryRef = retryRunnable
            mainHandler.postDelayed(retryRunnable, 300)
        }
    }

    /**
     * 앱 언어가 바뀌었을 때, 이미 떠 있는 상주 알림들을 새 언어로 즉시 다시 만들게 한다.
     * 저장(AppLang.save)만으로는 이미 표시 중인 알림 문구가 안 바뀌기 때문.
     *
     * 잠금화면은 메인 프로세스라 여기서 실행 여부를 정확히 알 수 있어 미리 거른다.
     * 푸시는 :push 별도 프로세스여서 이 프로세스의 prefs 캐시가 뒤처져 있을 수 있으므로,
     * 판단을 서비스 쪽에 맡긴다 — 꺼져 있으면 서비스가 스스로 즉시 종료한다.
     */
    private fun applyLanguageToRunningServices(code: String) {
        try {
            // 서비스가 안 돌고 있어도 채널 이름은 남아 있으므로 여기서 갱신해 둔다.
            ImportExportService.refreshChannelLanguage(this)
            LockScreenService.refreshChannelLanguage(this)
        } catch (e: Exception) {
            Log.w(TAG, "알림 채널 언어 갱신 실패: ${e.message}")
        }

        try {
            val lockRunning = getSharedPreferences("lock_screen_prefs", MODE_PRIVATE)
                .getBoolean("service_running", false)
            if (lockRunning) {
                startService(Intent(this, LockScreenService::class.java).apply {
                    action = AppLang.ACTION_SET_LANG
                    putExtra(AppLang.EXTRA_LANG, code)
                })
            }
        } catch (e: Exception) {
            Log.w(TAG, "잠금화면 서비스 언어 통지 실패: ${e.message}")
        }

        try {
            startService(Intent(this, PushNotificationService::class.java).apply {
                action = AppLang.ACTION_SET_LANG
                putExtra(AppLang.EXTRA_LANG, code)
            })
        } catch (e: Exception) {
            Log.w(TAG, "푸시 서비스 언어 통지 실패: ${e.message}")
        }
    }

    private fun saveSettings(settings: Map<String, Any?>) {
        val prefs = getSharedPreferences("lock_screen_prefs", MODE_PRIVATE)
        val editor = prefs.edit()
        editor.putBoolean("enabled", settings["enabled"] as? Boolean ?: false)

        // folderIds: Dart List<int> → Kotlin List<*> (Integer or Long)
        val folderIds = settings["folderIds"]
        val folderIdsStr = when (folderIds) {
            is List<*> -> folderIds.filterNotNull().joinToString(",") { it.toString() }
            else -> ""
        }
        editor.putString("folder_ids", folderIdsStr)

        editor.putInt("finished_filter",
            (settings["finishedFilter"] as? Number)?.toInt() ?: -1)
        editor.putString("sort_order",
            (settings["sortOrder"] as? String) ?: "sequence")
        editor.putBoolean("reversed",
            settings["reversed"] as? Boolean ?: false)
        editor.putInt("bg_color",
            (settings["bgColor"] as? Number)?.toInt() ?: 0xFF1A1A2E.toInt())

        // 신규 키는 "인자가 있을 때만 기록" — 없으면 기존 값 보존.
        // 기존 6개 키의 무조건 기록은 그대로 둔다(회귀 위험 0).
        // 이유: main.dart의 _restoreLockScreenService()가 앱 실행마다 startService를 태우는데,
        // 거기서 스케줄을 안 실으면 사용자 설정이 매 실행마다 조용히 지워진다.
        // as? 안전 캐스트가 "키 없음 / 값이 null / 타입 틀림" 셋을 전부 '보존'으로 접는다.
        (settings["scheduleEnabled"] as? Boolean)?.let { editor.putBoolean("schedule_enabled", it) }
        (settings["scheduleCsv"] as? String)?.let { editor.putString("folder_schedule", it) }

        // 서비스 kill 전 데이터 보존 보장 — apply() 대신 commit()
        // (LockScreenService.setServiceRunning():236, PushNotificationService와 동일 이유).
        // 사용자 액션이 이미 MethodChannel 왕복을 기다리는 중이라 커밋 비용은 무관하다.
        editor.commit()

        Log.d(TAG, "Settings saved: enabled=${settings["enabled"]}, folders=$folderIdsStr, sort=${settings["sortOrder"]}")
    }

    private fun loadSettings(): Map<String, Any?> {
        val prefs = getSharedPreferences("lock_screen_prefs", MODE_PRIVATE)
        // 구버전(random_order bool)에서 업그레이드: sort_order가 없으면 derive
        val sortOrder = prefs.getString("sort_order", null) ?: run {
            if (prefs.contains("random_order")) {
                if (prefs.getBoolean("random_order", false)) "random" else "sequence"
            } else {
                "sequence"
            }
        }
        return mapOf(
            "enabled" to prefs.getBoolean("enabled", false),
            "folderIds" to (prefs.getString("folder_ids", "")
                ?.split(",")
                ?.filter { it.isNotEmpty() }
                ?.mapNotNull { it.toIntOrNull() } ?: emptyList<Int>()),
            "finishedFilter" to prefs.getInt("finished_filter", -1),
            "sortOrder" to sortOrder,
            "reversed" to prefs.getBoolean("reversed", false),
            "bgColor" to prefs.getInt("bg_color", 0xFF1A1A2E.toInt()),
            "scheduleEnabled" to prefs.getBoolean("schedule_enabled", false),
            "scheduleCsv" to (prefs.getString("folder_schedule", "") ?: "")
        )
    }

    private fun startLockScreenService() {
        try {
            val intent = Intent(this, LockScreenService::class.java)
            intent.action = "START_SERVICE"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            Log.d(TAG, "startLockScreenService called")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start service", e)
        }
    }

    private fun stopLockScreenService() {
        try {
            val intent = Intent(this, LockScreenService::class.java)
            stopService(intent)
            Log.d(TAG, "stopLockScreenService called")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to stop service", e)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleImportNavigationIntent(intent)
        handleSettingsNavigationIntent(intent)
        handlePushNotificationIntent(intent)
        handleEditCardNavigationIntent(intent)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_CODE_WRITE_STORAGE) {
            val pending = pendingSaveToDownloads
            pendingSaveToDownloads = null
            if (pending == null) return
            val (sourcePath, fileName, result) = pending
            if (grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED &&
                permissions.getOrNull(0) == "android.permission.WRITE_EXTERNAL_STORAGE") {
                Log.d(TAG, "WRITE_EXTERNAL_STORAGE 승인됨, saveToDownloads 재개")
                performSaveToDownloads(sourcePath, fileName, result)
            } else {
                Log.w(TAG, "WRITE_EXTERNAL_STORAGE 거부됨, saveToDownloads 취소")
                result.error("PERMISSION_DENIED", "WRITE_EXTERNAL_STORAGE permission denied", null)
            }
        }
    }

    private fun handleEditCardNavigationIntent(intent: Intent) {
        if (!intent.getBooleanExtra("navigate_to_edit_card", false)) return
        intent.removeExtra("navigate_to_edit_card")
        val cardId = intent.getIntExtra("card_id", -1)
        val folderId = intent.getIntExtra("folder_id", -1)
        intent.removeExtra("card_id")
        intent.removeExtra("folder_id")
        if (cardId <= 0 || folderId <= 0) return
        Log.d(TAG, "Edit card navigation: folder=$folderId card=$cardId")
        importExportChannel?.invokeMethod("navigateToEditCard", mapOf(
            "folderId" to folderId,
            "cardId" to cardId
        ))
    }

    private fun handleSettingsNavigationIntent(intent: Intent) {
        val target = intent.getStringExtra("navigate_to") ?: return
        intent.removeExtra("navigate_to")
        Log.d(TAG, "Settings navigation: $target")
        importExportChannel?.invokeMethod("navigateToSettings", target)
    }

    private fun handleImportNavigationIntent(intent: Intent) {
        if (intent.getBooleanExtra("navigate_to_import", false)) {
            intent.removeExtra("navigate_to_import")
            importExportChannel?.invokeMethod("navigateToImport", null)
        }
        if (intent.getBooleanExtra("navigate_to_export", false)) {
            intent.removeExtra("navigate_to_export")
            importExportChannel?.invokeMethod("navigateToExport", null)
        }
    }

    private fun handlePushNotificationIntent(intent: Intent) {
        val payload = intent.getStringExtra("notification_payload") ?: return
        intent.removeExtra("notification_payload")
        Log.d(TAG, "Push notification payload: $payload")
        // payload = "folderId:cardId" → Flutter의 onNavigate 콜백으로 전달
        val parts = payload.split(":")
        if (parts.size >= 2) {
            val folderId = parts[0].toIntOrNull() ?: return
            val cardId = parts[1].toIntOrNull() ?: return
            importExportChannel?.invokeMethod("navigateToPushCard", mapOf(
                "folderId" to folderId,
                "cardId" to cardId
            ))
        }
    }

    /**
     * sourcePath 파일을 공개 Downloads 폴더에 저장. 호출 전 (pre-Q 경로의 경우)
     * WRITE_EXTERNAL_STORAGE 권한 확인/요청이 끝난 상태여야 한다 — saveToDownloads
     * 핸들러와 onRequestPermissionsResult 승인 콜백 양쪽에서 호출된다.
     */
    private fun performSaveToDownloads(sourcePath: String, fileName: String, result: MethodChannel.Result) {
        // 백그라운드 스레드에서 파일 I/O 수행 (ANR 방지)
        Thread {
            try {
                val sourceFile = File(sourcePath)
                if (!sourceFile.exists()) {
                    runOnUiThread { result.error("ERROR", "Source file not found", null) }
                    return@Thread
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    // 확장자로 MIME 추정 (.mra 등 미등록 확장자는 기존과 동일하게 octet-stream)
                    val extension = fileName.substringAfterLast('.', "").lowercase()
                    val mimeType = MimeTypeMap.getSingleton()
                        .getMimeTypeFromExtension(extension) ?: "application/octet-stream"
                    val values = ContentValues().apply {
                        put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                        put(MediaStore.Downloads.MIME_TYPE, mimeType)
                        put(MediaStore.Downloads.IS_PENDING, 1)
                    }
                    val uri = contentResolver.insert(
                        MediaStore.Downloads.EXTERNAL_CONTENT_URI, values
                    )
                    if (uri != null) {
                        try {
                            val outputStream = contentResolver.openOutputStream(uri)
                            if (outputStream != null) {
                                outputStream.use { output ->
                                    sourceFile.inputStream().use { input ->
                                        input.copyTo(output)
                                    }
                                }
                                values.clear()
                                values.put(MediaStore.Downloads.IS_PENDING, 0)
                                contentResolver.update(uri, values, null, null)
                                runOnUiThread { result.success(true) }
                            } else {
                                contentResolver.delete(uri, null, null)
                                runOnUiThread { result.error("ERROR", "Failed to open output stream", null) }
                            }
                        } catch (e: Exception) {
                            contentResolver.delete(uri, null, null)
                            runOnUiThread { result.error("ERROR", e.message, e.stackTraceToString()) }
                        }
                    } else {
                        runOnUiThread { result.error("ERROR", "Failed to create MediaStore entry", null) }
                    }
                } else {
                    @Suppress("DEPRECATION")
                    val downloadsDir = Environment.getExternalStoragePublicDirectory(
                        Environment.DIRECTORY_DOWNLOADS
                    )
                    val destFile = File(downloadsDir, fileName)
                    sourceFile.copyTo(destFile, overwrite = true)
                    runOnUiThread { result.success(true) }
                }
            } catch (e: Exception) {
                runOnUiThread { result.error("ERROR", e.message, e.stackTraceToString()) }
            }
        }.start()
    }

    private fun isServiceRunning(): Boolean {
        // SharedPreferences 플래그는 OS kill 시 스테일해질 수 있으므로
        // 실제 알림 존재 여부로 서비스 실행 상태 확인
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm != null) {
                val hasNotification = nm.activeNotifications.any {
                    it.id == LockScreenService.NOTIFICATION_ID
                }
                if (hasNotification) return true
                // 알림 없으면 prefs도 동기화 (OS가 서비스 kill 시 onDestroy 미호출 대비)
                val prefs = getSharedPreferences("lock_screen_prefs", MODE_PRIVATE)
                if (prefs.getBoolean("service_running", false)) {
                    prefs.edit().putBoolean("service_running", false).apply()
                }
                return false
            }
        }
        val prefs = getSharedPreferences("lock_screen_prefs", MODE_PRIVATE)
        return prefs.getBoolean("service_running", false)
    }
}
