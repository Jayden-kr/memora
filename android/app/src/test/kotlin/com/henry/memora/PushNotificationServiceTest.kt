package com.henry.memora

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PushNotificationService.Companion의 순수 로직(recentCardIds 파싱/인코딩 +
 * 직전 카드 재출현 방지 가드 판정 + 알림 상한 자가보정 판정) 유닛테스트. 전부
 * Android API 의존성이 없어 Service 인스턴스 없이 JVM에서 바로 검증 가능하다.
 */
class PushNotificationServiceTest {

    // ─────────────────────────────────────────────────────────
    // parseRecentIds / encodeRecentIds — 파싱 왕복
    // ─────────────────────────────────────────────────────────

    @Test
    fun `encode then parse round-trips a representative id list`() {
        val original = listOf(42, 7, 13, 1, 99)
        val csv = PushNotificationService.encodeRecentIds(original)
        assertEquals(original, PushNotificationService.parseRecentIds(csv))
    }

    @Test
    fun `empty list encodes to empty string and parses back to empty list`() {
        assertEquals("", PushNotificationService.encodeRecentIds(emptyList()))
        assertEquals(emptyList<Int>(), PushNotificationService.parseRecentIds(""))
    }

    // ─────────────────────────────────────────────────────────
    // parseRecentIds — 깨진 CSV는 절대 throw하지 않고 조용히 드롭
    // ─────────────────────────────────────────────────────────

    @Test
    fun `parseRecentIds never throws on garbage input`() {
        val garbage = listOf(
            null,
            "",
            "   ",
            ",,,",
            "abc",
            "1,abc,3",
            "1, ,3",
            "1,,3",
            ",1,2",
            "1,2,",
            "🎉,1,2",
            "1.5,2",
            "-1,-2,-3",
            "999999999999999999999" // Int 오버플로
        )
        for (input in garbage) {
            // throw만 안 하면 통과 — 반환값 자체는 케이스마다 아래에서 개별 검증.
            PushNotificationService.parseRecentIds(input)
        }
    }

    @Test
    fun `parseRecentIds drops non-numeric tokens but keeps valid ones`() {
        assertEquals(listOf(1, 3), PushNotificationService.parseRecentIds("1,abc,3"))
    }

    @Test
    fun `parseRecentIds drops empty tokens from consecutive or trailing commas`() {
        assertEquals(listOf(1, 2), PushNotificationService.parseRecentIds("1,,2,"))
    }

    @Test
    fun `parseRecentIds trims surrounding whitespace`() {
        assertEquals(listOf(1, 2, 3), PushNotificationService.parseRecentIds(" 1 , 2 , 3 "))
    }

    @Test
    fun `parseRecentIds caps at RECENT_CARD_LIMIT even if csv has more`() {
        val csv = (1..10).joinToString(",")
        val result = PushNotificationService.parseRecentIds(csv)
        assertEquals(PushNotificationService.RECENT_CARD_LIMIT, result.size)
        assertEquals(listOf(1, 2, 3, 4, 5), result)
    }

    // ─────────────────────────────────────────────────────────
    // shouldExcludeRecentCards — 카드 부족 시 가드
    // ─────────────────────────────────────────────────────────

    @Test
    fun `guard allows exclusion when card pool comfortably exceeds recent history`() {
        // 최근 5개 기억 중인데 폴더에 카드가 10개 있으면 제외해도 5개나 남는다.
        assertTrue(PushNotificationService.shouldExcludeRecentCards(totalCount = 10, recentSize = 5))
    }

    @Test
    fun `guard blocks exclusion when card pool is at or below the danger threshold`() {
        // 최근 5개를 기억하는데 폴더에 카드가 딱 5개(recentSize와 같음)뿐이면 전부
        // 제외 대상이라 0건이 나올 수 있다 — 걸면 안 된다.
        assertFalse(PushNotificationService.shouldExcludeRecentCards(totalCount = 5, recentSize = 5))
        // 더 적어도(카드 < 최근개수) 당연히 걸면 안 된다.
        assertFalse(PushNotificationService.shouldExcludeRecentCards(totalCount = 3, recentSize = 5))
        assertFalse(PushNotificationService.shouldExcludeRecentCards(totalCount = 0, recentSize = 5))
    }

