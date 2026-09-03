package com.henry.memora

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

class PushScheduleTest {

    // ─────────────────────────────────────────────────────────
    // parse() drop rules — 각각 개별 검증
    // ─────────────────────────────────────────────────────────

    @Test
    fun `parse drops start equal end`() {
        assertEquals(emptyList<PushSchedule.Slot>(), PushSchedule.parse("540:540:3:10"))
    }

    @Test
    fun `parse drops start below range`() {
        assertEquals(emptyList<PushSchedule.Slot>(), PushSchedule.parse("-1:600:3:10"))
    }

    @Test
    fun `parse drops end at or above 1440`() {
        assertEquals(emptyList<PushSchedule.Slot>(), PushSchedule.parse("600:1440:3:10"))
    }

    @Test
    fun `parse drops negative folderId`() {
        assertEquals(emptyList<PushSchedule.Slot>(), PushSchedule.parse("540:600:-1:10"))
    }

    @Test
    fun `parse drops non-numeric start end or folderId`() {
        assertEquals(emptyList<PushSchedule.Slot>(), PushSchedule.parse("abc:600:3:10"))
        assertEquals(emptyList<PushSchedule.Slot>(), PushSchedule.parse("540:xyz:3:10"))
        assertEquals(emptyList<PushSchedule.Slot>(), PushSchedule.parse("540:600:xyz:10"))
    }

    @Test
    fun `parse drops tokens with two parts`() {
        assertEquals(emptyList<PushSchedule.Slot>(), PushSchedule.parse("540:600"))
    }

    @Test
    fun `parse drops tokens with five parts`() {
        assertEquals(emptyList<PushSchedule.Slot>(), PushSchedule.parse("540:600:3:10:99"))
    }

    @Test
    fun `parse ignores trailing comma`() {
        assertEquals(
            listOf(PushSchedule.Slot(540, 600, 3, 10)),
            PushSchedule.parse("540:600:3:10,")
        )
    }

    @Test
    fun `parse of blank string is empty list`() {
        assertEquals(emptyList<PushSchedule.Slot>(), PushSchedule.parse(""))
        assertEquals(emptyList<PushSchedule.Slot>(), PushSchedule.parse("   "))
    }

    @Test
    fun `parse of null is empty list`() {
        assertEquals(emptyList<PushSchedule.Slot>(), PushSchedule.parse(null))
    }

    @Test
    fun `parse accepts whitespace around numbers`() {
        assertEquals(
            listOf(PushSchedule.Slot(540, 600, 3, 10)),
            PushSchedule.parse(" 540 : 600 : 3 : 10 ")
        )
    }

    // ─────────────────────────────────────────────────────────
    // 3필드 관대 수용 + 잘못된 interval 강등(드롭 아님)
    // ─────────────────────────────────────────────────────────

    @Test
    fun `three-field token omitting interval is accepted with INHERIT`() {
        assertEquals(
            listOf(PushSchedule.Slot(540, 600, 3, PushSchedule.INHERIT)),
            PushSchedule.parse("540:600:3")
        )
        assertEquals(0, PushSchedule.INHERIT)
    }

    @Test
    fun `interval below 5 degrades to INHERIT instead of dropping the whole slot`() {
        val result = PushSchedule.parse("540:600:3:4")
        assertEquals(listOf(PushSchedule.Slot(540, 600, 3, PushSchedule.INHERIT)), result)
    }

    @Test
    fun `interval above 1440 degrades to INHERIT instead of dropping the whole slot`() {
        val result = PushSchedule.parse("540:600:3:1441")
        assertEquals(listOf(PushSchedule.Slot(540, 600, 3, PushSchedule.INHERIT)), result)
    }

    @Test
    fun `negative interval degrades to INHERIT instead of dropping the whole slot`() {
        val result = PushSchedule.parse("540:600:3:-5")
        assertEquals(listOf(PushSchedule.Slot(540, 600, 3, PushSchedule.INHERIT)), result)
    }

    @Test
    fun `non-numeric interval degrades to INHERIT instead of dropping the whole slot`() {
        val result = PushSchedule.parse("540:600:3:abc")
        assertEquals(listOf(PushSchedule.Slot(540, 600, 3, PushSchedule.INHERIT)), result)
    }

    @Test
    fun `interval boundaries 5 and 1440 are valid (inclusive)`() {
        assertEquals(5, PushSchedule.parse("540:600:3:5").single().intervalMin)
        assertEquals(1440, PushSchedule.parse("540:600:3:1440").single().intervalMin)
    }

    // ─────────────────────────────────────────────────────────
    // MAX_SLOTS = 5 초과 컷
    // ─────────────────────────────────────────────────────────

