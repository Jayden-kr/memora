package com.henry.memora

/**
 * 잠금화면 시간대별 폴더 전환 규칙. Android API 의존성 0 — JVM 유닛테스트 대상.
 * (FolderScheduleTest.kt)
 */
object FolderSchedule {
    const val MAX_SLOTS = 50

    data class Slot(val start: Int, val end: Int, val folderId: Int)

    /**
     * "start:end:folderId" CSV를 파싱한다. 잘못된 항목은 그 항목 하나만 버리고
     * 전체 문자열을 무효화하지 않는다 — 어떤 입력을 줘도 throw하지 않는다.
     *
     * 유효 판정이 끝난 뒤 start 오름차순으로 안정 정렬하고 최대 [MAX_SLOTS]개만
     * 남긴다. 여기서 정렬해 두는 것이 "먼저 매치되는 슬롯이 이긴다"([resolve])는
     * 규칙을 prefs에 저장된 순서와 무관하게 항상 결정론적으로 만드는 지점이다.
     */
    fun parse(csv: String?): List<Slot> {
        if (csv.isNullOrBlank()) return emptyList()
        val result = mutableListOf<Slot>()
        for (token in csv.split(",")) {
            if (token.isBlank()) continue
            val parts = token.split(":")
            if (parts.size != 3) continue
            val start = parts[0].trim().toIntOrNull() ?: continue
            val end = parts[1].trim().toIntOrNull() ?: continue
            val folderId = parts[2].trim().toIntOrNull() ?: continue
            if (start !in 0..1439 || end !in 0..1439) continue
            if (start == end) continue // 애매함(0분짜리? 하루 종일?)을 파싱 단계에서 배제
            if (folderId < 0) continue
            result.add(Slot(start, end, folderId))
        }
        // take(MAX_SLOTS)는 sortedBy 이후이므로 넘치면 "가장 이른 시작"들이 남는다.
        return result.sortedBy { it.start }.take(MAX_SLOTS)
    }

    fun encode(slots: List<Slot>): String =
        slots.joinToString(",") { "${it.start}:${it.end}:${it.folderId}" }

    /**
     * 반열림 구간 [start, end)로 판정한다.
     *
     * PushNotificationService.kt:417-422(fireIfInRange)의 overnight 체크는 양끝을
     * 모두 포함(`nowTotal in startTotal..endTotal`)한다 — 여기와 의도적으로 다르다.
     * 그쪽은 "알림을 쏠지 말지"를 정하는 단일 범위라 경계 포함이 자연스럽지만,
     * 여기는 하루 전체를 여러 슬롯으로 분할(partition)한다. 09:00–18:00과
     * 18:00–23:00처럼 인접한 두 슬롯에서 양끝 포함을 쓰면 18:00 정각이 두 슬롯
     * 모두에 매치돼버린다. 이 차이를 "통일"하려고 고치지 말 것 — 둘 다 각자 맥락에서
     * 옳다.
     */
    fun slotContains(start: Int, end: Int, nowMinutes: Int): Boolean {
        return when {
            start < end -> nowMinutes >= start && nowMinutes < end   // 같은 날
            start > end -> nowMinutes >= start || nowMinutes < end   // 자정 넘김
            else -> false                                             // parse에서 이미 걸러짐 (start == end)
        }
    }

    /**
     * 슬롯을 저장된 순서(=[parse]가 정렬해 둔 start 오름차순)대로 검사해 첫 매치의
     * folderId 하나만 담은 리스트를 반환한다. 매치가 하나도 없으면 [baseFolderIds]를
     * 그대로(변형 없이) 반환한다.
     */
    fun resolve(nowMinutes: Int, slots: List<Slot>, baseFolderIds: List<Int>): List<Int> {
        for (slot in slots) {
            if (slotContains(slot.start, slot.end, nowMinutes)) {
                return listOf(slot.folderId)
            }
        }
        return baseFolderIds
    }
}