    @Test
    fun `guard blocks exclusion when there is no recent history to exclude`() {
        // recentSize==0(처음 발화, 또는 prefs가 비어있음)이면 제외 조건 자체가 무의미하다.
        assertFalse(PushNotificationService.shouldExcludeRecentCards(totalCount = 100, recentSize = 0))
    }

    @Test
    fun `guard boundary — exactly recentSize is still blocked`() {
        // worst-case로 recentSize개 전부가 이 카드 5장 안에 있으면 제외 후 0건.
        assertFalse(PushNotificationService.shouldExcludeRecentCards(totalCount = 5, recentSize = 5))
    }

    @Test
    fun `guard boundary — exactly recentSize plus one is allowed`() {
        // worst-case로 제외해도 1건은 남는다 — 1라운드 감사에서 발견된 off-by-one 수정:
        // 예전엔 이 경계에서 false였다(불필요하게 보수적 — 이 경계에서만 재출현 방지가
        // 안 걸리는 구멍이었다).
        assertTrue(PushNotificationService.shouldExcludeRecentCards(totalCount = 6, recentSize = 5))
    }

    @Test
    fun `guard boundary — well above recentSize is allowed`() {
        assertTrue(PushNotificationService.shouldExcludeRecentCards(totalCount = 7, recentSize = 5))
    }

    // ─────────────────────────────────────────────────────────
    // 상수 값 자체가 조용히 바뀌는 것을 잡는 핀 테스트
    // ─────────────────────────────────────────────────────────

    @Test
    fun `notif limit constants are pinned`() {
        assertEquals(50, PushNotificationService.DEFAULT_DEVICE_NOTIF_LIMIT)
        assertEquals(5, PushNotificationService.NOTIF_HEADROOM)
        assertEquals(20, PushNotificationService.DROP_DETECT_MIN_TOTAL)
        // R3-L1: MIN_DEVICE_NOTIF_LIMIT은 값이 아니라 유도된 관계다 — 값 자체(24)뿐 아니라
        // 그 값을 만드는 식(DROP_DETECT_MIN_TOTAL + NOTIF_HEADROOM - 1)도 함께 고정해서,
        // 둘 중 하나만 따로 바뀌는 조용한 회귀(관계가 깨지는 것)를 잡는다.
        assertEquals(24, PushNotificationService.MIN_DEVICE_NOTIF_LIMIT)
        assertEquals(
            PushNotificationService.DROP_DETECT_MIN_TOTAL + PushNotificationService.NOTIF_HEADROOM - 1,
            PushNotificationService.MIN_DEVICE_NOTIF_LIMIT
        )
        // R1-H1: 착지 확인 창 = 0/200/400ms(3회 × 200ms), 학습 확정 전 연속 실패 요구치.
        assertEquals(3, PushNotificationService.LANDING_CHECK_ATTEMPTS)
        assertEquals(200L, PushNotificationService.LANDING_CHECK_INTERVAL_MS)
        assertEquals(2, PushNotificationService.LANDING_MISS_STREAK_TO_LEARN)
    }

    // ─────────────────────────────────────────────────────────
    // clampLearnedLimit — 바닥 보장
    // ─────────────────────────────────────────────────────────

    @Test
    fun `clampLearnedLimit keeps an observed total above the floor unchanged`() {
        // R3-L1: MIN_DEVICE_NOTIF_LIMIT이 24로 올라간 뒤에도 "바닥보다 확실히 위"인
        // 사례로 남아야 하므로 30을 쓴다(24 자체는 이제 바닥과 같은 값이라 이 케이스를
        // 대표하지 못한다).
        assertEquals(30, PushNotificationService.clampLearnedLimit(30))
    }

    @Test
    fun `clampLearnedLimit raises a pathologically low observed total to the floor`() {
        assertEquals(PushNotificationService.MIN_DEVICE_NOTIF_LIMIT, PushNotificationService.clampLearnedLimit(3))
    }

