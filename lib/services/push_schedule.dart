import 'lock_screen_service.dart';

/// 푸시 알림 시간대 슬롯 하나. start/end는 자정부터의 분(0..1439), 반열림 구간
/// [start, end). start > end면 자정을 넘는 구간이다. intervalMin은 이 슬롯이 활성일
/// 때 쓸 알림 간격(분) 오버라이드 — [PushSchedule.inherit](0)이면 전역 간격을 그대로
/// 쓴다(사실상 이 슬롯은 폴더만 바꾼다는 뜻).
///
/// ⚠️ 드롭 규칙은 android/.../PushSchedule.kt 의 parse()와 반드시 일치해야 한다.
/// (LockScreenSlot/FolderSchedule.kt와 같은 문제를 풀지만, MAX_SLOTS(5 vs 50)와
/// intervalMin 필드 유무가 달라 의도적으로 별도 클래스다.)
class PushSlot {
  final int start;
  final int end;
  final int folderId;
  final int intervalMin;

  const PushSlot({
    required this.start,
    required this.end,
    required this.folderId,
    this.intervalMin = 0,
  });
}

class PushSchedule {
  static const int maxSlots = 5;

  /// intervalMin에 쓰이는 sentinel — "전역 인터벌을 그대로 상속". 유효 범위(5..1440)와
  /// 절대 겹치지 않는다.
  static const int inherit = 0;

  static const String settingEnabledKey = 'push_schedule_enabled';
  static const String settingCsvKey = 'push_schedule';

  /// scheduleCsv("start:end:folderId:intervalMin,...") → 슬롯 목록. 간격 필드를
  /// 생략한 3필드 토큰("start:end:folderId")도 관대하게 받아 intervalMin=[inherit]로
  /// 채운다.
  ///
  /// 드롭 규칙 (PushSchedule.kt parse()와 반드시 일치):
  /// - 토큰이 ':' 기준 3개 또는 4개로 안 쪼개지면 드롭
  /// - start/end 가 0..1439 범위 밖이면 드롭
  /// - start == end 면 드롭
  /// - folderId < 0 이면 드롭
  /// - intervalMin이 5..1439 범위 밖(숫자가 아닌 경우 포함)이면 그 슬롯을 드롭하지
  ///   "않고" [inherit](0)으로 강등한다 — 간격 필드 오타 하나로 폴더 규칙 전체를
  ///   잃지 않게 하기 위함
  /// - start 오름차순 정렬 후 최대 [maxSlots]개로 컷 (가장 이른 시작들만 유지)
  /// 잘못된 입력이 섞여 있어도 절대 throw 하지 않는다 — 최악의 경우 빈 리스트.
  static List<PushSlot> decode(String? csv) {
    if (csv == null || csv.isEmpty) return [];
    final slots = <PushSlot>[];
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
      if (folderId < 0) continue;
      var intervalMin = inherit;
      if (parts.length == 4) {
        final raw = int.tryParse(parts[3].trim());
        if (raw != null && raw >= 5 && raw <= 1440) intervalMin = raw;
      }
      slots.add(PushSlot(
        start: start,
        end: end,
        folderId: folderId,
        intervalMin: intervalMin,
      ));
    }
    slots.sort((a, b) => a.start.compareTo(b.start));
    if (slots.length > maxSlots) return slots.sublist(0, maxSlots);
    return slots;
  }

  /// 슬롯 목록 → scheduleCsv. 항상 4필드로 쓴다(간격 생략 표기는 decode만 관대하게
  /// 받아들인다). 빈 목록이면 빈 문자열("슬롯 없음"과 동일 의미).
  static String encode(List<PushSlot> slots) {
    return slots
        .map((s) => '${s.start}:${s.end}:${s.folderId}:${s.intervalMin}')
        .join(',');
  }

  // ─── UI 보조 어댑터 — LockScreenSchedule의 구현을 그대로 호출(1440분 순회+자정랩
  // 병합 알고리즘을 복제하지 않는다) ───

  static LockScreenSlot _toLockScreenSlot(PushSlot s) =>
      LockScreenSlot(start: s.start, end: s.end, folderId: s.folderId);

  /// 슬롯 목록 중 서로 겹치는 슬롯들의 인덱스 집합 (경고 표시용).
  static Set<int> overlappingIndices(List<PushSlot> slots) =>
      LockScreenSchedule.overlappingIndices(
          slots.map(_toLockScreenSlot).toList());

  /// 각 슬롯이 실제로 차지하는 구간. 반환값의 i번째 원소가 slots[i]의 실적용 구간.
  static List<List<List<int>>> effectiveRanges(List<PushSlot> slots) =>
      LockScreenSchedule.effectiveRanges(slots.map(_toLockScreenSlot).toList());

  /// 마스터 활성시간창([startTotal, endTotal], 양끝 포함 — 네이티브
  /// PushNotificationService.fireIfInRange와 동일한 의미론)과 전혀 겹치지 않는
  /// 슬롯의 인덱스 집합. 그런 슬롯은 저장은 되지만 네이티브에서 발화조차 되지
  /// 않는다(activeSlotNow가 inMasterWindow(now)==false면 즉시 null을 반환하므로)
  /// — UI 경고 전용, 저장을 막지 않는다.
  static Set<int> outsideWindowIndices(
      List<PushSlot> slots, int startTotal, int endTotal) {
    final result = <int>{};
    for (var i = 0; i < slots.length; i++) {
      final slot = slots[i];
      var overlapsWindow = false;
      for (var m = 0; m < 1440; m++) {
        if (_slotCovers(slot, m) && _masterContains(startTotal, endTotal, m)) {
          overlapsWindow = true;
          break;
        }
      }
      if (!overlapsWindow) result.add(i);
    }
    return result;
  }

  /// 슬롯(반열림 [start,end), start>end면 자정 교차)이 분 [minute]을 커버하는지.
  static bool _slotCovers(PushSlot slot, int minute) {
    if (slot.start < slot.end) {
      return minute >= slot.start && minute < slot.end;
    }
    if (slot.start > slot.end) {
      return minute >= slot.start || minute < slot.end;
    }
    return false;
  }

  /// 마스터 활성시간창(양끝 포함, overnight 지원)이 분 [minute]을 포함하는지.
  /// PushNotificationService.kt fireIfInRange()/inMasterWindow()의 판정과 동일한
  /// 의미론 — 슬롯의 반열림 판정과 "통일"하지 말 것(둘 다 각자 맥락에서 옳다).
  static bool _masterContains(int startTotal, int endTotal, int minute) {
    if (startTotal <= endTotal) {
      return minute >= startTotal && minute <= endTotal;
    }
    return minute >= startTotal || minute <= endTotal;
  }
}
