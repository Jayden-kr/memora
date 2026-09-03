package com.henry.memora

/**
 * 푸시 알림 시간대 규칙 목록. Android API 의존성 0 — JVM 유닛테스트 대상.
 * (PushScheduleTest.kt)
 *
 * v1.3.9 재설계: 마스터 활성시간창·전역 폴더·전역 인터벌·INHERIT sentinel이 전부
 * 사라졌다. 이제 규칙 하나하나가 완결된 단위다(시작/종료/폴더/간격을 전부 명시)
 * — 어떤 행에도 걸리지 않는 시각엔 알림이 안 울린다(의도적인 동작 변경).
 *
 * FolderSchedule.kt(잠금화면 시간대 전환)과 같은 문제를 풀지만 의도적으로 별도 파일이다:
 * - MAX_RULES가 다르다(여기 12, 잠금화면 50)
 * - 규칙마다 intervalMin(간격)이 하나 더 있다
 * - folderId == ALL_FOLDERS(-1)로 "전체 폴더"를 표현할 수 있다(잠금화면 슬롯엔 이 개념이 없다)
 * FolderSchedule을 제네릭화하면 잠금화면이 걸린 테스트+LockScreenService를 건드리게
 * 된다. 대신 가장 틀리기 쉬운 순수 술어(구간 포함 판정)만 위임 호출해 단일 진실원천을
 * 유지한다 — 복제 금지.
 *
 * 잠금화면쪽 FolderSchedule.kt 45-51행 주석이 언급하는 옛 fireIfInRange()의 양끝포함
 * 판정은 v1.3.9에서 제거됐다 — 이제 발화 판정은 규칙의 반열림 구간(slotContains
 * 위임) 하나로 완전히 일원화됐다. FolderSchedule.kt 자체는 건드리지 않는다.
 */
object PushSchedule {
    const val MAX_RULES = 12
    const val ALL_FOLDERS = -1
    const val DEFAULT_INTERVAL_MIN = 30

    data class Rule(val start: Int, val end: Int, val folderId: Int, val intervalMin: Int)

    /**
     * "start:end:folderId:intervalMin"(4필드) 또는 "start:end:folderId"(3필드, 간격
     * 생략) CSV를 파싱한다. 잘못된 항목은 그 항목 하나만 버리고 전체 문자열을 무효화
     * 하지 않는다 — 어떤 입력을 줘도 throw하지 않는다.
     *
     * 드롭 규칙(lib/services/push_schedule.dart의 decode()와 반드시 일치):
     * - 토큰이 ':' 기준 3개 또는 4개로 안 쪼개지면 드롭
     * - start/end가 0..1439 범위 밖이면 드롭
     * - start == end면 드롭 (애매함을 파싱 단계에서 배제)
     * - folderId < -1이면 드롭 (-1 = 전체 폴더는 허용)
     * - intervalMin이 5..1440 범위 밖(파싱 실패·누락·0 포함)이면 그 규칙을 드롭하지
     *   "않고" DEFAULT_INTERVAL_MIN(30)으로 강등한다 — 간격 필드 오타 하나로 폴더
     *   규칙 전체를 잃지 않게 하기 위함. 3필드 토큰(간격 생략)도 동일하게 30으로 채운다.
     *
     * 유효 판정이 끝난 뒤 start 오름차순으로 안정 정렬하고 최대 [MAX_RULES]개만
     * 남긴다(가장 이른 시작들이 남는다).
     */
    fun parse(csv: String?): List<Rule> {
        if (csv.isNullOrBlank()) return emptyList()
        val result = mutableListOf<Rule>()
        for (token in csv.split(",")) {
            if (token.isBlank()) continue
            val parts = token.split(":")
            if (parts.size != 3 && parts.size != 4) continue
            val start = parts[0].trim().toIntOrNull() ?: continue
            val end = parts[1].trim().toIntOrNull() ?: continue
            val folderId = parts[2].trim().toIntOrNull() ?: continue
            if (start !in 0..1439 || end !in 0..1439) continue
            if (start == end) continue
            if (folderId < ALL_FOLDERS) continue
            val rawInterval = if (parts.size == 4) parts[3].trim().toIntOrNull() else null
            val intervalMin = if (rawInterval != null && rawInterval in 5..1440) rawInterval else DEFAULT_INTERVAL_MIN
            result.add(Rule(start, end, folderId, intervalMin))
        }
        // take(MAX_RULES)는 sortedBy 이후이므로 넘치면 "가장 이른 시작"들이 남는다.
        return result.sortedBy { it.start }.take(MAX_RULES)
    }

    /** 항상 4필드로 쓴다. */
    fun encode(rules: List<Rule>): String =
        rules.joinToString(",") { "${it.start}:${it.end}:${it.folderId}:${it.intervalMin}" }

    /**
     * 규칙을 저장된 순서(=[parse]가 정렬해 둔 start 오름차순)대로 검사해 첫 매치를
     * 반환한다. 구간 포함 판정은 FolderSchedule.slotContains에 위임 — 복제 금지.
     */
    fun activeRule(nowMinutes: Int, rules: List<Rule>): Rule? =
        rules.firstOrNull { FolderSchedule.slotContains(it.start, it.end, nowMinutes) }

    /**
     * [now]부터 다음으로 어떤 규칙이든 활성화되는 시점까지 남은 분(1..1440). 규칙이
     * 하나도 없거나 앞으로 24시간 내내 매치가 없으면 1440(=하루 뒤에 재평가). 1440분
     * 브루트포스지만 TICK당 1회 호출뿐이라 비용은 무시 가능 — 자정랩·겹침을 케이스
     * 분석 없이 정확히 처리한다.
     */
    fun minutesUntilNextStart(now: Int, rules: List<Rule>): Int {
        if (rules.isEmpty()) return 1440
        for (d in 1..1440) {
            val t = (now + d) % 1440
            if (activeRule(t, rules) != null) return d
        }
        return 1440
    }
}