    @Test
    fun `learned occupancy always stays strictly below the total that justified learning it`() {
        // R3-L1의 핵심 불변식: 학습이 허용되는 모든 total(즉 total >= DROP_DETECT_MIN_TOTAL)에
        // 대해, 그 학습이 정착시키는 점유량(learnedLimit - NOTIF_HEADROOM)은 이 기기가 이미
        // 실측으로 증명한 동시 알림 개수(total)보다 반드시 더 낮아야 한다 — 안 그러면
        // "방금 실측으로 버틸 수 있다고 확인한 값" 이상으로 우리가 점유해 버려 다시 상한에
        // 부딪힌다. 세 상수(DROP_DETECT_MIN_TOTAL/NOTIF_HEADROOM/MIN_DEVICE_NOTIF_LIMIT) 중
        // 무엇이 바뀌어도 이 관계 자체가 성립하는지 이 테스트 하나로 계속 검증된다.
        for (t in PushNotificationService.DROP_DETECT_MIN_TOTAL..100) {
            val occupancy = PushNotificationService.clampLearnedLimit(t) - PushNotificationService.NOTIF_HEADROOM
            assertTrue("t=$t occupancy=$occupancy", occupancy < t)
        }
    }

    // ─────────────────────────────────────────────────────────
    // cardNotifsToEvict — 헬퍼
    // ─────────────────────────────────────────────────────────

    private val base = PushNotificationService.CARD_NOTIF_BASE

    /** id=[base]+n, postTime=[n]인 카드 알림 하나. */
    private fun card(n: Int): Pair<Int, Long> = (base + n) to n.toLong()

    // ─────────────────────────────────────────────────────────
    // cardNotifsToEvict — 예산 안/밖
    // ─────────────────────────────────────────────────────────

    @Test
    fun `under budget evicts nothing`() {
        // deviceLimit=50, headroom=5, otherCount=0 → budget=45. 카드 3장뿐이라 여유가 크다.
        val active = listOf(card(1), card(2), card(3))
        val result = PushNotificationService.cardNotifsToEvict(
            active, incomingId = base + 999, deviceLimit = 50, headroom = 5
        )
        assertEquals(emptyList<Int>(), result)
    }

    @Test
    fun `exactly at budget with a brand-new incoming id evicts exactly one, the oldest`() {
        // deviceLimit=24, headroom=5, otherCount=0 → budget=19. 카드가 정확히 19장 있고
        // 새 카드가 하나 더 들어오면 딱 1장만(가장 오래된 것) 내보내야 19장을 유지한다.
        val active = (1..19).map { card(it) }
        val result = PushNotificationService.cardNotifsToEvict(
            active, incomingId = base + 999, deviceLimit = 24, headroom = 5
        )
        assertEquals(listOf(base + 1), result)  // postTime=1이 가장 오래됨
    }

    @Test
    fun `at budget but incoming id is already in the tray evicts nothing`() {
        // incomingId가 이미 트레이에 있으면(교체) 총량이 늘지 않으므로 excess=0.
        val active = (1..19).map { card(it) }
        val result = PushNotificationService.cardNotifsToEvict(
            active, incomingId = base + 10, deviceLimit = 24, headroom = 5
        )
        assertEquals(emptyList<Int>(), result)
    }

    @Test
    fun `legacy pile-up of 60 card notifications trims down to exactly budget in one call`() {
        // deviceLimit=50, headroom=5, otherCount=0 → budget=45. 60장 쌓여 있으면
        // 신규 카드 1장을 포함해 45장이 되도록 16장을 내보내야 한다.
        val active = (1..60).map { card(it) }
        val result = PushNotificationService.cardNotifsToEvict(
            active, incomingId = base + 999, deviceLimit = 50, headroom = 5
        )
        assertEquals(16, result.size)
        val survivingCards = active.map { it.first }.filterNot { it in result }
        assertEquals(45, survivingCards.size + 1) // +1 = 새로 뜰 카드
        // 내보낸 건 항상 가장 오래된 것부터: postTime 1..16(=id base+1..base+16).
        assertEquals((1..16).map { base + it }, result)
    }

