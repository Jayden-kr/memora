package com.henry.memora

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PushNotificationService.Companion의 순수 로직(recentCardIds 파싱/인코딩 +
 * 직전 카드 재출현 방지 가드 판정) 유닛테스트. 두 함수 다 Android API 의존성이
 * 없어 Service 인스턴스 없이 JVM에서 바로 검증 가능하다.
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
        // 최근 5개를 기억하는데 폴더에 카드가 딱 6개(recentSize+1)뿐이면 제외 조건을
        // 걸면 0건이 나올 수 있다 — 걸면 안 된다.
        assertFalse(PushNotificationService.shouldExcludeRecentCards(totalCount = 6, recentSize = 5))
        // 더 적어도(카드 <= 최근개수) 당연히 걸면 안 된다.
        assertFalse(PushNotificationService.shouldExcludeRecentCards(totalCount = 3, recentSize = 5))
        assertFalse(PushNotificationService.shouldExcludeRecentCards(totalCount = 0, recentSize = 5))
    }

    @Test
    fun `guard blocks exclusion when there is no recent history to exclude`() {
        // recentSize==0(처음 발화, 또는 prefs가 비어있음)이면 제외 조건 자체가 무의미하다.
        assertFalse(PushNotificationService.shouldExcludeRecentCards(totalCount = 100, recentSize = 0))
    }

    @Test
    fun `guard boundary — exactly recentSize plus one is still blocked`() {
        assertFalse(PushNotificationService.shouldExcludeRecentCards(totalCount = 6, recentSize = 5))
    }

    @Test
    fun `guard boundary — one more than recentSize plus one is allowed`() {
        assertTrue(PushNotificationService.shouldExcludeRecentCards(totalCount = 7, recentSize = 5))
    }
}
