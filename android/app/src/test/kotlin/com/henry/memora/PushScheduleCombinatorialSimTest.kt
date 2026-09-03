package com.henry.memora

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** 음수 나머지도 0..1439로 접어주는 자정랩 정규화 — 파일 전체(TickSimulator 포함)가 쓴다. */
private fun Int.floorMod1440(): Int = ((this % 1440) + 1440) % 1440

/**
 * 시간대 규칙(PushSchedule) "실전 조합" 시뮬레이션 — v1.3.9 통합 이후 사용자가 실제
 * UI에서 만들 법한 규칙 조합을 이름 붙여 나열하고, 실제 프로덕션 함수(parse/
 * activeRule/minutesUntilNextStart)를 그대로 태워 검증한다.
 *
 * test/push_schedule_combinatorial_sim_test.dart와 짝을 이룬다 — 그쪽은 "정적"
 * 소유권(activeRule ↔ effectiveRanges/gapRanges) 정합성을, 여기 Kotlin은
 * PushNotificationService의 AlarmManager 기반 TICK 스케줄링 체인(드리프트 방지
 * 재귀식)이 시간축을 따라 실제로 어떻게 발화하는지를 검증한다 — Dart 쪽엔 "간격"
 * 개념이 스케줄링에 관여하지 않으므로(순수 시간표일 뿐) 이 부분은 Kotlin에서만
 * 가능하다.
 *
 * ⚠️ UI 슬롯 개수 상한: PushSchedule.MAX_RULES는 12다. 사용자가 이 기능을 "5개
 * 슬롯"이라 부른 적이 있으나 실제 UI(push_notification_settings.dart의
 * `_onAddPushRuleTapped`)는 `_rules.length >= PushSchedule.maxRules`(=12)에서만
 * 막고, 안내 문구도 "최대 12개"(app_ko.arb pushScheduleMaxReached)다 — 5는 실제
 * 제한이 아니다. S13이 실제 UI 상한인 12를 꽉 채워 스트레스한다.
 */
class PushScheduleCombinatorialSimTest {

    companion object {
        // S1 — 5개 규칙이 하루를 gap 없이 완전히 분할 (06-10/10-14/14-18/18-22/22-06)
        const val S1 = "360:600:1:30,600:840:2:15,840:1080:3:60,1080:1320:4:20,1320:360:5:10"

        // S2 — 3개 규칙만 채우고 나머지는 무음(gap)
        const val S2 = "540:720:1:30,900:1020:2:45,1200:1320:3:60"

        // S3 — 두 쌍이 겹침: 평일 부분겹침(09-15 & 12-18) + 자정넘김 부분겹침(20-02 & 22-04)
        const val S3 = "540:900:1:30,720:1080:2:20,1200:120:3:15,1320:240:4:25"

        // S4 — 한 슬롯(12-13)이 다른 슬롯(09-18) 안에 완전히 포함되어 영원히 가려짐
        const val S4 = "540:1080:1:30,720:780:2:20"

        // S5 — 5개 전부 같은 시각(10:00)에 시작, 끝나는 시각만 다름 — stable sort 타이브레이크
        const val S5 = "600:660:1:10,600:720:2:20,600:900:3:30,600:1000:4:40,600:1200:5:50"

        // S6 — 전체 폴더(-1) 슬롯과 특정 폴더 슬롯이 섞여 하루를 분할
        const val S6 = "0:480:-1:30,480:960:7:45,960:0:12:20"

        // S7 — 인접한 두 슬롯의 간격이 극단적으로 다름(5분 슬롯 뒤 1440분 슬롯)
        const val S7 = "0:5:1:5,5:0:2:1440"

        // S8 — 슬롯 길이(10분)가 그 슬롯 자신의 간격(30분)보다 짧음
        const val S8 = "540:550:1:30"

        // S9 — 자정을 넘는 슬롯이 "둘 다" 있고 서로 겹침(22-03 & 23-04)
        const val S9 = "1320:180:1:20,1380:240:2:25"

        // S11 — 경계값 극단: start=0,end=1439(거의 하루 전체) + 1439-0(1분짜리 wrap 슬롯)
        const val S11 = "0:1439:1:30,1439:0:2:60"

        // S12 — 실사용 패턴: 기상 직후 복습 30분 + 근무시간 무음 + 저녁 신규카드 + 취침 무음
        const val S12 = "420:450:1:60,1140:1380:2:20"

        // S13 — 12개(=실제 UI 상한) 꽉 채움, 슬롯 사이마다 60분 gap
        val S13: String = (0 until 12).joinToString(",") { i ->
            val start = i * 110
            "$start:${start + 50}:$i:${5 + i * 3}"
        }

        val ALL_SCENARIOS = listOf(
            "S1_전체분할_gap없음" to S1,
            "S2_부분채움_gap있음" to S2,
            "S3_두겹침쌍_평일및자정넘김" to S3,
            "S4_완전포함_가려짐" to S4,
            "S5_동시시작_극단겹침" to S5,
            "S6_전체폴더혼합" to S6,
            "S7_인접간격극단차" to S7,
            "S8_슬롯보다긴간격" to S8,
            "S9_이중자정넘김겹침" to S9,
            "S11_경계극단" to S11,
            "S12_실사용패턴" to S12,
            "S13_최대12개스트레스" to S13,
        )
    }

