package com.henry.memora

/**
 * 푸시 알림 시간대별 폴더·주기 전환 규칙. Android API 의존성 0 — JVM 유닛테스트 대상.
 * (PushScheduleTest.kt)
 *
 * FolderSchedule.kt(잠금화면 시간대 전환)과 같은 문제를 풀지만 의도적으로 별도 파일이다:
 * - MAX_SLOTS가 다르다(여기 5, 잠금화면 50)
 * - 슬롯마다 intervalMin(간격 오버라이드)이 하나 더 있다
 * - "전체 폴더"(-1/null) 표현이 없다 — 슬롯은 항상 폴더 1개를 가리켜야 한다
 * FolderSchedule을 제네릭화하면 잠금화면이 걸린 24개 테스트+LockScreenService를
 * 건드리게 된다. 대신 가장 틀리기 쉬운 순수 술어(구간 포함 판정)만 위임 호출해
 * 단일 진실원천을 유지한다 — 복제 금지.
 */
object PushSchedule {
    const val MAX_SLOTS = 5

    /** intervalMin에 쓰이는 sentinel — "전역 인터벌을 그대로 상속". 유효 범위(5..1440)와
     *  절대 겹치지 않는다. */
    const val INHERIT = 0

    data class Slot(val start: Int, val end: Int, val folderId: Int, val intervalMin: Int)

    /**
     * "start:end:folderId:intervalMin"(4필드) 또는 "start:end:folderId"(3필드, 간격
     * 생략) CSV를 파싱한다. 잘못된 항목은 그 항목 하나만 버리고 전체 문자열을 무효화
     * 하지 않는다 — 어떤 입력을 줘도 throw하지 않는다.
     *
     * 드롭 규칙(lib/services/push_schedule.dart의 decode()와 반드시 일치):
     * - 토큰이 ':' 기준 3개 또는 4개로 안 쪼개지면 드롭
     * - start/end가 0..1439 범위 밖이면 드롭
     * - start == end면 드롭 (애매함을 파싱 단계에서 배제)
     * - folderId < 0이면 드롭
     * - intervalMin이 5..1440 범위 밖(숫자가 아닌 경우 포함)이면 그 슬롯을 드롭하지
     *   "않고" INHERIT(0)으로 강등한다 — 간격 필드 오타 하나로 폴더 규칙 전체를
     *   잃지 않게 하기 위함
     * - 3필드 토큰(간격 생략)은 intervalMin=INHERIT으로 관대하게 수용
     *
     * 유효 판정이 끝난 뒤 start 오름차순으로 안정 정렬하고 최대 [MAX_SLOTS]개만
     * 남긴다(가장 이른 시작들이 남는다).
     */
    fun parse(csv: String?): List<Slot> {
        if (csv.isNullOrBlank()) return emptyList()
        val result = mutableListOf<Slot>()
        for (token in csv.split(",")) {
            if (token.isBlank()) continue
            val parts = token.split(":")
            if (parts.size != 3 && parts.size != 4) continue
            val start = parts[0].trim().toIntOrNull() ?: continue
            val end = parts[1].trim().toIntOrNull() ?: continue
            val folderId = parts[2].trim().toIntOrNull() ?: continue
            if (start !in 0..1439 || end !in 0..1439) continue
            if (start == end) continue
            if (folderId < 0) continue
            val rawInterval = if (parts.size == 4) parts[3].trim().toIntOrNull() else INHERIT
            val intervalMin = if (rawInterval != null && rawInterval in 5..1440) rawInterval else INHERIT
            result.add(Slot(start, end, folderId, intervalMin))
        }
        // take(MAX_SLOTS)는 sortedBy 이후이므로 넘치면 "가장 이른 시작"들이 남는다.
        return result.sortedBy { it.start }.take(MAX_SLOTS)
    }

    /** 항상 4필드로 쓴다(간격 생략 표기는 encode 출력에 없음 — parse만 관대하게 받는다). */
    fun encode(slots: List<Slot>): String =
        slots.joinToString(",") { "${it.start}:${it.end}:${it.folderId}:${it.intervalMin}" }

    /**
     * 슬롯을 저장된 순서(=[parse]가 정렬해 둔 start 오름차순)대로 검사해 첫 매치를
     * 반환한다. 구간 포함 판정은 FolderSchedule.slotContains에 위임 — 복제 금지.
     */
    fun activeSlot(nowMinutes: Int, slots: List<Slot>): Slot? =
        slots.firstOrNull { FolderSchedule.slotContains(it.start, it.end, nowMinutes) }

    /** 매치된 슬롯의 folderId, 없으면 [baseFolderId] 그대로. */
    fun resolveFolderId(nowMinutes: Int, slots: List<Slot>, baseFolderId: Int?): Int? {
        val slot = activeSlot(nowMinutes, slots) ?: return baseFolderId
        return slot.folderId
    }

    /** 매치된 슬롯의 intervalMin(단, INHERIT이면 base), 매치 없으면 [baseIntervalMin] 그대로. */
    fun resolveIntervalMin(nowMinutes: Int, slots: List<Slot>, baseIntervalMin: Int): Int {
        val slot = activeSlot(nowMinutes, slots) ?: return baseIntervalMin
        if (slot.intervalMin == INHERIT) return baseIntervalMin
        return slot.intervalMin
    }
}
