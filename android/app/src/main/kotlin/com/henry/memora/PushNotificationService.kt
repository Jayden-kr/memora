package com.henry.memora

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.database.sqlite.SQLiteDatabase
import android.os.*
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * 푸시 알림 Foreground Service — 시간대 규칙 목록(PushSchedule) 기반.
 * - 앱을 스와이프해서 날려도 살아남음 (START_STICKY)
 * - AlarmManager.setExactAndAllowWhileIdle로 프로세스 사망에도 정확한 간격 알림
 * - SQLite 직접 접근으로 랜덤 카드 조회
 *
 * v1.3.9 재설계: 마스터 활성시간창·전역 폴더·전역 인터벌 개념이 전부 사라졌다.
 * 규칙에 안 걸리는 시각엔 알림이 안 온다(의도적 동작 변경) — [PushSchedule.activeRule]이
 * null이면 그냥 조용히 다음 규칙 시작까지 대기한다.
 */
class PushNotificationService : Service() {
    companion object {
        const val TAG = "PushNotifService"
        const val CHANNEL_ID = "push_notif_service_channel"
        const val SERVICE_NOTIF_ID = 3
        // 카드 알림 ID/requestCode 베이스. cardId를 더해 카드별로 stable한 PendingIntent를 만든다.
        // 100000 베이스로 다른 알림 ID(0,1,3,2001,2002,9001,99999)와 충돌 방지.
        const val CARD_NOTIF_BASE = 100000
        const val REVIEW_CHANNEL_ID = "review_notification_channel"
        const val ACTION_STOP = "STOP"
        const val ACTION_TICK = "TICK"
        const val REQUEST_CODE_TICK = 10000
        const val REQUEST_CODE_RESTART = 9999
        // 활성 규칙이 없을 때(gap) 다음 재평가까지 대기하는 최대 시간. minutesUntilNextStart가
        // 최대 1439를 반환할 수 있으므로, DST/시계 스큐/Doze 오차가 쌓여도 최악의 경우 1시간
        // 안에는 재평가하도록 캡을 씌운다.
        const val MAX_GAP_POLL_MIN = 60
        // 직전 카드 재출현 방지에 기억해 두는 최근 카드 ID 최대 개수. ⚠️ 이 값은 더 이상
        // "동시에 띄우는 알림 개수"와는 무관하다 — 그 역할은 DEVICE_NOTIF_LIMIT/NOTIF_HEADROOM
        // 쪽으로 분리했다(둘을 한 상수가 겸하던 게 5287dad의 원죄: "최근 카드 5개 기억"용
        // 숫자를 "알림 5개까지만 허용"에도 그대로 재사용해 과잉 제한이 걸렸었다).
        const val RECENT_CARD_LIMIT = 5

        /** 한 앱에 허용되는 동시 알림 개수의 기본 추정치(AOSP MAX_PACKAGE_NOTIFICATIONS). */
        const val DEFAULT_DEVICE_NOTIF_LIMIT = 50
        /** 상한 바로 밑을 노리되 앱의 다른 알림(상주 2 + 자동그룹 요약 + 임포트/PDF/테스트)이
         *  동시에 뜰 자리를 남긴다.
         *  ⚠️ R2 기기검증(Galaxy S23): 시스템이 자동으로 붙이는 자동그룹 요약 알림은
         *  `NotificationManager.getActiveNotifications()`에 안 잡히는데도 NMS의 패키지당
         *  상한 계산에는 들어간다 — 그래서 실측 상한이 50인데 학습된 값은 49로 한 칸 낮게
         *  나왔다(총량을 우리가 보는 것보다 1 적게 인식). 이 헤드룸이 그 한 칸을 이미
         *  흡수하고 있으니, 학습값이 기대보다 1 낮다고 "버그"로 보고 오차를 없애려
         *  건드리지 말 것 — 안전한 방향(과소평가)의 오차다. */
        const val NOTIF_HEADROOM = 5
        /** 실측 상한 저장 키(push_notif_prefs — :push 프로세스 전용). */
        const val KEY_DEVICE_NOTIF_LIMIT = "deviceNotifLimit"
        /** "notify가 무시됐다"고 판정하기 전에 최소한 이만큼은 떠 있어야 한다(비동기 게시 오탐 차단).
         *  보고된 어떤 기기 상한도 24 미만이 아니므로 20은 안전한 문턱. */
        const val DROP_DETECT_MIN_TOTAL = 20
        /** 학습이 이 밑으로 내려가지 않게 하는 바닥. 값이 아니라 **유도된 관계**다 —
         *  학습은 total >= DROP_DETECT_MIN_TOTAL일 때만 일어나므로 그 시점에 이 기기가
         *  최소 그만큼은 동시에 띄울 수 있다는 게 증명된 셈이고, 학습 후 점유량은 정확히
         *  (limit - NOTIF_HEADROOM)이다(비카드 알림 개수와 무관하게 상쇄된다).
         *  따라서 floor - NOTIF_HEADROOM < DROP_DETECT_MIN_TOTAL 이어야 안전하고,
         *  그 조건을 만족하는 가장 큰 값이 이 식이다. 오학습이 한 번 일어나도 카드가
         *  9장까지 쪼그라들지 않게 막는 게 목적이다(잘못된 학습은 되돌릴 길이 없다). */
        const val MIN_DEVICE_NOTIF_LIMIT = DROP_DETECT_MIN_TOTAL + NOTIF_HEADROOM - 1
        /** 착지 확인 재시도(게시는 비동기라 즉시 조회하면 아직 없을 수 있다).
         *  ⚠️ R1-H1: 0/200/400ms — 총 대기는 400ms다. 이 창을 넓게 잡으면(예전 4×250=1000ms)
         *  "사용자가 뜨자마자 스와이프"가 "OS가 거부"로 오판된다 — 이 사용자는 알림을 습관적으로
         *  스와이프해서 비우고, 이 패치 이후엔 트레이에 20장 이상 쌓인 상태가 정상이라 그 오판이
         *  실제로 자주 발생한다. 400ms는 사람이 헤드업을 인지→손을 움직여→스와이프하기엔
         *  빠듯하게 짧은 반면(지각+반응에 수백ms), 시스템이 받아준 notify()는 보통 수십ms
         *  안에 트레이에 반영되므로 정상 착지를 놓칠 일은 없다. */
        const val LANDING_CHECK_ATTEMPTS = 3
        const val LANDING_CHECK_INTERVAL_MS = 200L
        /** 착지 실패가 연속 이만큼 쌓여야 상한을 학습한다. 단발 실패는 게시 지연이나
         *  사용자가 막 스와이프한 것일 수 있어 그걸로 상한을 낮추면 안 된다. */
        const val LANDING_MISS_STREAK_TO_LEARN = 2
        /** 연속 착지 실패 횟수(push_notif_prefs — :push 프로세스 전용). */
        const val KEY_LANDING_MISS_STREAK = "landingMissStreak"

        // ── 아래 함수들은 Android API 의존성 0인 순수 로직이라 companion object에
        // 둬서 인스턴스 생성 없이 JVM 유닛테스트가 가능하다(PushNotificationServiceTest.kt).

        /**
         * SharedPreferences의 recentCardIds CSV("id,id,...", 최근이 맨 앞)를 정수 목록으로
         * 파싱. 어떤 입력에도 throw하지 않는다 — 빈 문자열/null/깨진 토큰은 조용히 무시하고,
         * 최대 [RECENT_CARD_LIMIT]개까지만 취한다.
         */
        /**
         * 이미 만들어져 있는 푸시 채널 2개(상주 서비스·복습 알림)의 이름/설명만 현재 앱 언어로
         * 다시 만든다. **메인 프로세스에서 호출한다** — 채널은 시스템이 앱 단위로 갖고 있어
         * 프로세스와 무관하고, 예전처럼 SET_LANG 인텐트로 `:push`를 깨워 갱신하면 푸시를 쓰지도
         * 않는 사용자의 프로세스가 실행마다 새로 뜬다(감사 D10-07 / 리뷰 N-03).
         * 없는 채널은 만들지 않는다 — 안 쓰던 사용자에게 채널이 생기면 안 된다.
         */
        fun refreshChannelLanguage(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val appContext = context.applicationContext
            val nm = appContext.getSystemService(NotificationManager::class.java) ?: return
            val res = AppLang.wrap(appContext)
            if (nm.getNotificationChannel(CHANNEL_ID) != null) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        res.getString(R.string.push_service_channel_name),
                        NotificationManager.IMPORTANCE_MIN
                    ).apply {
                        description = res.getString(R.string.push_service_channel_desc)
                        setShowBadge(false)
                    }
                )
            }
            if (nm.getNotificationChannel(REVIEW_CHANNEL_ID) != null) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        REVIEW_CHANNEL_ID,
                        res.getString(R.string.push_review_channel_name),
                        NotificationManager.IMPORTANCE_HIGH
                    ).apply {
                        description = res.getString(R.string.push_review_channel_desc)
                        enableVibration(true)
                    }
                )
            }
        }

        internal fun parseRecentIds(csv: String?): List<Int> {
            if (csv.isNullOrEmpty()) return emptyList()
            return csv.split(",").mapNotNull { it.trim().toIntOrNull() }.take(RECENT_CARD_LIMIT)
        }

        /** [parseRecentIds]의 역변환. */
        internal fun encodeRecentIds(ids: List<Int>): String = ids.joinToString(",")

        /**
         * 직전 카드 제외 조건을 걸어도 안전한지 판정. [recentSize]개를 전부 제외해도
         * 최소 1건은 남아야 하므로, 안전 조건은 (카드 총 개수 [totalCount]) > (최근 카드
         * 개수 [recentSize]) — 즉 totalCount가 recentSize+1 이상이면 충분하다(그 경우
         * worst-case로도 1건이 남는다). totalCount가 recentSize와 같거나 더 작으면
         * 제외 조건을 걸 경우 0건이 나와 알림이 조용히 끊길 수 있으므로 false(제외
         * 조건 없이 조회)를 반환한다.
         *
         * ⚠️ 1라운드 감사(2026-09-04)에서 발견: 예전엔 `totalCount > recentSize + 1`로
         * 한 단계 더 보수적이었다 — 카드가 정확히 recentSize+1개일 때(예: 최근 5개
         * 기억+카드 6개) 제외해도 1건이 남는데도 가드가 막아, 하필 이 재출현 방지
         * 기능이 막으려던 그 상황(직전 카드가 바로 또 뜸)이 이 경계값에서만 빠져나갔다.
         */
        internal fun shouldExcludeRecentCards(totalCount: Int, recentSize: Int): Boolean =
            recentSize > 0 && totalCount > recentSize

        /**
         * 새 카드 알림 하나를 띄우기 전에, 지워야 할 카드 알림을 **오래된 순으로** 고른다.
         *
         * 5287dad의 원죄를 되풀이하지 않기 위한 설계: "몇 개까지 허용할지"([deviceLimit] -
         * [headroom] - 다른 알림 개수)와 "뭘 지울지"(카드 알림 중 postTime이 가장 오래된
         * 것부터)를 이 함수 하나에만 모아 두고, 호출부는 그 결과를 그대로 cancel하기만
         * 한다 — 판단 로직이 두 곳에 흩어지면 한쪽만 고치는 회귀가 재발하기 쉽다.
         *
         * @param active      이 앱이 지금 띄워둔 모든 알림 (id, postTime) — 카드가 아닌 것도 포함해서 받는다
         * @param incomingId  이제 띄울 카드 알림 ID
         * @param deviceLimit 이 기기가 한 앱에 허용하는 동시 알림 개수
         * @param headroom    상한 밑에 남겨둘 여유
         * @return 취소할 알림 ID들. 카드 알림(id >= CARD_NOTIF_BASE)만, incomingId는 절대 포함하지 않는다.
         */
        internal fun cardNotifsToEvict(
            active: List<Pair<Int, Long>>,
            incomingId: Int,
            deviceLimit: Int,
            headroom: Int,
        ): List<Int> {
            val cards = active.filter { it.first >= CARD_NOTIF_BASE }
            val otherCount = active.size - cards.size
            val budget = maxOf(deviceLimit - headroom - otherCount, 1)
            val isReplacement = cards.any { it.first == incomingId }   // 같은 ID면 교체라 총량이 안 는다
            val excess = cards.size + (if (isReplacement) 0 else 1) - budget
            if (excess <= 0) return emptyList()
            return cards.asSequence()
                .filter { it.first != incomingId }
                .sortedWith(compareBy({ it.second }, { it.first }))     // postTime 오름차순, 동률은 id로 결정적
                .take(excess)
                .map { it.first }
                .toList()
        }

        /**
         * 실측된 총량을 이 기기의 상한으로 삼되 바닥을 지킨다. 이 함수가 존재하는 이유는
         * "실측=진리"를 무조건 믿지 않기 위해서다 — [confirmLandedOrRecalibrate]가 부르는
         * 시점의 [observedTotal]이 우연히 아주 작아도(예: 사용자가 알림을 대량으로 막
         * 스와이프한 직후) 그걸로 상한을 영구히 낮춰버리면 카드 알림이 다시는 몇 장 이상
         * 못 쌓이는 예전 버그가 다른 값으로 재발한다.
         */
        internal fun clampLearnedLimit(observedTotal: Int): Int =
            maxOf(observedTotal, MIN_DEVICE_NOTIF_LIMIT)

        /**
         * 착지 실패 한 번을 관측했을 때, 이번이 "이 기기의 상한"이라고 결론지어도 되는가.
         *
         * 두 조건이 **둘 다** 있어야 한다 — 어느 하나만으로는 오판이 나온다:
         * - [total] < [DROP_DETECT_MIN_TOTAL]이면 OS 상한과 무관한 상황(게시 지연 등)이라
         *   증거가 안 된다(스트릭이 아무리 쌓여도 아님).
         * - 문턱을 넘겼어도 [missStreakAfterThisMiss]가 [LANDING_MISS_STREAK_TO_LEARN]에
         *   도달하기 전이면 아직 "단발성(지연/스와이프)"일 가능성을 배제 못 한다. 진짜 OS
         *   상한은 매 발화마다 결정적으로 실패하므로 다음 tick에서 바로 스트릭을 채운다 —
         *   단발 지연이나 순간 스와이프는 그렇게 반복되지 않는다.
         */
        internal fun shouldRecalibrate(missStreakAfterThisMiss: Int, total: Int): Boolean =
            total >= DROP_DETECT_MIN_TOTAL && missStreakAfterThisMiss >= LANDING_MISS_STREAK_TO_LEARN
    }

    private var lang = "ko"
    private var rules: List<PushSchedule.Rule> = emptyList()
    // 감사 D6-07: 이 인스턴스가 지금까지 한 번이라도 startForeground()에 성공했는지.
    // ACTION_SET_LANG이 이 값이 false인 채로 들어오면 죽어있던 :push를 막 콜드스타트로
    // 깨운 것 — LockScreenService의 SET_LANG 자가치유가 screenReceiver==null로 같은
    // 상황을 판정하는 것과 동일한 역할.
    private var foregroundStarted = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        // createNotificationChannel()이 intent 파싱(onStartCommand)보다 먼저 실행되므로,
        // lang 필드가 기본값(ko)인 채로 채널이 생성되지 않도록 마지막 저장값을 미리 로드한다.
        // main-branch/TICK에서 실제 intent 값으로 다시 갱신됨.
        lang = AppLang.normalize(
            getSharedPreferences("push_notif_prefs", MODE_PRIVATE).getString("lang", null)
        )
        createNotificationChannel()
        Log.d(TAG, "onCreate")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "RECREATE_NOTIFICATION") {
            Log.d(TAG, "상주 알림 재생성")
            // 감사 D6-08: 이 인텐트는 알림의 deleteIntent(getForegroundService)로 오므로
            // 다른 분기(TICK/STOP/메인)와 마찬가지로 항상 startForegroundService 계약을
            // 진다 — startForeground를 try/catch 없이 불렀다가 Android 12+에서
            // ForegroundServiceStartNotAllowedException이 나면(상주 알림을 스와이프만
            // 해도 재현 가능) :push 프로세스가 그대로 죽었다. 다른 분기와 같은 방어를 넣는다.
            val notification = createServiceNotification()
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    startForeground(SERVICE_NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
                } else {
                    startForeground(SERVICE_NOTIF_ID, notification)
                }
                foregroundStarted = true
            } catch (e: Exception) {
                Log.e(TAG, "RECREATE_NOTIFICATION startForeground 실패", e)
                // TICK과 동일 이유: startForegroundService로 시작됐는데 startForeground를
                // 못 했으니 5초 안에 스스로 멈춰야 ForegroundServiceDidNotStartInTime으로
                // 또 한 번 크래시하지 않는다. 이 분기는 알람 체인을 건드리지 않으므로
                // TICK과 달리 복구 알람 예약은 불필요.
                stopSelf()
                return START_NOT_STICKY
            }
            // 알림이 꺼진 상태인데 이 인텐트가 왔다면(비정상 종료로 남아 있던 상주 알림을
            // 사용자가 스와이프한 경우) 서비스를 되살릴 이유가 없다 — 알람 체인도 없어서
            // 아무도 멈춰 주지 않는 좀비 포그라운드 서비스가 된다. 여기서 스스로 정리한다.
            if (!getSharedPreferences("push_notif_prefs", MODE_PRIVATE)
                    .getBoolean("running", false)
            ) {
                Log.d(TAG, "RECREATE_NOTIFICATION: 이미 꺼진 상태 — 정리하고 종료")
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
                stopSelf()
                return START_NOT_STICKY
            }
            return START_STICKY
        }

        if (intent?.action == AppLang.ACTION_SET_LANG) {
            // 앱 언어 변경 통지. push_notif_prefs는 :push 프로세스만 쓰기 때문에(메인이 쓰면
            // :push가 기록한 스케줄을 되돌릴 위험) 메인이 직접 쓰지 않고 여기로 넘겨준다.
            val running = getSharedPreferences("push_notif_prefs", MODE_PRIVATE)
                .getBoolean("running", false)
            // 메인이 넘긴 코드가 null이면 "시스템 언어 따라가기". 해석된 코드를 박아두면
            // 나중에 폰 언어를 바꿔도 :push만 옛 언어에 남는다 — 키를 지워서 읽을 때마다
            // 시스템을 다시 보게 한다(AppLang.save와 같은 규약).
            val requested = intent.getStringExtra(AppLang.EXTRA_LANG)
            lang = AppLang.normalize(requested)
            getSharedPreferences("push_notif_prefs", MODE_PRIVATE).edit().apply {
                if (requested.isNullOrEmpty()) remove("lang") else putString("lang", lang)
            }.commit()
            // 채널 이름은 서비스가 꺼져 있어도 시스템 설정에 남으므로 먼저 갱신한다.
            // (이미 있는 채널만 — 안 쓰던 사용자에게 채널을 새로 만들지 않는다)
            val nm = getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                nm?.getNotificationChannel(CHANNEL_ID) != null
            ) {
                createNotificationChannel()
            }
            ensureReviewChannel(nm, force = true)
            if (!running) {
                // 알림이 꺼져 있는데 이 인텐트로 프로세스가 깨어난 경우 — 저장만 하고 종료.
                stopSelf()
                return START_NOT_STICKY
            }
            // 프로세스가 새로 떴을 수 있으므로 시간/간격을 복원한다.
            loadSettingsFromPrefs()
            // 감사 D6-07: foregroundStarted==false면 이 인텐트가 죽어있던 :push를
            // 콜드스타트로 깨웠다는 뜻(이 인스턴스가 TICK/메인 경로로 startForeground를
            // 한 번도 못 밟음). 이 상태에서 nm.notify()만 하면 상주 알림은 보이는데
            // 실제로는 foreground 서비스가 아니라서 곧 시스템이 프로세스를 죽인다(최대
            // 한 주기 알림 유실 + 알림 3이 낡은 채로 남을 수 있음). LockScreenService의
            // SET_LANG 자가치유(screenReceiver==null → startNormally())와 같은 원리로,
            // 언어 적용 전에 정식 시작 경로(foreground 승격 + running 플래그 + 알람
            // 체인 확인)부터 밟는다.
            if (!foregroundStarted) {
                createNotificationChannel()
                val notification = createServiceNotification()
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                        startForeground(SERVICE_NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
                    } else {
                        startForeground(SERVICE_NOTIF_ID, notification)
                    }
                    foregroundStarted = true
                } catch (e: Exception) {
                    Log.e(TAG, "SET_LANG 콜드스타트 startForeground 실패", e)
                }
                saveRunning(true)
                // 알람 체인 확인: 프로세스만 재생성됐다면 AlarmManager 예약은 프로세스
                // 사망과 무관하게 이미 살아있어 아래는 사실상 재확인일 뿐이다. 하지만 기기
                // 재부팅처럼 예약 자체가 사라진 경우엔 이 재확인이 없으면 다음 TICK이
                // 영영 오지 않는다. 메인 분기의 "남은 시간이 정상 범위면 유지, 아니면
                // 전체 간격으로 리셋" 로직을 그대로 재사용한다 — computeNextFireTime()은
                // "직전 발화 다음" 계산이라 여기서 쓰면 한 주기를 통째로 건너뛰므로 쓰지 않는다.
                val nowMin = nowMinutes()
                val activeRule = PushSchedule.activeRule(nowMin, rules)
                val delayMs: Long = delayMsForNow(nowMin, activeRule)
                val pushPrefsForAlarm = getSharedPreferences("push_notif_prefs", MODE_PRIVATE)
                val remaining = pushPrefsForAlarm.getLong("nextFireTime", 0L) - System.currentTimeMillis()
                if (remaining in 1L..delayMs) {
                    scheduleNextAlarm(remaining)
                } else {
                    saveNextFireTime(System.currentTimeMillis() + delayMs)
                    scheduleNextAlarm(delayMs)
                }
            } else {
                nm?.notify(SERVICE_NOTIF_ID, createServiceNotification())
            }
            return START_STICKY
        }

        if (intent?.action == ACTION_STOP) {
            Log.d(TAG, "STOP 수신 — 서비스 종료")
            // stopService는 startForegroundService(ACTION_STOP)로 호출되므로, 서비스가
            // 미실행 상태였다면 여기서 콜드스타트된다. 그 경우 startForeground를 먼저 호출하지
            // 않으면 ForegroundServiceDidNotStartInTimeException으로 크래시한다(TICK 분기와 동일
            // 이유). 아래에서 곧바로 stopForeground로 제거하므로 알림은 사용자에게 보이지 않는다.
            createNotificationChannel()
            try {
                val notification = createServiceNotification()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    startForeground(SERVICE_NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
                } else {
                    startForeground(SERVICE_NOTIF_ID, notification)
                }
            } catch (e: Exception) {
                Log.e(TAG, "STOP startForeground 실패", e)
            }
            // AlarmManager PendingIntent 취소 (tick + restart)
            cancelTickAlarm()
            cancelRestartAlarm()
            // nextFireTime 정리 (OFF→ON 시 새 타이머 시작을 위해)
            getSharedPreferences("push_notif_prefs", MODE_PRIVATE)
                .edit().remove("nextFireTime").remove("timingKey").commit()
            saveRunning(false)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            stopSelf()
            return START_NOT_STICKY
        }

        if (intent?.action == ACTION_TICK) {
            Log.d(TAG, "TICK 수신 — 알림 체크")
            // 설정 복원 (프로세스가 재생성됐을 수 있으므로)
            loadSettingsFromPrefs()

            // startForeground 필수: getForegroundService PendingIntent로 시작되므로
            // 프로세스 재생성(cold start) 시 startForeground 미호출 → ForegroundServiceDidNotStartInTimeException 방지
            createNotificationChannel()
            val notification = createServiceNotification()
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    startForeground(SERVICE_NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
                } else {
                    startForeground(SERVICE_NOTIF_ID, notification)
                }
                foregroundStarted = true
            } catch (e: Exception) {
                Log.e(TAG, "TICK startForeground 실패", e)
                // 체인 유지: 여기서 그냥 물러나면 다음 알람이 영영 예약되지 않아 앱을 다시
                // 열기 전까지 푸시가 죽는다(다음 예약 코드는 이 아래에 있어 도달 불가였다).
                // 실패가 일시적(배경 시작 제한 등)일 수 있으니 다음 발화만이라도 예약해 두고
                // 물러난다. 이미 STOP된 상태(tombstone)면 예약하지 않는다.
                try {
                    val p = getSharedPreferences("push_notif_prefs", MODE_PRIVATE)
                    if (p.getBoolean("running", false) && p.contains("nextFireTime")) {
                        val now = nowMinutes()
                        val next = computeNextFireTime(p, now, PushSchedule.activeRule(now, rules))
                        saveNextFireTime(next)
                        scheduleNextAlarm(next - System.currentTimeMillis())
                    }
                } catch (t: Exception) {
                    Log.e(TAG, "복구 알람 예약 실패", t)
                }
                // startForegroundService로 시작됐는데 startForeground를 못 했으니 5초 안에
                // 스스로 멈춰야 ForegroundServiceDidNotStartInTime 크래시가 안 난다.
                stopSelf()
                return START_NOT_STICKY
            }

            val prefs = getSharedPreferences("push_notif_prefs", MODE_PRIVATE)

            // STOP이 이 TICK 디스패치 직후 처리된 경쟁 상태 대비: AlarmManager.cancel()은 이미
            // 디스패치된 PendingIntent를 회수하지 못한다. STOP은 running=false로 바꾸고
            // nextFireTime을 지우므로, 둘 중 하나라도 tombstone이면 즉시 종료해야 사용자가
            // 방금 끈 알림이 되살아나지 않는다.
            if (!prefs.getBoolean("running", false) || !prefs.contains("nextFireTime")) {
                Log.d(TAG, "TICK — STOP 이후 잔여 알람 감지, 종료")
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
                stopSelf()
                return START_NOT_STICKY
            }

            saveRunning(true)

            // 현재 시각을 한 번만 계산 → 활성 규칙 판정 → 있으면 그 간격으로, 없으면(gap)
            // 다음 규칙 시작까지(최대 MAX_GAP_POLL_MIN분) 다음 알람 예약.
            val now = nowMinutes()
            val rule = PushSchedule.activeRule(now, rules)
            Log.d(TAG, "Schedule: now=%02d:%02d rules=%d matched=%s".format(
                now / 60, now % 60, rules.size,
                rule?.let { "[${it.start}-${it.end})->folder=${it.folderId},interval=${it.intervalMin}" } ?: "none(gap)"
            ))

            // 다음 알람을 먼저 예약 (프로세스가 발화 도중 죽어도 체인 유지)
            val nextFireTime = computeNextFireTime(prefs, now, rule)
            saveNextFireTime(nextFireTime)
            scheduleNextAlarm(nextFireTime - System.currentTimeMillis())

            // 예약 완료 후 발화 (프로세스 사망 시 이번 알림만 유실, 체인은 유지). 규칙이
            // 없으면(gap) 발화하지 않는다 — 이게 이 재설계의 핵심 동작 변경이다.
            if (rule != null) fire(rule)

            return START_STICKY
        }

        // 설정 읽기 (Flutter의 startService 호출, 또는 부팅 복원처럼 extras 없는 콜드스타트)
        val prefs = getSharedPreferences("push_notif_prefs", MODE_PRIVATE)
        lang = AppLang.normalize(intent?.getStringExtra("lang") ?: prefs.getString("lang", null))

        // 규칙 CSV. hasExtra 패턴 — "전달 안 함=보존" vs "명시적으로 넘김(빈 문자열 포함)"을
        // 구분한다. 프레퍼런스 키 이름은 이전 버전과 동일하게 "scheduleCsv"로 유지한다
        // (§5.3 콜드스타트 폴백이 이 키를 그대로 재사용하기 때문).
        val rulesCsvRaw = if (intent != null && intent.hasExtra("rulesCsv")) {
            intent.getStringExtra("rulesCsv") ?: ""
        } else {
            prefs.getString("scheduleCsv", "") ?: ""
        }
        val hasFreshRulesFromIntent = intent != null && intent.hasExtra("rulesCsv") &&
            !intent.getStringExtra("rulesCsv").isNullOrEmpty()

        rules = PushSchedule.parse(rulesCsvRaw)
        if (rules.isEmpty()) {
            val fallback = legacyFallbackRules(prefs)
            if (fallback.isNotEmpty()) {
                Log.w(TAG, "scheduleCsv 비어있음 — 레거시 prefs(startTotal/endTotal/intervalMin/folderId)로 규칙 폴백")
                rules = fallback
            }
        }

        // ⚠️ canonicalCsv/timingKey는 rulesCsvRaw(마이그레이션 전 상태 그대로) 기준이다 —
        // 위의 레거시 폴백으로 합성된 rules를 여기 반영하지 않는다. loadSettingsFromPrefs()가
        // 매 TICK마다 같은 레거시 prefs로 동일한 폴백을 재현하므로(레거시 키를 지우기 전까진)
        // 실제 발화·표시는 rules 필드가 이미 담당하고, canonicalCsv는 순수하게 "Flutter가
        // 실제로 보낸 값"만 반영해 Flutter가 진짜 새 CSV를 보내는 순간 timingKey가 정확히
        // 갈라지게 한다.
        val canonicalCsv = PushSchedule.encode(PushSchedule.parse(rulesCsvRaw))

        // 타이밍 설정 변경 여부 판별. "v2:" 프리픽스는 업데이트 직후 남아있는 구
        // timingKey("$intervalMin:$startTotal:..." 형식)와 절대 충돌하지 않게 하기 위함 —
        // 프리픽스가 없으면 구 timingKey와 우연히 같은 문자열이 나올 여지가 있어 강제로
        // 다르게 만든다.
        val timingKey = "v2:$canonicalCsv"
        val savedTimingKey = prefs.getString("timingKey", "") ?: ""
        val wasRunning = prefs.getBoolean("running", false)

        val editor = prefs.edit()
            .putString("scheduleCsv", canonicalCsv)
            .putString("timingKey", timingKey)
            .putString("lang", lang)
        if (hasFreshRulesFromIntent) {
            // Flutter가 실제로 비어있지 않은 규칙을 보냈다 — 이제부터는 §5.3 콜드스타트
            // 폴백이 더 이상 필요 없으므로(scheduleCsv가 항상 최신 상태) 레거시 키를 지운다.
            // 한 번 지워지면 폴백은 영구히 비활성화된다(다시 살아나 새 규칙을 덮어쓰지 않음).
            editor.remove("startTotal").remove("endTotal").remove("intervalMin").remove("folderId")
        }
        editor.commit()  // apply() 대신 commit() — 서비스 kill 전 데이터 보존 보장

        Log.d(TAG, "시작: 규칙 ${rules.size}개")

        // Foreground 알림
        val notification = createServiceNotification()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(SERVICE_NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(SERVICE_NOTIF_ID, notification)
            }
            foregroundStarted = true
        } catch (e: Exception) {
            Log.e(TAG, "startForeground 실패", e)
            return START_NOT_STICKY
        }

        saveRunning(true)

        // 기존 tick 알람 취소
        cancelTickAlarm()

        // 메인 분기도 activeRule(now, rules)을 호출해 delayMs를 계산한다 — 이전 설계의
        // "메인 분기는 슬롯을 조회하지 않는다"는 규율은 v1.3.9에서 의도적으로 뒤집혔다.
        // 규칙 하나뿐이던 전역 인터벌 개념 자체가 사라졌으므로, 지금 활성 규칙이 있는지
        // 없는지에 따라 delayMs가 달라져야 첫 알람이 올바른 시각에 잡힌다.
        val now = nowMinutes()
        val rule = PushSchedule.activeRule(now, rules)
        val delayMs: Long = delayMsForNow(now, rule)

        if (wasRunning && timingKey == savedTimingKey) {
            // 설정 동일 + 이미 실행 중이었음 → 남은 시간만 대기
            val nextFireTime = prefs.getLong("nextFireTime", 0L)
            val nowMs = System.currentTimeMillis()
            val remaining = nextFireTime - nowMs

            // remaining은 정상적으로 delayMs를 넘을 수 없다. 기기 시계를 과거로 돌리면
            // remaining이 delayMs보다 훨씬 커질 수 있는데(시계 스큐), 그대로 유지하면
            // 시계가 따라잡을 때까지 며칠씩 알림이 멈춘다 — 그런 경우도 새로 리셋한다.
            if (remaining in 1L..delayMs) {
                scheduleNextAlarm(remaining)
                Log.d(TAG, "타이머 유지: ${remaining / 60000}분 ${(remaining % 60000) / 1000}초 남음")
            } else {
                saveNextFireTime(System.currentTimeMillis() + delayMs)
                scheduleNextAlarm(delayMs)
                Log.d(TAG, "타이머 리셋 → ${delayMs / 60000}분 후 다음 알림 예약")
            }
        } else {
            // 새로 시작 or 설정 변경 → 전체 타이머
            saveNextFireTime(System.currentTimeMillis() + delayMs)
            scheduleNextAlarm(delayMs)
            Log.d(TAG, "${delayMs / 60000}분 후 첫 알림 (설정 변경)")
        }

        return START_STICKY
    }

    override fun onDestroy() {
        Log.d(TAG, "onDestroy")
        super.onDestroy()
    }

    /**
     * getForegroundService()는 API 26+ 전용 — minSdk 24 기기(Android 7.0/7.1)에서 가드 없이
     * 호출하면 NoSuchMethodError(Error, onStartCommand의 catch(Exception)에 안 잡힘)로
     * 프로세스가 죽는다. Pre-O는 getService로 충분(당시 startForeground는
     * startForegroundService 경유를 요구하지 않음). LockScreenService.kt와 동일 패턴 —
     * 이 파일은 호출 지점이 여러 곳이라 헬퍼로 통합.
     */
    private fun foregroundServicePendingIntent(context: Context, reqCode: Int, intent: Intent, flags: Int): PendingIntent {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            PendingIntent.getForegroundService(context, reqCode, intent, flags)
        } else {
            PendingIntent.getService(context, reqCode, intent, flags)
        }
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        // running 상태가 아니면 재시작 불필요
        val prefs = getSharedPreferences("push_notif_prefs", MODE_PRIVATE)
        if (!prefs.getBoolean("running", false)) {
            Log.d(TAG, "onTaskRemoved — running=false, 재시작 예약 안 함")
            return
        }
        Log.d(TAG, "onTaskRemoved — AlarmManager로 서비스 재시작 예약")
        val restartIntent = Intent(applicationContext, PushNotificationService::class.java)
        val pi = foregroundServicePendingIntent(
            applicationContext, REQUEST_CODE_RESTART, restartIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val am = getSystemService(Context.ALARM_SERVICE) as? android.app.AlarmManager
        val triggerAt = System.currentTimeMillis() + 3000
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && am != null) {
            if (am.canScheduleExactAlarms()) {
                am.setExactAndAllowWhileIdle(
                    android.app.AlarmManager.RTC_WAKEUP,
                    triggerAt,
                    pi
                )
            } else {
                am.setAndAllowWhileIdle(
                    android.app.AlarmManager.RTC_WAKEUP,
                    triggerAt,
                    pi
                )
            }
        } else {
            am?.setExactAndAllowWhileIdle(
                android.app.AlarmManager.RTC_WAKEUP,
                triggerAt,
                pi
            )
        }
    }

    /**
     * AlarmManager를 사용하여 delayMs 후 ACTION_TICK Intent를 예약
     */
    private fun scheduleNextAlarm(delayMs: Long) {
        val tickIntent = Intent(applicationContext, PushNotificationService::class.java).apply {
            action = ACTION_TICK
        }
        val pi = foregroundServicePendingIntent(
            applicationContext, REQUEST_CODE_TICK, tickIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val am = getSystemService(Context.ALARM_SERVICE) as? android.app.AlarmManager
        val triggerAt = System.currentTimeMillis() + delayMs
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && am != null) {
            if (am.canScheduleExactAlarms()) {
                am.setExactAndAllowWhileIdle(
                    android.app.AlarmManager.RTC_WAKEUP,
                    triggerAt,
                    pi
                )
            } else {
                am.setAndAllowWhileIdle(
                    android.app.AlarmManager.RTC_WAKEUP,
                    triggerAt,
                    pi
                )
            }
        } else {
            am?.setExactAndAllowWhileIdle(
                android.app.AlarmManager.RTC_WAKEUP,
                triggerAt,
                pi
            )
        }
        Log.d(TAG, "다음 알람 예약: ${delayMs / 60000}분 ${(delayMs % 60000) / 1000}초 후")
    }

    /**
     * Tick 알람 PendingIntent 취소
     */
    private fun cancelTickAlarm() {
        val tickIntent = Intent(applicationContext, PushNotificationService::class.java).apply {
            action = ACTION_TICK
        }
        val pi = foregroundServicePendingIntent(
            applicationContext, REQUEST_CODE_TICK, tickIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val am = getSystemService(Context.ALARM_SERVICE) as? android.app.AlarmManager
        am?.cancel(pi)
    }

    /**
     * Restart 알람 PendingIntent 취소
     */
    private fun cancelRestartAlarm() {
        val restartIntent = Intent(applicationContext, PushNotificationService::class.java)
        val pi = foregroundServicePendingIntent(
            applicationContext, REQUEST_CODE_RESTART, restartIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val am = getSystemService(Context.ALARM_SERVICE) as? android.app.AlarmManager
        am?.cancel(pi)
    }

    /**
     * §5.3 콜드스타트 갭 폴백: scheduleCsv가 비어 있고(아직 Flutter 마이그레이션이 돌지
     * 않은 상태) 레거시 단일 인터벌 알람 prefs(startTotal/endTotal/intervalMin/folderId
     * — v1.3.8 이전부터 있던 키)가 남아있으면 그 값으로 규칙 1개를 합성한다. 부팅
     * 리시버(LockScreenStartReceiver.restorePushNotificationService)가 extras 없이
     * 이 서비스를 띄우는 경로에서, Flutter가 아직 한 번도 열리지 않아 push_rules
     * 마이그레이션이 돌지 않았다면 이 폴백이 없으면 규칙 0개 → 영구 무음이 된다.
     */
    private fun legacyFallbackRules(prefs: SharedPreferences): List<PushSchedule.Rule> {
        if (!prefs.contains("startTotal") || !prefs.contains("endTotal")) return emptyList()
        val s = prefs.getInt("startTotal", 540)
        val e = prefs.getInt("endTotal", 1320)
        if (s == e) return emptyList()
        val folderId = prefs.getInt("folderId", -1)
        val intervalMin = maxOf(5, prefs.getInt("intervalMin", 30))
        return listOf(PushSchedule.Rule(s, e, folderId, intervalMin))
    }

    /**
     * SharedPreferences에서 설정값 복원 (TICK/ACTION_SET_LANG에서 프로세스 재생성 시 사용)
     */
    private fun loadSettingsFromPrefs() {
        val prefs = getSharedPreferences("push_notif_prefs", MODE_PRIVATE)
        // 키가 없으면 "시스템 언어 따라가기" — 예전엔 "ko"로 굳혀 영어 폰에서도 프로세스가
        // 재생성될 때마다 한국어로 돌아갔다. 다른 두 읽기 경로(SET_LANG·메인 분기)와 동일 규약.
        lang = AppLang.normalize(prefs.getString("lang", null))
        rules = PushSchedule.parse(prefs.getString("scheduleCsv", null))
        if (rules.isEmpty()) {
            val fallback = legacyFallbackRules(prefs)
            if (fallback.isNotEmpty()) rules = fallback
        }
    }

    /**
     * "지금부터 다음 알람까지" 대기할 밀리초. 직전 발화 시각을 기준으로 삼지 않는
     * 진입점(스위치 On·설정 변경·SET_LANG 콜드스타트 자가치유)이 공유한다.
     *
     * 활성 규칙이 있으면 그 규칙의 간격을 쓰되, 규칙이 바뀌는 시점보다 늦지 않게
     * 클램프한다(감사 D6-01) — 간격이 남은 창보다 길면 그 사이에 시작하는 규칙을
     * 통째로 건너뛰기 때문이다. 활성 규칙이 없으면 다음 규칙 시작까지 기다린다
     * (최대 [MAX_GAP_POLL_MIN]분마다 재평가).
     */
    private fun delayMsForNow(now: Int, rule: PushSchedule.Rule?): Long =
        if (rule != null) {
            minOf(rule.intervalMin, PushSchedule.minutesUntilRuleChange(now, rules)) * 60_000L
        } else {
            minOf(PushSchedule.minutesUntilNextStart(now, rules), MAX_GAP_POLL_MIN) * 60_000L
        }

    /**
     * TICK의 다음 발화 시각. 규칙이 있으면 예정시각(savedNextFireTime)+간격 — 실제 발화
     * 시각이 아니라 예정시각 기준이라 드리프트가 누적되지 않는다. 규칙이 없으면(gap) 다음
     * 규칙 시작까지(최대 MAX_GAP_POLL_MIN분). 정상 TICK과 startForeground 실패 경로가
     * 같은 계산을 쓰도록 분리했다.
     */
    private fun computeNextFireTime(prefs: SharedPreferences, now: Int, rule: PushSchedule.Rule?): Long {
        return if (rule != null) {
            val intervalMs = rule.intervalMin * 60_000L
            val savedFireTime = prefs.getLong("nextFireTime", System.currentTimeMillis())
            var next = savedFireTime + intervalMs
            while (next <= System.currentTimeMillis()) next += intervalMs
            // 감사 D6-01: 다음 발화가 현재 규칙의 창을 넘어가면 그 사이에 시작하는 규칙이
            // 있어도 깨어나지 않아 통째로 건너뛴다. 규칙이 바뀌는 시점보다 늦지 않게 당긴다.
            val boundary = System.currentTimeMillis() +
                PushSchedule.minutesUntilRuleChange(now, rules) * 60_000L
            minOf(next, boundary)
        } else {
            val gapMin = minOf(PushSchedule.minutesUntilNextStart(now, rules), MAX_GAP_POLL_MIN)
            System.currentTimeMillis() + gapMin * 60_000L
        }
    }

    /** 자정 기준 경과 분(0~1439). minSdk 24라 java.time 대신 Calendar 사용. */
    private fun nowMinutes(): Int {
        val cal = java.util.Calendar.getInstance()
        return cal.get(java.util.Calendar.HOUR_OF_DAY) * 60 + cal.get(java.util.Calendar.MINUTE)
    }

    /** 활성 규칙 하나를 발화. 규칙의 folderId==ALL_FOLDERS(-1)면 전체 폴더(null 필터). */
    private fun fire(rule: PushSchedule.Rule) {
        Log.d(TAG, "알림 발사! (folder=${rule.folderId}, interval=${rule.intervalMin})")
        val targetFolderId = if (rule.folderId == PushSchedule.ALL_FOLDERS) null else rule.folderId
        // DB I/O를 백그라운드 스레드에서 실행 (ANR 방지)
        Thread {
            try {
                showCardNotification(targetFolderId)
            } catch (e: Exception) {
                Log.e(TAG, "showCardNotification 실패", e)
            }
        }.start()
    }

    /** cards 테이블에서 [folderIdFilter](null이면 전체)로 필터링한 카드 총 개수. */
    private fun countCards(db: SQLiteDatabase, folderIdFilter: Int?): Int {
        val where = if (folderIdFilter != null) "folder_id = ?" else null
        val args = if (folderIdFilter != null) arrayOf(folderIdFilter.toString()) else null
        val cursor = db.query("cards", arrayOf("COUNT(*) AS cnt"), where, args, null, null, null)
        cursor.use {
            if (it.moveToFirst()) return it.getInt(it.getColumnIndexOrThrow("cnt"))
        }
        return 0
    }

    /**
     * cards 테이블에서 [folderIdFilter](null이면 전체)로 필터링한 랜덤 카드 1건을 조회.
     * [recentCardIds]에 담긴 카드는 가능하면 제외해 직전에 뜬 카드가 바로 다음에 또
     * 뜨지 않게 한다 — 단, 대상 범위의 카드 총 개수가 (recentCardIds 크기 + 1) 이하면
     * 제외 조건 없이 조회한다(그렇지 않으면 0건이 나와 알림이 조용히 끊긴다).
     * 반환: Triple(cardId, cardFolderId, question) — cardId<=0이면 조회 실패(0건).
     */
    private fun queryRandomCard(
        db: SQLiteDatabase,
        folderIdFilter: Int?,
        recentCardIds: List<Int> = emptyList()
    ): Triple<Int, Int, String> {
        val totalCount = countCards(db, folderIdFilter)
        val applyExclusion = shouldExcludeRecentCards(totalCount, recentCardIds.size)

        val whereClauses = mutableListOf<String>()
        val args = mutableListOf<String>()
        if (folderIdFilter != null) {
            whereClauses.add("folder_id = ?")
            args.add(folderIdFilter.toString())
        }
        if (applyExclusion) {
            val placeholders = recentCardIds.joinToString(",") { "?" }
            whereClauses.add("id NOT IN ($placeholders)")
            args.addAll(recentCardIds.map { it.toString() })
        }
        val where = if (whereClauses.isNotEmpty()) whereClauses.joinToString(" AND ") else null
        val whereArgs = if (args.isNotEmpty()) args.toTypedArray() else null

        val cursor = db.query("cards", arrayOf("id", "folder_id", "question"),
            where, whereArgs, null, null, "RANDOM()", "1")
        cursor.use {
            if (it.moveToFirst()) {
                val q = it.getString(it.getColumnIndexOrThrow("question"))
                val cardId = it.getInt(it.getColumnIndexOrThrow("id"))
                val cardFolderId = it.getInt(it.getColumnIndexOrThrow("folder_id"))
                return Triple(cardId, cardFolderId, if (!q.isNullOrEmpty()) q else "")
            }
        }
        return Triple(-1, -1, "")
    }

    private fun showCardNotification(targetFolderId: Int?) {
        val dbFile = findDbFile() ?: return
        var db: SQLiteDatabase? = null
        try {
            // 읽기 전용 핸들엔 enableWriteAheadLogging()이 무효 — 조회를 잠금(BUSY) 시 재시도한다(D8-05).
            db = DbReadRetry.run(TAG) {
                SQLiteDatabase.openDatabase(dbFile.path, null, SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS)
            }

            // 직전에 뜬 카드 재출현 방지용 최근 카드 ID 목록. push_notif_prefs는
            // :push 프로세스(이 서비스)만 읽고 쓴다.
            val pushPrefs = getSharedPreferences("push_notif_prefs", MODE_PRIVATE)
            // STOP 이후에도 fire()가 띄운 이 스레드는 살아 있다(tombstone은 새 TICK만 막는다).
            // 여기서 한 번, notify 직전에 한 번 더 확인해 "방금 껐는데 한 장 더"를 막는다.
            if (!pushPrefs.getBoolean("running", false)) {
                Log.d(TAG, "STOP 이후 발화 취소")
                return
            }
            val recentCardIds = parseRecentIds(pushPrefs.getString("recentCardIds", null))

            // 랜덤 카드 조회 (규칙이 지정한 폴더 우선, 직전 카드들 제외)
            var (cardId, cardFolderId, question) =
                DbReadRetry.run(TAG) { queryRandomCard(db, targetFolderId, recentCardIds) }

            // 카드 0건 폴백: 규칙이 가리키는 폴더가 삭제되었거나 카드가 비어 있으면
            // 전체 폴더로 1회 재조회 — 규칙 폴더가 무효해졌다고 알림 자체가 조용히
            // 끊기지 않게 한다. targetFolderId가 이미 null(전체 폴더)이면 재조회해도
            // 결과가 같으므로 스킵.
            if (cardId <= 0 && targetFolderId != null) {
                Log.w(TAG, "규칙 폴더($targetFolderId) 카드 없음, 전체 폴더로 재조회")
                val fallback = DbReadRetry.run(TAG) { queryRandomCard(db, null, recentCardIds) }
                cardId = fallback.first
                cardFolderId = fallback.second
                question = fallback.third
            }

            // 카드 조회 실패 시 알림 자체를 건너뜀.
            // payload 없이 알림을 띄우면 탭해도 네비게이션이 안 되므로 무의미.
            if (cardId <= 0) {
                Log.w(TAG, "랜덤 카드 조회 실패, 알림 스킵")
                return
            }
            if (question.isEmpty()) {
                question = AppLang.wrap(this, lang).getString(R.string.push_review_default_body)
            }

            // notifId = requestCode = CARD_NOTIF_BASE + cardId
            // 카드별로 stable한 PendingIntent — 같은 카드가 또 뽑혀도 자기자신만 교체하므로
            // 본문/payload가 항상 일치한다. 다른 카드끼리는 ID가 달라 PI extras 누수 불가능.
            val notifId = CARD_NOTIF_BASE + cardId
            val payload = "$cardFolderId:$cardId"

            val nm = getSystemService(NotificationManager::class.java)
            ensureReviewChannel(nm)

            // Android 13+: POST_NOTIFICATIONS 권한 확인.
            // PendingIntent 생성을 이 체크 이후로 미뤄야 권한 거부 시 기존 PI extras 누수 방지.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                if (ContextCompat.checkSelfPermission(this, android.Manifest.permission.POST_NOTIFICATIONS)
                    != PackageManager.PERMISSION_GRANTED) {
                    Log.w(TAG, "POST_NOTIFICATIONS 권한 없음, 알림 스킵")
                    return
                }
            }

            // 알림 탭 → 해당 카드로 이동하는 Intent (권한 통과 후 PI 생성)
            val launchIntent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra("notification_payload", payload)
            }
            val pi = PendingIntent.getActivity(this, notifId, launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

            val builder = NotificationCompat.Builder(this, REVIEW_CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentText(question)
                .setAutoCancel(true)
                .setContentIntent(pi)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_REMINDER)

            if (!pushPrefs.getBoolean("running", false)) {
                Log.d(TAG, "STOP 이후 발화 취소(notify 직전)")
                return
            }

            // notify() 전에 먼저 지운다 — 순서를 반대로 하면(예전 pruneCardNotifications처럼
            // notify 다음에 정리) 이미 OS 상한에 걸려 있는 경우 지금 막 하려는 이 notify() 자체가
            // 조용히 버려지는 그 알림이라, 사후 정리는 너무 늦다. 카드가 아닌 다른 알림(상주 2 +
            // 자동그룹 요약 + 임포트/PDF/테스트)도 상한을 나눠 쓰므로 스냅샷에 함께 담아 개수만
            // 반영하고 대상에서는 제외한다.
            val activeSnapshot: List<Pair<Int, Long>> = try {
                nm?.activeNotifications?.map { it.id to it.postTime } ?: emptyList()
            } catch (e: Exception) {
                Log.w(TAG, "activeNotifications 조회 실패, 정리 스킵", e)
                emptyList()
            }
            val deviceLimit = pushPrefs.getInt(KEY_DEVICE_NOTIF_LIMIT, DEFAULT_DEVICE_NOTIF_LIMIT)
            if (nm != null) {
                cardNotifsToEvict(activeSnapshot, notifId, deviceLimit, NOTIF_HEADROOM).forEach { nm.cancel(it) }
            }

            nm?.notify(notifId, builder.build())
            // 카드 본문은 로그에 남기지 않는다(릴리스 빌드에서도 Log가 제거되지 않음).
            Log.d(TAG, "알림 표시 완료: cardId=$cardId, payload=$payload")

            // 발화 성공 후 recentCardIds 갱신: 새 카드를 맨 앞에 추가, 5개 초과분은 버림.
            // 이 prefs는 :push 프로세스(이 서비스 자신)만 읽고 쓴다.
            val updatedRecent = (listOf(cardId) + recentCardIds.filter { it != cardId })
                .take(RECENT_CARD_LIMIT)
            // 감사 D6-10: apply()는 비동기라 :push 프로세스가 발화 직후 죽으면 이 쓰기가
            // 유실돼 방금 뜬 카드가 바로 다음 발화에 또 뽑힌다(재출현 방지 기능 무력화).
            // 이 코드는 fire()가 띄운 백그라운드 Thread 안에서만 실행되므로(메인 스레드
            // 아님) commit()의 동기 I/O가 ANR을 유발하지 않는다.
            pushPrefs.edit().putString("recentCardIds", encodeRecentIds(updatedRecent)).commit()

            // 착지 확인 + 자가보정. recentCardIds 커밋이 이미 끝난 뒤라, 여기서 뭐가 터지든
            // (예외든 재보정 자체의 실패든) 위에서 확정한 재출현 방지 상태는 절대 잃지 않는다.
            if (nm != null) {
                try {
                    confirmLandedOrRecalibrate(nm, notifId, builder, pushPrefs)
                } catch (e: Exception) {
                    Log.w(TAG, "착지 확인/재보정 실패", e)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "알림 표시 실패", e)
        } finally {
            db?.close()
        }
    }

    /**
     * 방금 notify()한 [notifId]가 실제로 트레이에 떴는지 확인하고, 안 떴다면 그게
     * "이 기기의 실제 상한에 걸렸다"는 신호인지 판정해 [KEY_DEVICE_NOTIF_LIMIT]을 갱신한다.
     *
     * ⚠️ 이 함수 안의 `Thread.sleep`은 여기서만 안전하다 — 이 함수는 [showCardNotification]의
     * 연장이고, showCardNotification은 항상 [fire]가 띄운 백그라운드 [Thread] 위에서만 실행된다
     * (메인 스레드에서 부르면 최대 `LANDING_CHECK_ATTEMPTS * LANDING_CHECK_INTERVAL_MS`만큼
     * ANR 위험을 그대로 진다 — 이 사실을 모르고 호출부를 옮기면 안 된다).
     */
    private fun confirmLandedOrRecalibrate(
        nm: NotificationManager,
        notifId: Int,
        builder: NotificationCompat.Builder,
        pushPrefs: SharedPreferences,
    ) {
        // 먼저 확인, 그 다음 sleep — 정상 착지(대부분의 경우)는 한 번 조회로 끝나
        // 지연 비용이 거의 0이다.
        repeat(LANDING_CHECK_ATTEMPTS) { attempt ->
            val landed = nm.activeNotifications.any { it.id == notifId }
            if (landed) {
                // R1-H1: 착지 확인됨 — 이전에 쌓인 연속 실패 스트릭은 이 발화와는 무관해졌으니
                // 리셋한다. 이미 0이면 쓰기를 건너뛴다 — 정상 착지가 압도적으로 흔한 경로라
                // 매 발화마다 불필요한 commit() I/O를 만들지 않기 위해서다.
                if (pushPrefs.getInt(KEY_LANDING_MISS_STREAK, 0) != 0) {
                    pushPrefs.edit().putInt(KEY_LANDING_MISS_STREAK, 0).commit()
                }
                return
            }
            if (attempt < LANDING_CHECK_ATTEMPTS - 1) Thread.sleep(LANDING_CHECK_INTERVAL_MS)
        }

        // 여기까지 왔으면 재시도를 다 썼는데도 안 보인다.
        val active = nm.activeNotifications
        val total = active.size
        if (total < DROP_DETECT_MIN_TOTAL) {
            // 보고된 어떤 기기 상한도 24 미만이 아니므로, 총량이 이 문턱보다 낮은데도 안
            // 보이는 건 OS 상한이 아니라 게시 지연(아직 시스템에 반영 안 됨) 또는 사용자가
            // 뜨는 순간 바로 스와이프한 것이다. 이런 경우에 학습하면 상한을 근거 없이
            // 영구히 낮춰버려 예전 버그(5개 고정)를 다른 숫자로 재현하게 된다 — 아무것도
            // 바꾸지 않고 그냥 넘어간다. 스트릭도 건드리지 않는다 — 이 분기는 상한에 대해
            // 아무 증거도 아니므로, 카운트하면 무관한 실패가 진짜 스트릭에 섞여 든다.
            Log.d(TAG, "알림 착지 확인 실패했지만 total=$total < $DROP_DETECT_MIN_TOTAL, 학습 스킵")
            return
        }

        // R1-H1: total이 문턱을 넘겼어도 이번 한 번만으로 학습하지 않는다 — 사용자가 헤드업이
        // 뜨자마자(400ms 안에) 스와이프해도 이 분기까지 도달한다. 진짜 OS 상한은 다음 발화에서도
        // 똑같이 실패하므로, 연속 실패가 [LANDING_MISS_STREAK_TO_LEARN]에 도달할 때까지 기다린다
        // (단발 지연/스와이프는 그렇게 반복되지 않는다).
        val streak = pushPrefs.getInt(KEY_LANDING_MISS_STREAK, 0) + 1
        pushPrefs.edit().putInt(KEY_LANDING_MISS_STREAK, streak).commit()

        if (!shouldRecalibrate(streak, total)) {
            Log.d(TAG, "알림 착지 실패(total=$total), 연속 $streak/$LANDING_MISS_STREAK_TO_LEARN — 학습 보류")
            return
        }

        // 스트릭이 문턱에 도달 — 이게 이 기기의 실제 OS 상한이다. 학습하고, 그 새 한도로 다시
        // 정리한 뒤 딱 한 번만 재시도한다(루프도, 2차 착지 확인도 없음 — 재시도 자체가 또
        // 상한에 걸릴 수 있는 자리라 무한히 물고 늘어지지 않는다). 스트릭은 리셋한다 — 이번
        // 학습으로 원인이 해소됐다고 보고 다음 실패부터 다시 센다.
        val learnedLimit = clampLearnedLimit(total)
        pushPrefs.edit()
            .putInt(KEY_DEVICE_NOTIF_LIMIT, learnedLimit)
            .putInt(KEY_LANDING_MISS_STREAK, 0)
            .commit()
        Log.w(TAG, "알림 착지 실패 연속 ${streak}회, 기기 상한 재보정: total=$total → deviceNotifLimit=$learnedLimit")

        val snapshot: List<Pair<Int, Long>> = active.map { it.id to it.postTime }
        // R2-M1: 학습값 기록 + 정리는 STOP 여부와 무관하게 한다 — 이 기기의 실제 상한을 알아낸
        // 사실과, 밀린 카드 알림을 정리하는 것은 지금 push가 켜져 있는지와 상관없이 항상 맞는
        // 일이다. re-notify()만 별도로 막는다 — showCardNotification이 STOP tombstone을
        // 두 번(발화 진입 시·notify 직전) 확인하는 것과 같은 이유로, 여기서 최대 400ms를 더
        // 기다린 뒤라 그 사이에 사용자가 OFF를 눌렀을 수 있다. 이 재시도 notify()에도 같은
        // 확인을 붙이지 않으면 "방금 껐는데 한 장 더"가 이 경로로 다시 뚫린다 — 학습/정리와
        // 재시도-notify를 한 조건으로 묶지 말 것(의도적 분리).
        cardNotifsToEvict(snapshot, notifId, learnedLimit, NOTIF_HEADROOM).forEach { nm.cancel(it) }
        if (pushPrefs.getBoolean("running", false)) {
            nm.notify(notifId, builder.build())
        } else {
            Log.d(TAG, "STOP 이후 재보정 재시도 notify 취소")
        }
    }

    private fun findDbFile(): java.io.File? {
        val dataDir = applicationInfo.dataDir
        // getDatabasePath를 우선 시도 (공식 API)
        val candidates = listOf(
            getDatabasePath("memora.db"),
            java.io.File(dataDir, "app_flutter/memora.db"),
            java.io.File(filesDir, "app_flutter/memora.db"),
            java.io.File(filesDir, "memora.db"),
        )
        for (candidate in candidates) {
            if (candidate.exists() && candidate.canRead()) return candidate
        }
        Log.w(TAG, "DB 파일을 찾을 수 없음. 검색 경로: ${candidates.map { it.path }}")
        return null
    }

    /**
     * 복습 알림 채널 보장. [REVIEW_CHANNEL_ID]는 원래 Flutter 플러그인이 만들지만,
     * 없으면 알림이 아예 안 뜨므로 여기서도 fallback으로 만든다.
     * [force]면 이미 있어도 다시 만들어 이름/설명을 현재 언어로 갱신한다
     * (같은 ID 재생성은 비파괴적 — 사용자가 조정한 중요도·소리는 유지된다).
     */
    private fun ensureReviewChannel(nm: NotificationManager?, force: Boolean = false) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || nm == null) return
        val exists = nm.getNotificationChannel(REVIEW_CHANNEL_ID) != null
        if (if (force) !exists else exists) return
        val res = AppLang.wrap(this, lang)
        nm.createNotificationChannel(
            NotificationChannel(
                REVIEW_CHANNEL_ID,
                res.getString(R.string.push_review_channel_name),
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = res.getString(R.string.push_review_channel_desc)
                enableVibration(true)
            }
        )
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val res = AppLang.wrap(this, lang)
            val channel = NotificationChannel(
                CHANNEL_ID,
                res.getString(R.string.push_service_channel_name),
                NotificationManager.IMPORTANCE_MIN
            ).apply {
                description = res.getString(R.string.push_service_channel_desc)
                setShowBadge(false)
            }
            val nm = getSystemService(NotificationManager::class.java) ?: return
            nm.createNotificationChannel(channel)
        }
    }

    private fun fmtClock(totalMinutes: Int): String {
        val h = totalMinutes / 60
        val m = totalMinutes % 60
        return String.format(java.util.Locale.US, "%02d:%02d", h, m)
    }

    private fun createServiceNotification(): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("navigate_to", "push_notification_settings")
        }
        val pi = PendingIntent.getActivity(this, 2, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        // 상주 알림에 보여줄 문구는 지금 이 순간의 실제 상태를 반영한다: 활성 규칙이
        // 있으면 그 시간대/간격을, 없으면(gap) 다음 규칙이 언제 시작하는지를, 규칙
        // 자체가 없으면(스위치는 켜져 있는데 아직 규칙을 못 만든 극단적 상태) 일시중지를.
        val now = nowMinutes()
        val rule = PushSchedule.activeRule(now, rules)
        val res = AppLang.wrap(this, lang)
        val contentText = if (rule != null) {
            val rangeText = "${fmtClock(rule.start)}~${fmtClock(rule.end)}"
            res.getString(R.string.push_service_text_active, rangeText, rule.intervalMin)
        } else if (rules.isNotEmpty()) {
            val nextStartMin = (now + PushSchedule.minutesUntilNextStart(now, rules)) % 1440
            res.getString(R.string.push_service_text_idle, fmtClock(nextStartMin))
        } else {
            res.getString(R.string.push_service_text_paused)
        }

        // 상주 알림이 스와이프로 제거되면 서비스가 다시 알림을 생성
        val recreateIntent = Intent(this, PushNotificationService::class.java).apply {
            action = "RECREATE_NOTIFICATION"
        }
        val deletePi = foregroundServicePendingIntent(
            this, 200, recreateIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Memora")
            .setContentText(contentText)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(pi)
            .setDeleteIntent(deletePi)
            .setOngoing(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun saveNextFireTime(time: Long) {
        getSharedPreferences("push_notif_prefs", MODE_PRIVATE)
            .edit().putLong("nextFireTime", time).commit()
    }

    private fun saveRunning(running: Boolean) {
        getSharedPreferences("push_notif_prefs", MODE_PRIVATE)
            .edit().putBoolean("running", running).commit()
    }
}
