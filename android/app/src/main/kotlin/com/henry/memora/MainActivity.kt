package com.henry.memora

import android.app.NotificationManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import android.util.Log
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.henry.memora/lockscreen"
    private val IMPORT_EXPORT_CHANNEL = "com.henry.memora/import_export"
    private val TAG = "AmkiWang"

    private var importExportChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Cold start: 알림 탭으로 앱이 시작된 경우 payload를 Flutter에 전달하기 위해 저장
        val initialPayload = intent?.getStringExtra("notification_payload")
        intent?.removeExtra("notification_payload")
        val initialNavigateTo = intent?.getStringExtra("navigate_to")
        intent?.removeExtra("navigate_to")

        // Import/Export Foreground Service MethodChannel
        val ieChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, IMPORT_EXPORT_CHANNEL)
        importExportChannel = ieChannel
        ieChannel.setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "startService" -> {
                            val title = call.argument<String>("title") ?: "처리 중..."
                            val type = call.argument<String>("type") ?: "import"
                            // 알림을 즉시 표시 (foreground service 시작 전)
                            ImportExportService.updateProgress(this, title, "준비 중...", 0, 0, type)
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
                            val title = call.argument<String>("title") ?: "완료"
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
                            // 백그라운드 스레드에서 파일 I/O 수행 (ANR 방지)
                            Thread {
                                try {
                                    val sourceFile = File(sourcePath)
                                    if (!sourceFile.exists()) {
                                        runOnUiThread { result.error("ERROR", "Source file not found", null) }
                                        return@Thread
                                    }
                                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                        val values = ContentValues().apply {
                                            put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                                            put(MediaStore.Downloads.MIME_TYPE, "application/octet-stream")
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
                                putExtra("intervalMin", (args["intervalMin"] as? Number)?.toInt() ?: 30)
                                putExtra("startTotal", (args["startTotal"] as? Number)?.toInt() ?: 540)
                                putExtra("endTotal", (args["endTotal"] as? Number)?.toInt() ?: 1320)
                                putExtra("folderId", (args["folderId"] as? Number)?.toInt() ?: -1)
                                putExtra("soundEnabled", args["soundEnabled"] as? Boolean ?: true)
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
                            } catch (_: Exception) {
                                // 서비스가 없으면 prefs만 정리 (commit으로 동기 저장)
                                getSharedPreferences("push_notif_prefs", MODE_PRIVATE)
                                    .edit().putBoolean("running", false).commit()
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
        editor.putBoolean("random_order",
            settings["randomOrder"] as? Boolean ?: true)
        editor.putBoolean("reversed",
            settings["reversed"] as? Boolean ?: false)
        editor.putInt("bg_color",
            (settings["bgColor"] as? Number)?.toInt() ?: 0xFF1A1A2E.toInt())
        editor.apply()

        Log.d(TAG, "Settings saved: enabled=${settings["enabled"]}, folders=$folderIdsStr")
    }

    private fun loadSettings(): Map<String, Any?> {
        val prefs = getSharedPreferences("lock_screen_prefs", MODE_PRIVATE)
        return mapOf(
            "enabled" to prefs.getBoolean("enabled", false),
            "folderIds" to (prefs.getString("folder_ids", "")
                ?.split(",")
                ?.filter { it.isNotEmpty() }
                ?.mapNotNull { it.toIntOrNull() } ?: emptyList<Int>()),
            "finishedFilter" to prefs.getInt("finished_filter", -1),
            "randomOrder" to prefs.getBoolean("random_order", true),
            "reversed" to prefs.getBoolean("reversed", false),
            "bgColor" to prefs.getInt("bg_color", 0xFF1A1A2E.toInt())
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
