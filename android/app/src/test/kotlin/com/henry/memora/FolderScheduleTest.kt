package com.henry.memora

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FolderScheduleTest {

    // ─────────────────────────────────────────────────────────
    // resolve() — 하루 전체 커버리지
    // ─────────────────────────────────────────────────────────

    /**
     * 하루를 정확히 4등분(끝 슬롯은 자정 넘김 end=0으로 wrap)해서 1440분 전부를 쓸어본다.
     * 슬롯 경계 어디서도 base로 새지 않고, 매 분이 정확히 하나의 폴더로만 해석돼야 한다.
     */
    @Test
    fun `exhaustive sweep over adjacent chain covering whole day`() {
        val slots = listOf(
            FolderSchedule.Slot(0, 360, 1),
            FolderSchedule.Slot(360, 720, 2),
            FolderSchedule.Slot(720, 1080, 3),
            FolderSchedule.Slot(1080, 0, 4) // 18:00~24:00, wrap 표현
        )
        val base = listOf(-999) // 슬롯 folderId(1~4)와 절대 겹치지 않는 sentinel

        for (minute in 0..1439) {
            val expected = when (minute) {
                in 0..359 -> 1
                in 360..719 -> 2
                in 720..1079 -> 3
                else -> 4 // 1080..1439
            }
            val resolved = FolderSchedule.resolve(minute, slots, base)
            assertEquals("minute=$minute", listOf(expected), resolved)
            assertNotEquals("minute=$minute should never fall back to base", base, resolved)
        }
    }

    @Test
    fun `adjacent boundary minute belongs only to the later slot`() {
        val slots = listOf(
            FolderSchedule.Slot(540, 1080, 3),
            FolderSchedule.Slot(1080, 1380, 7)
        )
        assertEquals(listOf(7), FolderSchedule.resolve(1080, slots, emptyList()))
        assertEquals(listOf(3), FolderSchedule.resolve(1079, slots, emptyList()))
    }

    @Test
    fun `midnight wrap slot matches across the boundary and not just after it`() {
        val slots = listOf(FolderSchedule.Slot(1320, 120, 9))
        assertEquals(listOf(9), FolderSchedule.resolve(1320, slots, emptyList()))
        assertEquals(listOf(9), FolderSchedule.resolve(1439, slots, emptyList()))
        assertEquals(listOf(9), FolderSchedule.resolve(0, slots, emptyList()))
        assertEquals(listOf(9), FolderSchedule.resolve(119, slots, emptyList()))
        assertEquals(emptyList<Int>(), FolderSchedule.resolve(120, slots, emptyList()))
        assertEquals(emptyList<Int>(), FolderSchedule.resolve(700, slots, emptyList()))
    }

    @Test
    fun `wrap slot with end equal to zero means exactly midnight, not covering minute zero`() {
        // 22:00-24:00 == [1320, 0)
        val slots = listOf(FolderSchedule.Slot(1320, 0, 9))
        for (minute in 1320..1439) {
            assertEquals("minute=$minute", listOf(9), FolderSchedule.resolve(minute, slots, emptyList()))
        }
        assertEquals(emptyList<Int>(), FolderSchedule.resolve(0, slots, emptyList()))
    }

    @Test
    fun `uncovered time falls back to base folder unchanged`() {
        val slots = listOf(FolderSchedule.Slot(540, 600, 3))
        val base = listOf(5, 6)
        assertEquals(base, FolderSchedule.resolve(100, slots, base))
        // base가 빈 리스트여도 그대로(변형 없이) 반환돼야 한다
        assertEquals(emptyList<Int>(), FolderSchedule.resolve(100, slots, emptyList()))
    }

    @Test
    fun `overlapping slots resolve to the earlier start (documented tie-break)`() {
        // parse가 start 오름차순 정렬을 보장하므로, CSV 경유로 만들어 순서를 검증한다.
        val slots = FolderSchedule.parse("540:1080:3,600:700:4")
        assertEquals(listOf(3), FolderSchedule.resolve(650, slots, emptyList()))
    }

    /**
     * DST spring-forward 등가 시나리오: 벽시계가 02:00~03:00을 건너뛰는 날에도 이 함수는
     * "그 시각이 실제로 왔는지"를 모른다 — 그냥 nowMinutes만 본다. 그래서 150분(02:30)이
     * 절대 관측되지 않는 날엔 슬롯이 절대 안 켜지는 게 맞는 동작이다(버그 아님). 여기서는
     * 그 wall-clock 의미론만 확인한다: 60분과 180분(경계 포함 여부)은 base, 150분만 슬롯.
     */
    @Test
    fun `DST spring-forward equivalent - skipped hour is correct, not a bug`() {
        val slots = listOf(FolderSchedule.Slot(120, 180, 42))
        val base = listOf(-1)
        assertEquals(base, FolderSchedule.resolve(60, slots, base))
        assertEquals(listOf(42), FolderSchedule.resolve(150, slots, base))
        assertEquals(base, FolderSchedule.resolve(180, slots, base)) // end 배타적
    }

    // ─────────────────────────────────────────────────────────
    // slotContains() 직접 검증 — resolve 뒤에 숨어 회귀를 놓치지 않도록
    // ─────────────────────────────────────────────────────────

    @Test
    fun `slotContains same-day half-open interval`() {
        assertTrue(FolderSchedule.slotContains(540, 600, 540))
        assertTrue(FolderSchedule.slotContains(540, 600, 599))
        assertFalse(FolderSchedule.slotContains(540, 600, 600))
        assertFalse(FolderSchedule.slotContains(540, 600, 539))
    }

    @Test
    fun `slotContains start equal end always false`() {
        assertFalse(FolderSchedule.slotContains(540, 540, 540))
        assertFalse(FolderSchedule.slotContains(0, 0, 0))
    }

    // ─────────────────────────────────────────────────────────
    // parse() drop rules — 각각 개별 검증
    // ─────────────────────────────────────────────────────────

    @Test
    fun `parse drops start equal end`() {
        assertEquals(emptyList<FolderSchedule.Slot>(), FolderSchedule.parse("540:540:3"))
    }

    @Test
    fun `parse drops start below range`() {
        assertEquals(emptyList<FolderSchedule.Slot>(), FolderSchedule.parse("-1:600:3"))
    }

    @Test
    fun `parse drops end at or above 1440`() {
        assertEquals(emptyList<FolderSchedule.Slot>(), FolderSchedule.parse("600:1440:3"))
    }

    @Test
    fun `parse drops negative folderId`() {
        assertEquals(emptyList<FolderSchedule.Slot>(), FolderSchedule.parse("540:600:-1"))
    }

    @Test
    fun `parse drops non-numeric parts`() {
        assertEquals(emptyList<FolderSchedule.Slot>(), FolderSchedule.parse("abc:600:3"))
        assertEquals(emptyList<FolderSchedule.Slot>(), FolderSchedule.parse("540:xyz:3"))
        assertEquals(emptyList<FolderSchedule.Slot>(), FolderSchedule.parse("540:600:xyz"))
    }

    @Test
    fun `parse drops tokens with two parts`() {
        assertEquals(emptyList<FolderSchedule.Slot>(), FolderSchedule.parse("540:600"))
    }

    @Test
    fun `parse drops tokens with four parts`() {
        assertEquals(emptyList<FolderSchedule.Slot>(), FolderSchedule.parse("540:600:3:7"))
    }

    @Test
    fun `parse ignores trailing comma`() {
        assertEquals(listOf(FolderSchedule.Slot(540, 600, 3)), FolderSchedule.parse("540:600:3,"))
    }

    @Test
    fun `parse of blank string is empty list`() {
        assertEquals(emptyList<FolderSchedule.Slot>(), FolderSchedule.parse(""))
        assertEquals(emptyList<FolderSchedule.Slot>(), FolderSchedule.parse("   "))
    }

    @Test
    fun `parse of null is empty list`() {
        assertEquals(emptyList<FolderSchedule.Slot>(), FolderSchedule.parse(null))
    }

    @Test
    fun `parse accepts whitespace around numbers`() {
        assertEquals(listOf(FolderSchedule.Slot(540, 600, 3)), FolderSchedule.parse(" 540 : 600 : 3 "))
    }

    @Test
    fun `parse caps at MAX_SLOTS keeping earliest starts`() {
        // 60개(0,20,...,1180 시작)를 만들어 상한(50) 초과분이 잘리는지, 남는 게 "가장 이른
        // 시작 50개"인지 확인한다.
        val tokens = (0 until 60).map { i -> "${i * 20}:${i * 20 + 10}:$i" }
        val csv = tokens.joinToString(",")
        val result = FolderSchedule.parse(csv)
        assertEquals(FolderSchedule.MAX_SLOTS, result.size)
        assertEquals((0 until 50).map { it * 20 }, result.map { it.start })
        assertEquals((0 until 50).toList(), result.map { it.folderId })
    }

    @Test
    fun `parse never throws on a batch of garbage inputs`() {
        val garbage = listOf(
            "abc",
            "1:2",
            "1:2:3:4",
            ":::",
            "999999:1:2",
            "1:999999:2",
            "5:5:1",
            "5:6:-1",
            ",,,",
            "1:2:a",
            "a:b:c",
            "1: :3",
            "1:2:",
            ":2:3",
            "",
            "   ",
            "1:2:3,",
            ",1:2:3",
            "1:2:3,,4:5:6",
            "1:2:3:",
            "::",
            "1",
            "1:",
            "-1:-1:-1",
            "1440:0:1",
            "0:1440:1",
            "540:600:3\n",
            "🎉:1:2",
            null
        )
        for (input in garbage) {
            // 던지지 않는다는 것 자체가 검증 대상. 결과가 null이 아니라는 것도 확인.
            val result = FolderSchedule.parse(input)
            assertTrue(result.size >= 0)
        }
    }

    // ─────────────────────────────────────────────────────────
    // encode/parse round-trip
    // ─────────────────────────────────────────────────────────

    @Test
    fun `encode then parse round-trips a representative slot list`() {
        // 이미 start 오름차순으로 준 리스트 — parse의 정렬이 순서를 바꾸지 않아야 원본과
        // 정확히 일치한다.
        val original = listOf(
            FolderSchedule.Slot(0, 60, 1),
            FolderSchedule.Slot(540, 1080, 3),
            FolderSchedule.Slot(1320, 120, 9)
        )
        val csv = FolderSchedule.encode(original)
        assertEquals("0:60:1,540:1080:3,1320:120:9", csv)
        val roundTripped = FolderSchedule.parse(csv)
        assertEquals(original, roundTripped)
    }

    @Test
    fun `encode of empty list is empty string and parses back to empty list`() {
        assertEquals("", FolderSchedule.encode(emptyList()))
        assertEquals(emptyList<FolderSchedule.Slot>(), FolderSchedule.parse(FolderSchedule.encode(emptyList())))
    }
}