    @Test
    fun `incoming id is never evicted even when it would otherwise be the oldest`() {
        // incomingId 자신이 트레이에 이미 있고(교체) postTime이 가장 오래돼도 후보에서
        // 제외돼야 한다 — 지금 막 다시 띄우는 대상을 스스로 지우면 안 된다.
        val incoming = base + 1
        val active = listOf((incoming to 0L)) + (2..20).map { card(it) } // 20장, incoming 포함
        val result = PushNotificationService.cardNotifsToEvict(
            active, incomingId = incoming, deviceLimit = 24, headroom = 5
        )
        // deviceLimit=24, headroom=5, otherCount=0 → budget=19. isReplacement=true라
        // excess = 20 + 0 - 19 = 1. incoming(postTime=0)을 빼고 그 다음으로 오래된
        // postTime=2(id base+2)가 나가야 한다.
        assertFalse(incoming in result)
        assertEquals(listOf(base + 2), result)
    }

    @Test
    fun `non-card ids are never evicted but still consume budget`() {
        // 카드가 아닌 알림(상주 서비스 3, 복습알림 요약류 2001/2002/9001, 기타 99999)도
        // 트레이 자리를 차지하지만, 이 함수가 지울 대상은 카드뿐이다.
        // postTime을 카드보다도 더 오래된 값(0)으로 줘서, 만약 id>=CARD_NOTIF_BASE
        // 필터가 빠지면 "가장 오래된 것부터" 정렬에 의해 이 비카드 id들이 제일 먼저
        // 뽑혀 나온다 — 필터 누락을 실제로 잡아내는 배치.
        val nonCardIds = listOf(0, 1, 3, 2001, 2002, 9001, 99999)
        val nonCardActive = nonCardIds.map { it to 0L }
        val cardActive = (1..60).map { card(it) }
        val active = nonCardActive + cardActive
        val result = PushNotificationService.cardNotifsToEvict(
            active, incomingId = base + 999, deviceLimit = 50, headroom = 5
        )
        // otherCount=7이 예산을 깎아먹는다: budget = 50-5-7 = 38.
        // excess = 60 + 1 - 38 = 23.
        assertEquals(23, result.size)
        for (id in nonCardIds) assertFalse(id in result)
        for (id in result) assertTrue(id >= base)
        // 진짜로 카드 중 가장 오래된 23장(postTime 1..23)이 나가야 한다 — 비카드
        // id들의 postTime=0이 더 오래됐어도 후보 풀에 없으므로 무관해야 한다.
        assertEquals((1..23).map { base + it }, result)
    }

    @Test
    fun `postTime ties break deterministically by ascending id`() {
        // 세 카드가 전부 같은 postTime — 정렬이 postTime만으로는 결정 불가하므로
        // id 오름차순이 2차 키가 돼야 한다(안 그러면 flaky 순서).
        val active = listOf(
            (base + 9) to 100L,
            (base + 5) to 100L,
            (base + 3) to 100L,
        )
        // deviceLimit=7, headroom=5, otherCount=0 → budget=2. excess = 3+1-2 = 2.
        val result = PushNotificationService.cardNotifsToEvict(
            active, incomingId = base + 999, deviceLimit = 7, headroom = 5
        )
        assertEquals(listOf(base + 3, base + 5), result) // 낮은 id부터 나감
    }

    @Test
    fun `degenerate budget floors at 1, does not crash, does not evict the incoming id`() {
        // otherCount=20 + headroom=10 이 deviceLimit=5를 완전히 잡아먹어
        // (5-10-20 = -25) 예산이 음수가 되는 병적인 입력. maxOf(...,1)로 바닥을 지켜야
        // 하고, incomingId는 애초에 후보가 아니므로 결과에 나오면 안 된다.
        val nonCardActive = (1..20).map { it to 500L }
        val cardActive = (1..3).map { card(it) }
        val active = nonCardActive + cardActive
        val incoming = base + 999
        val result = PushNotificationService.cardNotifsToEvict(
            active, incomingId = incoming, deviceLimit = 5, headroom = 10
        )
        // budget=1, excess = 3+1-1 = 3 → 카드 3장 전부 내보내야 한다.
        assertEquals(setOf(base + 1, base + 2, base + 3), result.toSet())
        assertFalse(incoming in result)
    }

