package com.henry.memora

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BgContrastTest {

    // ─────────────────────────────────────────────────────────
    // 회귀 기준: 오늘의 하드코딩 팔레트를 무너뜨리지 않는지
    // ─────────────────────────────────────────────────────────

    /**
     * ⚠️ 가장 중요한 테스트. 기본 배경색(0xFF1A1A2E)은 오늘 하드코딩된 다크
     * 팔레트(흰 텍스트)를 그대로 유지해야 한다 — 이 판정이 뒤집히면 기존 사용자
     * 전원의 잠금화면 텍스트 색이 조용히 검게 바뀐다.
     */
    @Test
    fun `default background 0xFF1A1A2E is dark palette`() {
        assertTrue(BgContrast.isDarkPalette(0xFF1A1A2E.toInt()))
    }

    /** lock_screen_settings.dart의 6개 프리셋도 전부 다크 배경 취지로 골라졌다. */
    @Test
    fun `all six built-in presets are dark palette`() {
        val presets = listOf(
            0xFF1A1A2E, 0xFF16213E, 0xFF0F3460,
            0xFF1A1A1A, 0xFF2D132C, 0xFF1B1B2F
        )
        for (preset in presets) {
            val presetInt = preset.toInt()
            assertTrue("preset=${Integer.toHexString(presetInt)}", BgContrast.isDarkPalette(presetInt))
        }
    }

    // ─────────────────────────────────────────────────────────
    // 극단값
    // ─────────────────────────────────────────────────────────

    @Test
    fun `pure black is dark palette`() {
        assertTrue(BgContrast.isDarkPalette(0xFF000000.toInt()))
        assertEquals(0.0, BgContrast.relativeLuminance(0xFF000000.toInt()), 1e-9)
    }

    @Test
    fun `pure white is not dark palette`() {
        assertFalse(BgContrast.isDarkPalette(0xFFFFFFFF.toInt()))
        assertEquals(1.0, BgContrast.relativeLuminance(0xFFFFFFFF.toInt()), 1e-9)
    }

    // ─────────────────────────────────────────────────────────
    // 실사용 예시 — 밝은 커스텀 배경
    // ─────────────────────────────────────────────────────────

    @Test
    fun `light custom background (F5F5F0) is not dark palette`() {
        assertFalse(BgContrast.isDarkPalette(0xFFF5F5F0.toInt()))
    }

    // ─────────────────────────────────────────────────────────
    // 경계값 — LUMINANCE_THRESHOLD(0.55) 바로 위/아래의 무채색
    // ─────────────────────────────────────────────────────────

    /**
     * 무채색(R=G=B=x)의 상대휘도는 정확히 x/255다. threshold=0.55 기준으로
     * x=140(휘도 0.549..., threshold 미만)은 다크, x=141(휘도 0.552...,
     * threshold 이상)은 라이트로 갈려야 한다.
     */
    @Test
    fun `boundary gray just below threshold is dark palette`() {
        val gray140 = 0xFF000000.toInt() or (140 shl 16) or (140 shl 8) or 140
        assertTrue(BgContrast.relativeLuminance(gray140) < BgContrast.LUMINANCE_THRESHOLD)
        assertTrue(BgContrast.isDarkPalette(gray140))
    }

    @Test
    fun `boundary gray just above threshold is not dark palette`() {
        val gray141 = 0xFF000000.toInt() or (141 shl 16) or (141 shl 8) or 141
        assertTrue(BgContrast.relativeLuminance(gray141) >= BgContrast.LUMINANCE_THRESHOLD)
        assertFalse(BgContrast.isDarkPalette(gray141))
    }

    // ─────────────────────────────────────────────────────────
    // 알파 채널은 판정에 영향을 주지 않는다(RGB만 본다)
    // ─────────────────────────────────────────────────────────

    @Test
    fun `alpha channel is ignored`() {
        val opaque = 0xFF1A1A2E.toInt()
        val translucent = 0x331A1A2E.toInt()
        assertEquals(
            BgContrast.relativeLuminance(opaque),
            BgContrast.relativeLuminance(translucent),
            1e-9
        )
    }
}