    /**
     * PushNotificationService.onStartCommand의 ACTION_TICK 분기(176~206행 부근)가
     * 쓰는 "예정시각 기준 드리프트 없는 체인" 재귀식을 그대로 이식한 시뮬레이터.
     * 실제 android.app.Service/AlarmManager 없이 순수 분단위 정수 연산으로 같은
     * 수식을 재현하고, activeRule/minutesUntilNextStart는 프로덕션 함수를 직접
     * 호출한다 — 재구현하지 않는다.
     *
     * 실제 서비스는 절대시각(epoch ms)을 쓰고 Doze/지연으로 인한 catch-up
     * while루프가 있지만, 이 시뮬레이터는 알람이 항상 정확히 예정시각에 처리된다고
     * 가정한다(그 while루프는 `nextFireTime <= currentTime`일 때만 도는데, 매 틱을
     * 예정시각 정각에 처리하는 이 모델에서는 그 조건이 성립할 일이 없다 — 이는
     * AlarmManager 정확도라는 별개의 관심사이지 스케줄링 알고리즘 자체의 로직이
     * 아니다).
     */
    private class TickSimulator(private val rules: List<PushSchedule.Rule>) {
        var nowAbs: Int = 0
            private set
        var nextFireAbs: Int = 0
            private set
        val fires = mutableListOf<Pair<Int, PushSchedule.Rule>>()

        /** 메인 분기(스위치 On/설정변경) — 알림을 쏘지 않고 첫 알람만 예약한다. */
        fun start(atAbsoluteMinute: Int) {
            nowAbs = atAbsoluteMinute
            val nowOfDay = nowAbs.floorMod1440()
            val rule = PushSchedule.activeRule(nowOfDay, rules)
            val delay = if (rule != null) {
                rule.intervalMin
            } else {
                minOf(
                    PushSchedule.minutesUntilNextStart(nowOfDay, rules),
                    PushNotificationService.MAX_GAP_POLL_MIN
                )
            }
            nextFireAbs = nowAbs + delay
        }

