import 'lock_screen_service.dart';

/// 푸시 알림 시간대 규칙 하나. start/end는 자정부터의 분(0..1439), 반열림 구간
/// [start, end). start > end면 자정을 넘는 구간이다. intervalMin은 이 규칙이 활성일
/// 때 쓸 알림 간격(분) — 항상 명시값(상속/전역 기본값 개념 없음).
/// folderId == [PushSchedule.allFolders](-1)이면 "전체 폴더"를 뜻한다.
///
/// ⚠️ 드롭 규칙은 android/.../PushSchedule.kt 의 parse()와 반드시 일치해야 한다.
/// (LockScreenSlot/FolderSchedule.kt와 같은 문제를 풀지만, MAX_RULES(12 vs 50)와
/// intervalMin 필드·folderId==-1 표현이 달라 의도적으로 별도 클래스다.)
class PushRule {
  final int start;
  final int end;
  final int folderId;
  final int intervalMin;

  const PushRule({
    required this.start,
    required this.end,
    required this.folderId,
    required this.intervalMin,
  });
}

class PushSchedule {
  static const int maxRules = 12;

  /// folderId에 쓰이는 sentinel — "전체 폴더"(기본 폴더 필터 없음).
  static const int allFolders = -1;

  /// intervalMin 파싱 실패/누락/범위 밖일 때의 강등값.
  static const int defaultIntervalMin = 30;

  static const String settingRulesKey = 'push_rules';

  /// v1.4.0에서 사운드 토글 제거됨. 기존 저장값을 지우지 않기 위해 키 이름만 예약해 둔다.
  static const String settingSoundKey = 'push_sound_enabled';

  /// rulesCsv("start:end:folderId:intervalMin,...") → 규칙 목록. 간격 필드를
  /// 생략한 3필드 토큰("start:end:folderId")도 관대하게 받아 intervalMin을
  /// [defaultIntervalMin]으로 채운다.
  ///
  /// 드롭 규칙 (PushSchedule.kt parse()와 반드시 일치):
  /// - 토큰이 ':' 기준 3개 또는 4개로 안 쪼개지면 드롭
  /// - start/end 가 0..1439 범위 밖이면 드롭
  /// - start == end 면 드롭
  /// - folderId < -1 이면 드롭 (-1 = 전체 폴더는 허용)
  /// - intervalMin이 5..1440 범위 밖(파싱 실패·누락·0 포함)이면 그 규칙을 드롭하지
  ///   "않고" [defaultIntervalMin](30)으로 강등한다
  /// - start 오름차순 정렬 후 최대 [maxRules]개로 컷 (가장 이른 시작들만 유지)
  /// 잘못된 입력이 섞여 있어도 절대 throw 하지 않는다 — 최악의 경우 빈 리스트.
  static List<PushRule> decode(String? csv) {
    if (csv == null || csv.isEmpty) return [];
    final rules = <PushRule>[];
    for (final token in csv.split(',')) {
      if (token.isEmpty) continue;
      final parts = token.split(':');
      if (parts.length != 3 && parts.length != 4) continue;
      final start = int.tryParse(parts[0].trim());
      final end = int.tryParse(parts[1].trim());
      final folderId = int.tryParse(parts[2].trim());
      if (start == null || end == null || folderId == null) continue;
      if (start < 0 || start > 1439 || end < 0 || end > 1439) continue;
      if (start == end) continue;
      if (folderId < allFolders) continue;
      var intervalMin = defaultIntervalMin;
      if (parts.length == 4) {
        final raw = int.tryParse(parts[3].trim());
        if (raw != null && raw >= 5 && raw <= 1440) intervalMin = raw;
      }
      rules.add(PushRule(
        start: start,
        end: end,
        folderId: folderId,
        intervalMin: intervalMin,
      ));
    }
    rules.sort((a, b) => a.start.compareTo(b.start));
    if (rules.length > maxRules) return rules.sublist(0, maxRules);
    return rules;
  }