    @Test
    fun `parse caps at MAX_SLOTS keeping earliest starts`() {
        assertEquals(5, PushSchedule.MAX_SLOTS)
        // 10개(0,100,...,900 시작)를 만들어 상한(5) 초과분이 잘리는지, 남는 게
        // "가장 이른 시작 5개"인지 확인한다.
        val tokens = (0 until 10).map { i -> "${i * 100}:${i * 100 + 10}:$i:10" }
        val csv = tokens.joinToString(",")
        val result = PushSchedule.parse(csv)
        assertEquals(PushSchedule.MAX_SLOTS, result.size)
        assertEquals((0 until 5).map { it * 100 }, result.map { it.start })
        assertEquals((0 until 5).toList(), result.map { it.folderId })
    }

    // ─────────────────────────────────────────────────────────
    // never throws
    // ─────────────────────────────────────────────────────────

    @Test
    fun `parse never throws on a batch of garbage inputs`() {
        val garbage = listOf(
            "abc",
            "1:2",
            "1:2:3:4:5",
            ":::",
            "999999:1:2:10",
            "1:999999:2:10",
            "5:5:1:10",
            "5:6:-1:10",
            ",,,",
            "1:2:a:10",
            "a:b:c:d",
            "1: :3:10",
            "1:2::10",
            ":2:3:10",
            "",
            "   ",
            "1:2:3,",
            ",1:2:3",
            "1:2:3,,4:5:6",
            "1:2:3:",
            "::",
            "1",
            "1:",
            "-1:-1:-1:-1",
            "1440:0:1:10",
            "0:1440:1:10",
            "540:600:3:10\n",
            "🎉:1:2:10",
            null
        )
        for (input in garbage) {
            val result = PushSchedule.parse(input)
            assertTrue(result.size >= 0)
        }
    }

    // ─────────────────────────────────────────────────────────
    // encode/parse round-trip
    // ─────────────────────────────────────────────────────────

    @Test
    fun `encode then parse round-trips a representative slot list`() {
        val original = listOf(
            PushSchedule.Slot(0, 60, 1, PushSchedule.INHERIT),
            PushSchedule.Slot(540, 1080, 3, 15),
            PushSchedule.Slot(1320, 120, 9, 60)
        )
        val csv = PushSchedule.encode(original)
        assertEquals("0:60:1:0,540:1080:3:15,1320:120:9:60", csv)
        val roundTripped = PushSchedule.parse(csv)
        assertEquals(original, roundTripped)
    }

    @Test
    fun `encode always writes four fields even for INHERIT`() {
        assertEquals("540:600:3:0", PushSchedule.encode(listOf(PushSchedule.Slot(540, 600, 3, 0))))
    }

    @Test
    fun `encode of empty list is empty string and parses back to empty list`() {
        assertEquals("", PushSchedule.encode(emptyList()))
        assertEquals(emptyList<PushSchedule.Slot>(), PushSchedule.parse(PushSchedule.encode(emptyList())))
    }

    @Test
    fun `encode parse round trip is idempotent under repeated application`() {
        val randomSlots = (0 until 5).map {
            PushSchedule.Slot(it * 200, it * 200 + 100, it, if (it % 2 == 0) PushSchedule.INHERIT else 20)
        }
        val once = PushSchedule.parse(PushSchedule.encode(randomSlots))
        val twice = PushSchedule.parse(PushSchedule.encode(once))
        assertEquals(once, twice)
    }

    // ─────────────────────────────────────────────────────────
    // activeSlot — 1440분 전수 스윕
    // ─────────────────────────────────────────────────────────

    @Test
    fun `activeSlot exhaustive sweep over adjacent chain covering whole day`() {
        val slots = listOf(
            PushSchedule.Slot(0, 360, 1, 10),
            PushSchedule.Slot(360, 720, 2, 20),
            PushSchedule.Slot(720, 1080, 3, 30),
            PushSchedule.Slot(1080, 0, 4, 40) // 18:00~24:00, wrap 표현
        )
        for (minute in 0..1439) {
            val expected = when (minute) {
                in 0..359 -> 1
                in 360..719 -> 2
                in 720..1079 -> 3
                else -> 4
            }
            val slot = PushSchedule.activeSlot(minute, slots)
            assertNotNull("minute=$minute", slot)
            assertEquals("minute=$minute", expected, slot!!.folderId)
        }
    }

    @Test
    fun `activeSlot adjacent boundary minute belongs only to the later slot`() {
        val slots = listOf(
            PushSchedule.Slot(540, 1080, 3, 10),
            PushSchedule.Slot(1080, 1380, 7, 20)
        )
        assertEquals(7, PushSchedule.activeSlot(1080, slots)!!.folderId)
        assertEquals(3, PushSchedule.activeSlot(1079, slots)!!.folderId)
    }