        /**
         * ACTION_TICK 한 번 — 다음 알람을 먼저 예약한 뒤(체인 유지가 우선), 규칙이
         * 있으면 그 규칙으로 발화하고, 없으면(gap) 조용히 대기만 한다. 반환값은 이번
         * 틱이 실제로 처리된 절대분(=직전에 예약돼 있던 nextFireAbs).
         */
        fun stepToNextTick(): Int {
            val now = nextFireAbs
            nowAbs = now
            val nowOfDay = now.floorMod1440()
            val rule = PushSchedule.activeRule(nowOfDay, rules)
            if (rule != null) {
                nextFireAbs = now + rule.intervalMin
                fires.add(now to rule)
            } else {
                val gapMin = minOf(
                    PushSchedule.minutesUntilNextStart(nowOfDay, rules),
                    PushNotificationService.MAX_GAP_POLL_MIN
                )
                nextFireAbs = now + gapMin
            }
            return now
        }
    }

    /**
     * 한 시나리오를 여러 시작 위상(phase)에서 [totalDays]일치 시뮬레이션하며
     * (1) 알람 체인이 항상 전진하는지(멈추거나 역행하지 않는지)
     * (2) 모든 발화가 그 순간의 activeRule과 정확히 일치하는지(gap에서 발화하거나
     *     엉뚱한 규칙으로 발화하는 일이 없는지)
     * 를 검증한다. 이게 "경계를 넘는 매 순간 폴더/간격이 기대한 대로 바뀌는지"의
     * 시간축 버전이다 — 정적 activeRule() 호출만으로는 못 잡는, 실제 알람 체인의
     * 오발화·정체를 잡아낸다.
     */
    private fun assertTickChainNeverMisfires(name: String, csv: String, totalDays: Int = 3) {
        val rules = PushSchedule.parse(csv)
        val phases = listOf(0, 1, 137, 359, 599, 600, 733, 1000, 1319, 1320, 1439)
        for (phase in phases) {
            val sim = TickSimulator(rules)
            sim.start(phase)
            val horizon = phase + totalDays * 1440
            var iterations = 0
            val maxIterations = totalDays * 1440 * 2 + 2000
            while (sim.nextFireAbs <= horizon) {
                val scheduled = sim.nextFireAbs
                val tickAt = sim.stepToNextTick()
                assertEquals(
                    "$name phase=$phase: stepToNextTick가 예약된 시각과 다른 시각을 처리함",
                    scheduled, tickAt
                )
                assertTrue(
                    "$name phase=$phase tickAt=$tickAt: 다음 알람이 전진하지 않음(정체/역행 — 무한루프 위험)",
                    sim.nextFireAbs > tickAt
                )
                iterations++
                assertTrue(
                    "$name phase=$phase: 반복 상한(${maxIterations}) 초과 — 무한루프 의심",
                    iterations < maxIterations
                )
            }
            for ((minuteAbs, firedRule) in sim.fires) {
                val nowOfDay = minuteAbs.floorMod1440()
                val expected = PushSchedule.activeRule(nowOfDay, rules)
                assertNotNull(
                    "$name phase=$phase minuteAbs=$minuteAbs(=${nowOfDay}분): gap인데 발화함",
                    expected
                )
                assertEquals(
                    "$name phase=$phase minuteAbs=$minuteAbs: 발화한 규칙이 그 순간의 activeRule과 다름",
                    expected, firedRule
                )
            }
        }
    }

    @Test
    fun `모든 명명 시나리오 — TICK 체인이 3일간 결코 오발화하지 않는다`() {
        for ((name, csv) in ALL_SCENARIOS) {
            assertTickChainNeverMisfires(name, csv)
        }
    }

    @Test
    fun `S13 — parse가 실제 UI 상한 12개를 전부 받아들인다`() {
        val rules = PushSchedule.parse(S13)
        assertEquals(12, rules.size)
        assertEquals(12, PushSchedule.MAX_RULES)
    }

    // ─────────────────────────────────────────────────────────
    // S7 — 인접 슬롯 간 간격 극단차: 전환 지연은 나가는 슬롯 간격의 1주기 미만
    // ─────────────────────────────────────────────────────────