    // ─────────────────────────────────────────────────────────
    // 자가보정(clampLearnedLimit) 이후에도 예산이 상한 안에 머무는지 — 회귀 핀
    // ─────────────────────────────────────────────────────────

    @Test
    fun `after learning a 24-notification cap, the resulting occupancy stays within that cap`() {
        val observedTotal = 24
        val learnedLimit = PushNotificationService.clampLearnedLimit(observedTotal)
        val otherCount = 2 // 상주 알림 등, 카드가 아닌 알림
        val cardsSize = 30 // 예산을 넘는 파일업

        val nonCardActive = (1..otherCount).map { it to 500L }
        val cardActive = (1..cardsSize).map { card(it) }
        val active = nonCardActive + cardActive
        val incoming = base + 999

        val evicted = PushNotificationService.cardNotifsToEvict(
            active, incomingId = incoming, deviceLimit = learnedLimit, headroom = PushNotificationService.NOTIF_HEADROOM
        )
        val survivingCards = cardsSize - evicted.size
        val totalAfter = survivingCards + 1 /* 새로 뜰 카드 */ + otherCount

        // headroom을 상수로 계산 — 하드코딩된 숫자가 아니라 NOTIF_HEADROOM 자체가
        // 바뀌어도 이 불변식(occupancy가 학습된 상한보다 headroom만큼 밑에 머문다)이
        // 그대로 성립해야 한다.
        assertEquals(learnedLimit - PushNotificationService.NOTIF_HEADROOM, totalAfter)
        assertTrue(totalAfter <= learnedLimit)
    }

    // ─────────────────────────────────────────────────────────
    // shouldRecalibrate — R1-H1: "OS 상한"이라고 결론지어도 되는가
    // ─────────────────────────────────────────────────────────

    @Test
    fun `shouldRecalibrate is false below DROP_DETECT_MIN_TOTAL at every streak value`() {
        val belowThreshold = PushNotificationService.DROP_DETECT_MIN_TOTAL - 1
        for (streak in listOf(1, 2, 3, 100)) {
            assertFalse(
                "streak=$streak, total=$belowThreshold",
                PushNotificationService.shouldRecalibrate(missStreakAfterThisMiss = streak, total = belowThreshold)
            )
        }
    }

    @Test
    fun `shouldRecalibrate is false at or above the total threshold when streak is only 1`() {
        assertFalse(
            PushNotificationService.shouldRecalibrate(
                missStreakAfterThisMiss = 1, total = PushNotificationService.DROP_DETECT_MIN_TOTAL
            )
        )
    }

    @Test
    fun `shouldRecalibrate is true once total and streak both reach their thresholds`() {
        assertTrue(
            PushNotificationService.shouldRecalibrate(
                missStreakAfterThisMiss = PushNotificationService.LANDING_MISS_STREAK_TO_LEARN,
                total = PushNotificationService.DROP_DETECT_MIN_TOTAL
            )
        )
    }

    @Test
    fun `shouldRecalibrate stays true for streaks beyond the threshold — no off-by-one`() {
        // 정확히 문턱에서만 true가 되는 버그(>보다 좁은 ==)를 잡는다.
        assertTrue(
            PushNotificationService.shouldRecalibrate(
                missStreakAfterThisMiss = PushNotificationService.LANDING_MISS_STREAK_TO_LEARN + 1,
                total = PushNotificationService.DROP_DETECT_MIN_TOTAL
            )
        )
        assertTrue(
            PushNotificationService.shouldRecalibrate(missStreakAfterThisMiss = 100, total = 999)
        )
    }
}