  /// 규칙 목록 → rulesCsv. 항상 4필드로 쓴다. 빈 목록이면 빈 문자열("규칙 없음"과
  /// 동일 의미).
  static String encode(List<PushRule> rules) {
    return rules
        .map((r) => '${r.start}:${r.end}:${r.folderId}:${r.intervalMin}')
        .join(',');
  }

  /// 규칙(반열림 [start,end), start>end면 자정 교차)이 분 [minute]을 커버하는지.
  static bool _covers(PushRule rule, int minute) {
    if (rule.start < rule.end) {
      return minute >= rule.start && minute < rule.end;
    }
    if (rule.start > rule.end) {
      return minute >= rule.start || minute < rule.end;
    }
    return false;
  }

  /// 규칙을 저장된 순서(=[decode]가 정렬해 둔 start 오름차순)대로 검사해 첫 매치를
  /// 반환한다. Kotlin PushSchedule.activeRule과 동일한 "첫 매치 승리" 규칙 — 반드시
  /// [effectiveRanges]가 만드는 소유권과 일치해야 한다(교차검증 테스트로 보증).
  static PushRule? activeRule(int nowMinutes, List<PushRule> rules) {
    for (final rule in rules) {
      if (_covers(rule, nowMinutes)) return rule;
    }
    return null;
  }

  // ─── UI 보조 어댑터 — LockScreenSchedule의 구현을 그대로 호출(1440분 순회+자정랩
  // 병합 알고리즘을 복제하지 않는다) ───
  //
  // LockScreenSchedule.overlappingIndices/effectiveRanges는 LockScreenSlot의
  // start/end만 읽고 folderId는 전혀 참조하지 않는다(순수 시간 계산) — 그래서
  // folderId == allFolders(-1)를 그대로 태워도 안전하다.

  static LockScreenSlot _toLockScreenSlot(PushRule r) =>
      LockScreenSlot(start: r.start, end: r.end, folderId: r.folderId);

  /// 규칙 목록 중 서로 겹치는 규칙들의 인덱스 집합 (경고 표시용).
  static Set<int> overlappingIndices(List<PushRule> rules) =>
      LockScreenSchedule.overlappingIndices(
          rules.map(_toLockScreenSlot).toList());

  /// 각 규칙이 실제로 차지하는 구간. 반환값의 i번째 원소가 rules[i]의 실적용 구간.
  static List<List<List<int>>> effectiveRanges(List<PushRule> rules) =>
      LockScreenSchedule.effectiveRanges(rules.map(_toLockScreenSlot).toList());

  /// 어떤 규칙도 커버하지 않는 분들을 자정랩까지 병합한 구간 목록. 표기는
  /// [effectiveRanges]와 동일(반열림 [start,end), end==0은 "자정까지"를 뜻함).
  /// 규칙이 하나도 없으면 하루 전체가 gap이므로 [[0, 0]](= 0시부터 자정까지 전체
  /// wrap)을 반환한다.
  static List<List<int>> gapRanges(List<PushRule> rules) {
    final covered = List<bool>.filled(1440, false);
    for (var m = 0; m < 1440; m++) {
      covered[m] = activeRule(m, rules) != null;
    }
    final result = <List<int>>[];
    var i = 0;
    while (i < 1440) {
      if (covered[i]) {
        i++;
        continue;
      }
      var j = i + 1;
      while (j < 1440 && !covered[j]) {
        j++;
      }
      result.add([i, j]);
      i = j;
    }
    // 자정 랩 병합: 0에서 시작하는 gap과 1440에서 끝나는 gap이 동시에 있으면
    // 물리적으로 하나의 구간이므로 합친다 (LockScreenSchedule.effectiveRanges와
    // 동일한 병합 규칙).
    if (result.length >= 2 &&
        result.first[0] == 0 &&
        result.last[1] == 1440) {
      final wrapStart = result.removeLast()[0];
      final wrapEnd = result.removeAt(0)[1];
      result.insert(0, [wrapStart, wrapEnd]);
    }
    for (final r in result) {
      if (r[1] == 1440) r[1] = 0;
    }
    return result;
  }
}