    @Test
    fun `S7 — 짧은 슬롯에서 긴 간격 슬롯으로 넘어갈 때 전환 지연은 나가는 규칙 간격 1주기 미만`() {
        val rules = PushSchedule.parse(S7)
        val outgoing = rules.first { it.folderId == 1 } // 0-5, interval=5
        // rule1(0-5)이 커버하는 모든 가능한 시작 위상(0,1,2,3,4)에서 반복 — 실제
        // 사용자가 알림을 켠 순간은 이 5분 창 안 어디든 될 수 있다.
        for (phase in 0 until (outgoing.end - outgoing.start)) {
            val sim = TickSimulator(rules)
            sim.start(phase)
            var guard = 0
            while (sim.fires.none { it.second.folderId == 2 }) {
                sim.stepToNextTick()
                guard++
                assertTrue("phase=$phase: 500틱 안에 전환이 안 일어남(무한루프 의심)", guard < 500)
            }
            val firstNewRegimeFireAt = sim.fires.first { it.second.folderId == 2 }.first
            val staleness = firstNewRegimeFireAt - outgoing.end // 경계=5
            assertTrue(
                "phase=$phase: staleness=$staleness 가 음수 — 경계 전에 새 규칙이 발화함(있을 수 없음)",
                staleness >= 0
            )
            assertTrue(
                "phase=$phase: staleness=$staleness 가 나가는 규칙(folder=1)의 간격(${outgoing.intervalMin}) 이상"
                    + " — 전환 지연이 '나가는 슬롯 1주기 이내'라는 설계 보장을 넘음",
                staleness < outgoing.intervalMin
            )
        }
    }

    // ─────────────────────────────────────────────────────────
    // S8 — 슬롯(10분)이 자기 간격(30분)보다 짧으면, 특정 위상에서 그 슬롯 안에서
    // 한 번도 안 울릴 수 있다 — 설계상 허용된 동작(버그 아님)임을 위상을 직접
    // 통제해 실증한다. (Dart 쪽 S8은 이 부분을 "정적으로는 유효한 선언"까지만
    // 확인하고, 위상 의존적인 "실제로 스킵될 수 있다"는 주장은 여기서 증명한다.)
    // ─────────────────────────────────────────────────────────

    @Test
    fun `S8 변형 — 짧은 슬롯을 감싸는 두 규칙의 간격이 위상에 따라 그 슬롯을 통째로 건너뛸 수 있다(설계상 허용)`() {
        // rule7: 00:00-09:00(0-540) interval=12분. rule1: 09:00-09:10(540-550, 10분짜리
        // 짧은 슬롯) interval=30분. rule9: 09:10-24:00(550-0, wrap) interval=100분.
        // 위상을 10분으로 고정하면 rule7의 틱이 10,22,34,...,538로 진행하다가 538+12=550으로
        // 점프해 540-550 슬롯을 통째로 건너뛴다(538<540이고 550>=550이라 슬롯 안의 어떤
        // 분도 틱과 만나지 않음).
        val csv = "0:540:7:12,540:550:1:30,550:0:9:100"
        val rules = PushSchedule.parse(csv)
        val sim = TickSimulator(rules)
        sim.start(10)
        while (sim.nowAbs < 550) {
            sim.stepToNextTick()
        }
        assertTrue(
            "538분에 folder=7(rule7)이 발화했어야 함 — 실제 발화 목록: ${sim.fires}",
            sim.fires.any { it.first == 538 && it.second.folderId == 7 }
        )
        assertTrue(
            "538분 다음 발화가 550분(folder=9)이어야 함(540-550 슬롯을 건너뜀) — 실제 발화 목록: ${sim.fires}",
            sim.fires.any { it.first == 550 && it.second.folderId == 9 }
        )
        assertTrue(
            "짧은 슬롯(folder=1, 540-550)은 이 위상에서 단 한 번도 발화하지 않아야 한다"
                + " — 슬롯(10분) < 간격(30분)일 때 설계상 허용되는 동작이지 버그가 아니다."
                + " 실제 발화 목록: ${sim.fires}",
            sim.fires.none { it.second.folderId == 1 }
        )
    }
}
