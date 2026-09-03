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
        assertEquals(emptyList<PushSchedule.Rule>(), PushSchedule.parse("540:540:3:10"))
    }

    @Test
    fun `parse drops start below range`() {
        assertEquals(emptyList<PushSchedule.Rule>(), PushSchedule.parse("-1:600:3:10"))
    }

    @Test
    fun `parse drops end at or above 1440`() {
        assertEquals(emptyList<PushSchedule.Rule>(), PushSchedule.parse("600:1440:3:10"))
    }

    @Test
    fun `parse drops folderId below negative one`() {
        assertEquals(emptyList<PushSchedule.Rule>(), PushSchedule.parse("540:600:-2:10"))
    }

    @Test
    fun `parse accepts folderId of negative one as all-folders sentinel`() {
        val result = PushSchedule.parse("540:600:-1:10")
        assertEquals(listOf(PushSchedule.Rule(540, 600, PushSchedule.ALL_FOLDERS, 10)), result)
        assertEquals(-1, PushSchedule.ALL_FOLDERS)
    }

    @Test
    fun `parse drops non-numeric start end or folderId`() {
        assertEquals(emptyList<PushSchedule.Rule>(), PushSchedule.parse("abc:600:3:10"))
        assertEquals(emptyList<PushSchedule.Rule>(), PushSchedule.parse("540:xyz:3:10"))
        assertEquals(emptyList<PushSchedule.Rule>(), PushSchedule.parse("540:600:xyz:10"))
    }

    @Test
    fun `parse drops tokens with two parts`() {
        assertEquals(emptyList<PushSchedule.Rule>(), PushSchedule.parse("540:600"))
    }

    @Test
    fun `parse drops tokens with five parts`() {
        assertEquals(emptyList<PushSchedule.Rule>(), PushSchedule.parse("540:600:3:10:99"))
    }

    @Test
    fun `parse ignores trailing comma`() {
        assertEquals(
            listOf(PushSchedule.Rule(540, 600, 3, 10)),
            PushSchedule.parse("540:600:3:10,")
        )
    }

    @Test
    fun `parse of blank string is empty list`() {
        assertEquals(emptyList<PushSchedule.Rule>(), PushSchedule.parse(""))
        assertEquals(emptyList<PushSchedule.Rule>(), PushSchedule.parse("   "))
    }

    @Test
    fun `parse of null is empty list`() {
        assertEquals(emptyList<PushSchedule.Rule>(), PushSchedule.parse(null))
    }

    @Test
    fun `parse accepts whitespace around numbers`() {
        assertEquals(
            listOf(PushSchedule.Rule(540, 600, 3, 10)),
            PushSchedule.parse(" 540 : 600 : 3 : 10 ")
        )
    }

    // ─────────────────────────────────────────────────────────
    // 3필드 관대 수용 + 잘못된 interval 강등(드롭 아님, DEFAULT_INTERVAL_MIN=30)
    // ─────────────────────────────────────────────────────────

    @Test
    fun `three-field token omitting interval is accepted with DEFAULT_INTERVAL_MIN`() {
        assertEquals(
            listOf(PushSchedule.Rule(540, 600, 3, PushSchedule.DEFAULT_INTERVAL_MIN)),
            PushSchedule.parse("540:600:3")
        )
        assertEquals(30, PushSchedule.DEFAULT_INTERVAL_MIN)
    }

    @Test
    fun `interval of zero degrades to DEFAULT_INTERVAL_MIN instead of dropping the whole rule`() {
        val result = PushSchedule.parse("540:600:3:0")
        assertEquals(listOf(PushSchedule.Rule(540, 600, 3, PushSchedule.DEFAULT_INTERVAL_MIN)), result)
    }

    @Test
    fun `interval below 5 degrades to DEFAULT_INTERVAL_MIN instead of dropping the whole rule`() {
        val result = PushSchedule.parse("540:600:3:4")
        assertEquals(listOf(PushSchedule.Rule(540, 600, 3, PushSchedule.DEFAULT_INTERVAL_MIN)), result)
    }

    @Test
    fun `interval above 1440 degrades to DEFAULT_INTERVAL_MIN instead of dropping the whole rule`() {
        val result = PushSchedule.parse("540:600:3:1441")
        assertEquals(listOf(PushSchedule.Rule(540, 600, 3, PushSchedule.DEFAULT_INTERVAL_MIN)), result)
    }

    @Test
    fun `negative interval degrades to DEFAULT_INTERVAL_MIN instead of dropping the whole rule`() {
        val result = PushSchedule.parse("540:600:3:-5")
        assertEquals(listOf(PushSchedule.Rule(540, 600, 3, PushSchedule.DEFAULT_INTERVAL_MIN)), result)
    }

    @Test
    fun `non-numeric interval degrades to DEFAULT_INTERVAL_MIN instead of dropping the whole rule`() {
        val result = PushSchedule.parse("540:600:3:abc")
        assertEquals(listOf(PushSchedule.Rule(540, 600, 3, PushSchedule.DEFAULT_INTERVAL_MIN)), result)
    }

    @Test
    fun `interval boundaries 5 and 1440 are valid (inclusive)`() {
        assertEquals(5, PushSchedule.parse("540:600:3:5").single().intervalMin)
        assertEquals(1440, PushSchedule.parse("540:600:3:1440").single().intervalMin)
    }

    // ─────────────────────────────────────────────────────────
    // MAX_RULES = 12 초과 컷
    // ─────────────────────────────────────────────────────────

    @Test
    fun `parse caps at MAX_RULES keeping earliest starts`() {
        assertEquals(12, PushSchedule.MAX_RULES)
        // 20개(0,100,...,1900 시작... 실제로는 1439 이내로 clamp)를 만들어 상한(12)
        // 초과분이 잘리는지, 남는 게 "가장 이른 시작 12개"인지 확인한다.
        val tokens = (0 until 20).map { i -> "${i * 60}:${i * 60 + 10}:$i:10" }
        val csv = tokens.joinToString(",")
        val result = PushSchedule.parse(csv)
        assertEquals(PushSchedule.MAX_RULES, result.size)
        assertEquals((0 until 12).map { it * 60 }, result.map { it.start })
        assertEquals((0 until 12).toList(), result.map { it.folderId })
    }

    @Test
    fun `12 rules covering the whole day round-trip without loss (worst-case CSV byte length sanity)`() {
        // 최악 케이스: 큰 자릿수(folderId 99999, interval 1440)를 12개 채워 넣어도
        // 손실 없이 라운드트립되는지 — SharedPreferences/TEXT 컬럼 한계와 무관함을
        // 확인하는 목적(바이트 길이 자체는 이 테스트가 검증하지 않지만, 파싱 손실
        // 여부는 검증한다).
        val tokens = (0 until 12).map { i -> "${i * 100}:${i * 100 + 90}:99999:1440" }
        val csv = tokens.joinToString(",")
        val once = PushSchedule.parse(csv)
        assertEquals(12, once.size)
        val encoded = PushSchedule.encode(once)
        val twice = PushSchedule.parse(encoded)
        assertEquals(once, twice)
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
            "5:6:-2:10",
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
    fun `encode then parse round-trips a representative rule list`() {
        val original = listOf(
            PushSchedule.Rule(0, 60, 1, 30),
            PushSchedule.Rule(540, 1080, 3, 15),
            PushSchedule.Rule(1320, 120, PushSchedule.ALL_FOLDERS, 60)
        )
        val csv = PushSchedule.encode(original)
        assertEquals("0:60:1:30,540:1080:3:15,1320:120:-1:60", csv)
        val roundTripped = PushSchedule.parse(csv)
        assertEquals(original, roundTripped)
    }

    @Test
    fun `encode always writes four fields`() {
        assertEquals("540:600:3:30", PushSchedule.encode(listOf(PushSchedule.Rule(540, 600, 3, 30))))
    }

    @Test
    fun `encode of empty list is empty string and parses back to empty list`() {
        assertEquals("", PushSchedule.encode(emptyList()))
        assertEquals(emptyList<PushSchedule.Rule>(), PushSchedule.parse(PushSchedule.encode(emptyList())))
    }

    @Test
    fun `encode parse round trip is idempotent under repeated application`() {
        val randomRules = (0 until 5).map {
            PushSchedule.Rule(it * 200, it * 200 + 100, it, if (it % 2 == 0) 20 else 45)
        }
        val once = PushSchedule.parse(PushSchedule.encode(randomRules))
        val twice = PushSchedule.parse(PushSchedule.encode(once))
        assertEquals(once, twice)
    }

    // ─────────────────────────────────────────────────────────
    // activeRule — 1440분 전수 스윕
    // ─────────────────────────────────────────────────────────

    @Test
    fun `activeRule exhaustive sweep over adjacent chain covering whole day`() {
        val rules = listOf(
            PushSchedule.Rule(0, 360, 1, 10),
            PushSchedule.Rule(360, 720, 2, 20),
            PushSchedule.Rule(720, 1080, 3, 30),
            PushSchedule.Rule(1080, 0, 4, 40) // 18:00~24:00, wrap 표현
        )
        for (minute in 0..1439) {
            val expected = when (minute) {
                in 0..359 -> 1
                in 360..719 -> 2
                in 720..1079 -> 3
                else -> 4
            }
            val rule = PushSchedule.activeRule(minute, rules)
            assertNotNull("minute=$minute", rule)
            assertEquals("minute=$minute", expected, rule!!.folderId)
        }
    }

    @Test
    fun `activeRule adjacent boundary minute belongs only to the later rule`() {
        val rules = listOf(
            PushSchedule.Rule(540, 1080, 3, 10),
            PushSchedule.Rule(1080, 1380, 7, 20)
        )
        assertEquals(7, PushSchedule.activeRule(1080, rules)!!.folderId)
        assertEquals(3, PushSchedule.activeRule(1079, rules)!!.folderId)
    }

    @Test
    fun `activeRule midnight wrap rule matches across the boundary`() {
        val rules = listOf(PushSchedule.Rule(1320, 120, 9, 10))
        assertEquals(9, PushSchedule.activeRule(1320, rules)!!.folderId)
        assertEquals(9, PushSchedule.activeRule(1439, rules)!!.folderId)
        assertEquals(9, PushSchedule.activeRule(0, rules)!!.folderId)
        assertEquals(9, PushSchedule.activeRule(119, rules)!!.folderId)
        assertNull(PushSchedule.activeRule(120, rules))
        assertNull(PushSchedule.activeRule(700, rules))
    }

    @Test
    fun `activeRule overlapping rules resolve to the earlier start (documented tie-break)`() {
        val rules = PushSchedule.parse("540:1080:3:10,600:700:4:20")
        assertEquals(3, PushSchedule.activeRule(650, rules)!!.folderId)
    }

    // ─────────────────────────────────────────────────────────
    // 대조 프로퍼티: activeRule 매칭이 FolderSchedule.slotContains와 100% 일치
    // 위임이 끊기면(=누군가 slotContains를 복제/변형하면) 즉시 감지된다.
    // ─────────────────────────────────────────────────────────

    @Test
    fun `activeRule matching is a perfect cross-check against FolderSchedule slotContains`() {
        val rand = Random(1234)
        repeat(20) {
            val rules = (0 until 5).map {
                PushSchedule.Rule(
                    rand.nextInt(1440),
                    rand.nextInt(1440),
                    it,
                    30
                )
            }.filter { it.start != it.end } // parse가 이미 걸러내는 값과 동일하게 방어
            for (minute in 0..1439) {
                val expectedIndex = rules.indexOfFirst {
                    FolderSchedule.slotContains(it.start, it.end, minute)
                }
                val expected = if (expectedIndex >= 0) rules[expectedIndex] else null
                val actual = PushSchedule.activeRule(minute, rules)
                assertEquals("minute=$minute rules=$rules", expected, actual)
            }
        }
    }

    // ─────────────────────────────────────────────────────────
    // 자정 랩 양쪽 경계 매치
    // ─────────────────────────────────────────────────────────

    @Test
    fun `midnight wrap rule matches both boundary minutes 1439 and 0`() {
        val rules = listOf(PushSchedule.Rule(1439, 1, 5, 10))
        assertEquals(5, PushSchedule.activeRule(1439, rules)!!.folderId)
        assertEquals(5, PushSchedule.activeRule(0, rules)!!.folderId)
        assertNull(PushSchedule.activeRule(1, rules))
    }

    // ─────────────────────────────────────────────────────────
    // minutesUntilNextStart
    // ─────────────────────────────────────────────────────────

    @Test
    fun `minutesUntilNextStart is 1440 when there are no rules`() {
        assertEquals(1440, PushSchedule.minutesUntilNextStart(0, emptyList()))
        assertEquals(1440, PushSchedule.minutesUntilNextStart(900, emptyList()))
    }

    @Test
    fun `minutesUntilNextStart is 1 when a rule covers the whole day (no gap ever)`() {
        // 여러 규칙이 이어 붙어 하루 전체를 커버하면, 다음 분도 항상 매치되므로 gap이 없다.
        val rules = listOf(
            PushSchedule.Rule(0, 720, 1, 10),
            PushSchedule.Rule(720, 0, 2, 10)
        )
        for (now in listOf(0, 359, 719, 1000, 1439)) {
            assertEquals("now=$now", 1, PushSchedule.minutesUntilNextStart(now, rules))
        }
    }

    @Test
    fun `minutesUntilNextStart finds the correct gap with multiple rules`() {
        // 09:00-10:00(540-600), 14:00-15:00(840-900). now=10:00 정각(600, gap 시작) →
        // 다음 활성 시작까지 240분(14:00).
        val rules = listOf(
            PushSchedule.Rule(540, 600, 1, 10),
            PushSchedule.Rule(840, 900, 2, 10)
        )
        assertEquals(240, PushSchedule.minutesUntilNextStart(600, rules))
        // 두 규칙 사이의 gap 한복판(10:05)에서도 다음 규칙(14:00)까지 정확히 계산돼야 한다.
        assertEquals(235, PushSchedule.minutesUntilNextStart(605, rules))
    }

    @Test
    fun `minutesUntilNextStart handles midnight-crossing rule correctly`() {
        // 22:00~06:00(1320~360) 하나만 있는 경우, 06:00~22:00 구간의 모든 now에서
        // 정확한 거리(22:00까지)를 반환해야 한다.
        val rules = listOf(PushSchedule.Rule(1320, 360, 1, 10))
        assertEquals(1320 - 360, PushSchedule.minutesUntilNextStart(360, rules)) // 06:00 → 22:00
        assertEquals(1, PushSchedule.minutesUntilNextStart(1319, rules)) // 21:59 → 22:00
        // now가 이미 활성 구간 안(22:01)이면 함수는 "현재 상태"를 신경쓰지 않고 그냥
        // now+1부터 스캔하므로, 다음 분도 여전히 커버되는 한 1을 반환한다(호출부는 이미
        // activeRule(now)!=null인 분기에서는 이 함수를 쓰지 않는다 — TICK의 else 분기,
        // 즉 activeRule(now)==null일 때만 호출된다).
        assertEquals(1, PushSchedule.minutesUntilNextStart(1320, rules))
    }

    @Test
    fun `minutesUntilNextStart exhaustive sweep matches activeRule null distance`() {
        val rand = Random(77)
        repeat(10) {
            val rules = (0 until 4).map {
                PushSchedule.Rule(rand.nextInt(1440), rand.nextInt(1440), it, 30)
            }.filter { it.start != it.end }
            for (now in 0..1439) {
                val distance = PushSchedule.minutesUntilNextStart(now, rules)
                if (PushSchedule.activeRule(now, rules) == null) {
                    // distance분 뒤가 실제로 첫 매치 지점이어야 한다(그 사이는 전부 매치 없음).
                    for (d in 1 until distance) {
                        val t = (now + d) % 1440
                        assertNull("rules=$rules now=$now d=$d", PushSchedule.activeRule(t, rules))
                    }
                    if (distance < 1440) {
                        val t = (now + distance) % 1440
                        assertNotNull("rules=$rules now=$now distance=$distance", PushSchedule.activeRule(t, rules))
                    }
                }
            }
        }
    }
}