    @Test
    fun `activeSlot midnight wrap slot matches across the boundary`() {
        val slots = listOf(PushSchedule.Slot(1320, 120, 9, 10))
        assertEquals(9, PushSchedule.activeSlot(1320, slots)!!.folderId)
        assertEquals(9, PushSchedule.activeSlot(1439, slots)!!.folderId)
        assertEquals(9, PushSchedule.activeSlot(0, slots)!!.folderId)
        assertEquals(9, PushSchedule.activeSlot(119, slots)!!.folderId)
        assertNull(PushSchedule.activeSlot(120, slots))
        assertNull(PushSchedule.activeSlot(700, slots))
    }

    @Test
    fun `activeSlot overlapping slots resolve to the earlier start (documented tie-break)`() {
        val slots = PushSchedule.parse("540:1080:3:10,600:700:4:20")
        assertEquals(3, PushSchedule.activeSlot(650, slots)!!.folderId)
    }

    // ─────────────────────────────────────────────────────────
    // 대조 프로퍼티: activeSlot 매칭이 FolderSchedule.slotContains와 100% 일치
    // 위임이 끊기면(=누군가 slotContains를 복제/변형하면) 즉시 감지된다.
    // ─────────────────────────────────────────────────────────

    @Test
    fun `activeSlot matching is a perfect cross-check against FolderSchedule slotContains`() {
        val rand = Random(1234)
        repeat(20) {
            val slots = (0 until 5).map {
                PushSchedule.Slot(
                    rand.nextInt(1440),
                    rand.nextInt(1440),
                    it,
                    PushSchedule.INHERIT
                )
            }.filter { it.start != it.end } // parse가 이미 걸러내는 값과 동일하게 방어
            for (minute in 0..1439) {
                val expectedIndex = slots.indexOfFirst {
                    FolderSchedule.slotContains(it.start, it.end, minute)
                }
                val expected = if (expectedIndex >= 0) slots[expectedIndex] else null
                val actual = PushSchedule.activeSlot(minute, slots)
                assertEquals("minute=$minute slots=$slots", expected, actual)
            }
        }
    }

    // ─────────────────────────────────────────────────────────
    // resolveFolderId / resolveIntervalMin
    // ─────────────────────────────────────────────────────────

    @Test
    fun `resolveFolderId returns matched slot folderId when matched`() {
        val slots = listOf(PushSchedule.Slot(540, 600, 7, 10))
        assertEquals(7, PushSchedule.resolveFolderId(550, slots, 99))
    }

    @Test
    fun `resolveFolderId returns base folderId unchanged when no match`() {
        val slots = listOf(PushSchedule.Slot(540, 600, 7, 10))
        assertEquals(99, PushSchedule.resolveFolderId(100, slots, 99))
        assertNull(PushSchedule.resolveFolderId(100, slots, null))
    }

    @Test
    fun `resolveIntervalMin returns matched slot interval when matched and not INHERIT`() {
        val slots = listOf(PushSchedule.Slot(540, 600, 7, 15))
        assertEquals(15, PushSchedule.resolveIntervalMin(550, slots, 30))
    }

    @Test
    fun `resolveIntervalMin falls back to base when matched slot is INHERIT`() {
        val slots = listOf(PushSchedule.Slot(540, 600, 7, PushSchedule.INHERIT))
        assertEquals(30, PushSchedule.resolveIntervalMin(550, slots, 30))
    }

    @Test
    fun `resolveIntervalMin returns base unchanged when no match`() {
        val slots = listOf(PushSchedule.Slot(540, 600, 7, 15))
        assertEquals(30, PushSchedule.resolveIntervalMin(100, slots, 30))
    }

    @Test
    fun `resolveFolderId and resolveIntervalMin agree on overlap tie-break`() {
        val slots = PushSchedule.parse("540:1080:3:15,600:700:4:20")
        assertEquals(3, PushSchedule.resolveFolderId(650, slots, -1))
        assertEquals(15, PushSchedule.resolveIntervalMin(650, slots, 30))
    }

    // ─────────────────────────────────────────────────────────
    // 자정 랩 양쪽 경계 매치
    // ─────────────────────────────────────────────────────────

    @Test
    fun `midnight wrap slot matches both boundary minutes 1439 and 0`() {
        val slots = listOf(PushSchedule.Slot(1439, 1, 5, 10))
        assertEquals(5, PushSchedule.activeSlot(1439, slots)!!.folderId)
        assertEquals(5, PushSchedule.activeSlot(0, slots)!!.folderId)
        assertNull(PushSchedule.activeSlot(1, slots))
    }
}
