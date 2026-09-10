import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 잠금화면 시간대 슬롯 하나. start/end 는 자정부터의 분(0..1439), 반열림 구간 [start, end).
/// start > end 면 자정을 넘는 구간이다.
/// ⚠️ 드롭 규칙은 android/.../FolderSchedule.kt 의 parse() 와 반드시 일치해야 한다.
class LockScreenSlot {
  final int start;
  final int end;
  final int folderId;

  const LockScreenSlot({
    required this.start,
    required this.end,
    required this.folderId,
  });
}

class LockScreenSchedule {
  static const int maxSlots = 50;

  /// scheduleCsv("start:end:folderId,...") → 슬롯 목록.
  /// 드롭 규칙 (FolderSchedule.kt parse()와 반드시 일치):
  /// - 토큰이 ':' 기준 정확히 3개로 안 쪼개지면 드롭
  /// - start/end 가 0..1439 범위 밖이면 드롭
  /// - start == end 면 드롭
  /// - folderId < 0 이면 드롭
  /// - start 오름차순 정렬 후 최대 [maxSlots]개로 컷 (가장 이른 시작들만 유지)
  /// 잘못된 입력이 섞여 있어도 절대 throw 하지 않는다 — 최악의 경우 빈 리스트.
  static List<LockScreenSlot> decode(String? csv) {
    if (csv == null || csv.isEmpty) return [];
    final slots = <LockScreenSlot>[];
    for (final token in csv.split(',')) {
      final parts = token.split(':');
      if (parts.length != 3) continue;
      final start = int.tryParse(parts[0].trim());
      final end = int.tryParse(parts[1].trim());
      final folderId = int.tryParse(parts[2].trim());
      if (start == null || end == null || folderId == null) continue;
      if (start < 0 || start > 1439 || end < 0 || end > 1439) continue;
      if (start == end) continue;
      if (folderId < 0) continue;
      slots.add(LockScreenSlot(start: start, end: end, folderId: folderId));
    }
    slots.sort((a, b) => a.start.compareTo(b.start));
    if (slots.length > maxSlots) return slots.sublist(0, maxSlots);
    return slots;
  }

  /// 슬롯 목록 → scheduleCsv. 빈 목록이면 빈 문자열("슬롯 없음"과 동일 의미).
  static String encode(List<LockScreenSlot> slots) {
    return slots.map((s) => '${s.start}:${s.end}:${s.folderId}').join(',');
  }

  /// UI 경고용. 저장을 막지는 않는다.
  /// 반열림 구간 [start, end) 두 개가 1분이라도 겹치면 true.
  /// start > end(자정 교차) 슬롯은 [start, 1440) ∪ [0, end) 로 펼쳐서 비교한다.
  static bool overlaps(LockScreenSlot a, LockScreenSlot b) {
    for (final segA in _segments(a)) {
      for (final segB in _segments(b)) {
        // 반열림 구간 겹침 조건: segA[0] < segB[1] && segB[0] < segA[1]
        if (segA[0] < segB[1] && segB[0] < segA[1]) return true;
      }
    }
    return false;
  }

  /// 슬롯을 자정을 넘지 않는 [start, end) 구간 1~2개로 펼친다.
  static List<List<int>> _segments(LockScreenSlot s) {
    if (s.start < s.end) {
      return [
        [s.start, s.end],
      ];
    }
    if (s.start > s.end) {
      return [
        [s.start, 1440],
        [0, s.end],
      ];
    }
    return const []; // start == end: 커버 범위 없음 (decode에서 이미 드롭되는 값)
  }

  /// 슬롯 목록 중 서로 겹치는 슬롯들의 인덱스 집합 (경고 표시용).
  static Set<int> overlappingIndices(List<LockScreenSlot> slots) {
    final result = <int>{};
    for (var i = 0; i < slots.length; i++) {
      for (var j = i + 1; j < slots.length; j++) {
        if (overlaps(slots[i], slots[j])) {
          result.add(i);
          result.add(j);
        }
      }
    }
    return result;
  }

  /// 각 슬롯이 실제로 차지하는 구간. 반환값의 i번째 원소가 slots[i]의 실적용 구간 목록이다.
  /// 앞선 슬롯(= start가 이른 쪽)이 이미 가져간 분은 빠진다 — Kotlin FolderSchedule.resolve의
  /// "첫 매치 승리"와 같은 결과를 UI 쪽에서 재현한 것.
  /// 완전히 가려진 슬롯은 빈 리스트가 된다.
  ///
  /// 표시 전용 계산이다 — 우선순위(= 목록 순서)는 절대 바꾸지 않는다. 저장을 막지도
  /// 않는다.
  static List<List<List<int>>> effectiveRanges(List<LockScreenSlot> slots) {
    if (slots.isEmpty) return [];

    // 슬롯별 세그먼트를 한 번만 계산해 재사용 (1440분 순회마다 다시 만들지 않는다).
    final segsPerSlot = slots.map(_segments).toList();

    // owner[m] = 분 m을 차지하는 첫 슬롯의 인덱스(= 목록 순서상 첫 매치). 아무 슬롯도
    // 커버하지 않으면 -1.
    final owner = List<int>.filled(1440, -1);
    for (var m = 0; m < 1440; m++) {
      for (var i = 0; i < segsPerSlot.length; i++) {
        var inSlot = false;
        for (final seg in segsPerSlot[i]) {
          if (seg[0] <= m && m < seg[1]) {
            inSlot = true;
            break;
          }
        }
        if (inSlot) {
          owner[m] = i;
          break;
        }
      }
    }

    // owner를 연속 구간(run)으로 묶어 슬롯별로 모은다. 0→1439 순서로 스캔하므로 한
    // 슬롯의 run들은 자연히 start 오름차순으로 쌓인다 — 아래 자정 랩 병합이 그 순서에
    // 의존한다.
    final result = List.generate(slots.length, (_) => <List<int>>[]);
    var i = 0;
    while (i < 1440) {
      final o = owner[i];
      var j = i + 1;
      while (j < 1440 && owner[j] == o) {
        j++;
      }
      if (o != -1) {
        result[o].add([i, j]); // 반열림 [i, j) — j는 자정에서 닫히면 1440일 수 있다.
      }
      i = j;
    }

    // 자정 랩 병합: 같은 슬롯이 1440에서 끝나는 run과 0에서 시작하는 run을 동시에
    // 가지면(= 자정을 건너 계속 이어짐) 물리적으로 하나의 구간이므로 합친다.
    // length==1인 경우는 병합 대상이 될 수 없다 — 슬롯 하나가 1440분 전체를 차지할
    // 수는 없기 때문이다(decode가 start==end를 버리고, 자정교차 슬롯은 start>end라
    // [end, start) 만큼 항상 빈틈이 남는다).
    for (final ranges in result) {
      if (ranges.length >= 2 &&
          ranges.first[0] == 0 &&
          ranges.last[1] == 1440) {
        final wrapStart = ranges.removeLast()[0];
        final wrapEnd = ranges.removeAt(0)[1];
        ranges.insert(0, [wrapStart, wrapEnd]);
      }
    }

    // end==1440을 0으로 정규화 — 모든 반환값이 슬롯 자신의 start/end처럼 0..1439
    // 범위 안에서만 읽히고, "자정까지"인 구간은 슬롯이 원래 쓰는 표기(start>end)로
    // 자연스럽게 표현되게 한다.
    for (final ranges in result) {
      for (final r in ranges) {
        if (r[1] == 1440) r[1] = 0;
      }
      // 표시 순서 안정화: start 오름차순.
      ranges.sort((a, b) => a[0].compareTo(b[0]));
    }

    return result;
  }

  /// 실적용 구간이 사용자가 적어 넣은 구간과 완전히 같은가(= 표시할 필요가 없는가).
  static bool matchesDeclared(LockScreenSlot slot, List<List<int>> ranges) {
    return ranges.length == 1 &&
        ranges[0][0] == slot.start &&
        ranges[0][1] == slot.end;
  }
}

class LockScreenService {
  static const _channel = MethodChannel('com.henry.memora/lockscreen');

  /// 설정 저장 + 서비스 시작
  static Future<void> startService({
    required bool enabled,
    required List<int> folderIds,
    int finishedFilter = -1,
    String sortOrder = 'sequence',
    bool reversed = false,
    int bgColor = 0xFF1A1A2E,
    bool? scheduleEnabled,
    String? scheduleCsv,
    String? bgTextMode,
    String? bgImagePath,
    int? bgImageAlpha,
    int? bgScrimAlpha,
  }) async {
    try {
      final args = <String, dynamic>{
        'enabled': enabled,
        'folderIds': folderIds,
        'finishedFilter': finishedFilter,
        'sortOrder': sortOrder,
        'reversed': reversed,
        'bgColor': bgColor,
      };
      // scheduleEnabled/scheduleCsv/bgTextMode/bg이미지 3종은 null이면 인자에 아예
      // 넣지 않는다 — 네이티브가 기존 저장값을 그대로 보존하게 하려는 의도.
      // main.dart의 앱 시작 복원 경로(_restoreLockScreenService)가 이 파라미터들을
      // 생략하고 호출하므로, 여기 기본값을 주면 매 앱 실행마다 사용자의 시간대
      // 스케줄/텍스트 모드/배경 이미지가 조용히 사라진다.
      if (scheduleEnabled != null) args['scheduleEnabled'] = scheduleEnabled;
      if (scheduleCsv != null) args['scheduleCsv'] = scheduleCsv;
      if (bgTextMode != null) args['bgTextMode'] = bgTextMode;
      if (bgImagePath != null) args['bgImagePath'] = bgImagePath;
      if (bgImageAlpha != null) args['bgImageAlpha'] = bgImageAlpha;
      if (bgScrimAlpha != null) args['bgScrimAlpha'] = bgScrimAlpha;
      await _channel.invokeMethod('startService', args);
    } catch (e) {
      debugPrint('[LockScreenService] startService error: $e');
    }
  }

  /// 서비스 중지 (설정은 유지)
  static Future<void> stopService() async {
    try {
      await _channel.invokeMethod('stopService');
    } catch (e) {
      debugPrint('[LockScreenService] stopService error: $e');
    }
  }

  /// 설정만 저장 (서비스 시작/중지 안 함)
  static Future<void> saveSettings({
    required bool enabled,
    required List<int> folderIds,
    int finishedFilter = -1,
    String sortOrder = 'sequence',
    bool reversed = false,
    int bgColor = 0xFF1A1A2E,
    bool? scheduleEnabled,
    String? scheduleCsv,
    String? bgTextMode,
    String? bgImagePath,
    int? bgImageAlpha,
    int? bgScrimAlpha,
  }) async {
    try {
      final args = <String, dynamic>{
        'enabled': enabled,
        'folderIds': folderIds,
        'finishedFilter': finishedFilter,
        'sortOrder': sortOrder,
        'reversed': reversed,
        'bgColor': bgColor,
      };
      // startService와 동일한 이유로 null 키는 생략한다.
      if (scheduleEnabled != null) args['scheduleEnabled'] = scheduleEnabled;
      if (scheduleCsv != null) args['scheduleCsv'] = scheduleCsv;
      if (bgTextMode != null) args['bgTextMode'] = bgTextMode;
      if (bgImagePath != null) args['bgImagePath'] = bgImagePath;
      if (bgImageAlpha != null) args['bgImageAlpha'] = bgImageAlpha;
      if (bgScrimAlpha != null) args['bgScrimAlpha'] = bgScrimAlpha;
      await _channel.invokeMethod('saveSettings', args);
    } catch (e) {
      debugPrint('[LockScreenService] saveSettings error: $e');
    }
  }

  static Future<bool> isRunning() async {
    try {
      final result = await _channel.invokeMethod<bool>('isRunning');
      return result ?? false;
    } catch (e) {
      debugPrint('[LockScreenService] isRunning error: $e');
      return false;
    }
  }

  static Future<bool> canDrawOverlays() async {
    try {
      final result = await _channel.invokeMethod<bool>('canDrawOverlays');
      return result ?? false;
    } catch (e) {
      debugPrint('[LockScreenService] canDrawOverlays error: $e');
      return false;
    }
  }

  static Future<void> requestOverlayPermission() async {
    try {
      await _channel.invokeMethod('requestOverlayPermission');
    } catch (e) {
      debugPrint('[LockScreenService] requestOverlayPermission error: $e');
    }
  }

  static Future<Map<String, dynamic>> getSettings() async {
    try {
      final result = await _channel.invokeMethod<Map>('getSettings');
      if (result == null) return {};
      return Map<String, dynamic>.from(result);
    } catch (e) {
      debugPrint('[LockScreenService] getSettings error: $e');
      return {};
    }
  }

  /// 여러 폴더 ID를 잠금화면 설정의 folderIds와 시간대 스케줄 슬롯에서 한 번에 제거.
  /// settings read 1회 + write 1회로 N회 호출 대비 SharedPreferences I/O 최소화.
  /// - 남은 기본 폴더가 있고 서비스 실행 중이면: 갱신된 설정으로 재시작
  /// - 남은 기본 폴더가 없는데 유효한 시간대 슬롯이 남아 있으면: 그대로 계속 돌린다.
  ///   슬롯 창 안에서는 슬롯 폴더를, 창 밖에서는 전체 카드를 보여준다(네이티브
  ///   FolderSchedule.resolve + 빈 폴더 목록 = 필터 없음). 사용자 결정 2026-09-06.
  /// - 남은 기본 폴더도 슬롯도 없으면: 서비스 중지 + enabled=false 로 저장
  ///   (단, 시간대 슬롯은 기본 폴더와 별개의 유효한 데이터이므로 여기서 건드리지
  ///   않는다 — 사용자가 새 기본 폴더를 고르면 그대로 되살아난다)
  /// - 비활성화/미실행 상태면: 설정만 갱신
  /// 반환값: 이번 정리로 잠금화면을 껐으면 true. 화면이 사용자에게 알린다 —
  /// 푸시 규칙 쪽(removeFoldersFromPushSchedule)과 같은 규칙이다. 예전엔 여기만
  /// 조용히 꺼서, 사용자는 잠금화면이 왜 멈췄는지 알 방법이 없었다(스윕 S-02).
  ///
  /// round7: [isStale]은 호출자(home_screen의 정리 큐)가 "이 호출이 아직도
  /// 최신인지"를 판정하는 콜백이다. 이 함수는 SharedPreferences를 MethodChannel로
  /// 읽고 쓴다 — 그 사이에 큐의 백스톱이 자리를 강제로 비워 더 최신 정리가 먼저
  /// 끝나 있으면, 여기서 실제 쓰기(stopService/saveSettings/startService)를 하는
  /// 순간 옛 스냅샷으로 그 최신 결과를 덮어쓴다. 네이티브 채널이라 sqflite 트랜잭션
  /// 같은 원자성이 없으므로, 각 쓰기 직전마다 [isStale]을 다시 확인해 그렇다면
  /// 조용히 물러난다(리뷰 R6-1).
  static Future<bool> removeFoldersFromSettingsBatch(
    List<int> folderIdsToRemove, {
    bool Function()? isStale,
  }) async {
    if (folderIdsToRemove.isEmpty) return false;
    try {
      final settings = await getSettings();
      final rawIds = settings['folderIds'];
      final folderIds = <int>[];
      if (rawIds is List) {
        for (final v in rawIds) {
          if (v is int) {
            folderIds.add(v);
          } else if (v != null) {
            final parsed = int.tryParse(v.toString());
            if (parsed != null) folderIds.add(parsed);
          }
        }
      }
      final removeSet = folderIdsToRemove.toSet();
      final newFolderIds = folderIds
          .where((id) => !removeSet.contains(id))
          .toList();

      // 삭제 대상 폴더를 가리키는 시간대 슬롯도 함께 정리 — 그렇지 않으면 기본
      // 폴더 목록에서만 사라지고 슬롯엔 삭제된 폴더 id가 영구히 남는다.
      final slots = LockScreenSchedule.decode(
        settings['scheduleCsv'] as String?,
      );
      final prunedSlots = slots
          .where((s) => !removeSet.contains(s.folderId))
          .toList();
      final scheduleChanged = prunedSlots.length != slots.length;

      if (newFolderIds.length == folderIds.length && !scheduleChanged) {
        return false; // 변경 없음 (기본 폴더도, 슬롯도 이 삭제와 무관)
      }

      final scheduleCsv = LockScreenSchedule.encode(prunedSlots);
      // 슬롯이 있었는데 이번 pruning으로 전부 사라진 경우에만 스케줄을 끈다 —
      // 슬롯 0개인데 스케줄 ON인 상태는 혼란스러운 무동작(no-op)이기 때문. 그 외
      // (슬롯이 하나라도 남거나 애초에 없었던 경우)엔 scheduleEnabled를 건드리지
      // 않아(null → 인자 생략) 사용자가 설정한 값이 그대로 보존된다.
      final newScheduleEnabled = (slots.isNotEmpty && prunedSlots.isEmpty)
          ? false
          : null;

      final enabled = settings['enabled'] as bool? ?? false;
      final finishedFilter =
          (settings['finishedFilter'] as num?)?.toInt() ?? -1;
      final sortOrder = settings['sortOrder'] as String? ?? 'sequence';
      final reversed = settings['reversed'] as bool? ?? false;
      final bgColor = (settings['bgColor'] as num?)?.toInt() ?? 0xFF1A1A2E;

      final running = await isRunning();

      // 기본 폴더가 다 사라져도 유효한 시간대 슬롯이 남아 있으면 기능을 끄지 않는다
      // (사용자 결정 2026-09-06, 감사 D1-04/D5-05). 슬롯 시간대에는 그 폴더가 뜨고,
      // 그 밖의 시간에는 네이티브 사양대로 "빈 기본 폴더 = 전체 카드"로 동작한다.
      final keepRunningOnSlots = prunedSlots.isNotEmpty &&
          (settings['scheduleEnabled'] as bool? ?? false);

      // 실제 쓰기 직전마다 확인한다 — 위 판단(newFolderIds/scheduleCsv 등)이
      // 서있는 동안 더 최신 정리가 먼저 끝났다면, 이제 와서 쓰면 그 결과를 덮는다.
      //
      // ⚠️ **남아 있는 구멍(의도적으로 감수함).** 이 확인은 "보내기 직전"이지
      // "적용될 때까지"가 아니다. 확인을 통과하고 채널 호출을 띄운 뒤 그 호출이
      // 네이티브에서 오래 붙들려 있으면, 그 사이 더 최신 정리가 끝나고 내 옛 값이
      // 나중에 착지할 수 있다(리뷰 R7-A). 완전히 막으려면 세대 번호를 네이티브까지
      // 내려보내 거기서 원자적으로 판정해야 하는데, 그건 네이티브 API 변경이라
      // 이번 릴리스에서 하지 않는다.
      //
      // 감수하는 근거: (1) 성립하려면 채널 호출 하나가 백스톱(5분)을 넘겨 붙들린 뒤
      // 되살아나야 한다. (2) 그렇게 되살아난 값이 지운 폴더를 되살리더라도, 다음 앱
      // 시작의 _reconcileLockScreenFoldersOnce가 folderIds와 시간대 슬롯 양쪽에서
      // 없는 폴더 참조를 걷어낸다 — 영구히 굳지 않는다.
      bool giveUpIfStale() {
        if (isStale == null || !isStale()) return false;
        debugPrint(
          '[LockScreenService] 더 최신 정리가 있어 쓰기를 건너뜀 '
          '(removeFoldersFromSettingsBatch)',
        );
        return true;
      }

      if (newFolderIds.isEmpty && !keepRunningOnSlots) {
        if (giveUpIfStale()) return false;
        if (running) await stopService();
        // ⚠️ 여기서는 stale이어도 물러나지 않는다. 서비스는 이미 멈췄는데 저장을
        // 건너뛰면 prefs엔 enabled:true가 남아 화면과 실제가 갈리고, 반환값도 false라
        // 사용자에게 "잠금화면이 꺼졌다"는 안내조차 안 나간다 — 스윕 S-02에서 고쳤던
        // 그 조용한 종료가 그대로 재현된다(리뷰 R7-C). 찢어진 상태를 남기느니
        // 마무리하는 쪽이 낫다.
        await saveSettings(
          enabled: false,
          folderIds: const [],
          finishedFilter: finishedFilter,
          sortOrder: sortOrder,
          reversed: reversed,
          bgColor: bgColor,
          scheduleEnabled: newScheduleEnabled,
          scheduleCsv: scheduleCsv,
        );
        // 원래 켜져 있던 것을 이번에 껐을 때만 알린다.
        return enabled;
      } else if (running && enabled) {
        if (giveUpIfStale()) return false;
        await startService(
          enabled: enabled,
          folderIds: newFolderIds,
          finishedFilter: finishedFilter,
          sortOrder: sortOrder,
          reversed: reversed,
          bgColor: bgColor,
          scheduleEnabled: newScheduleEnabled,
          scheduleCsv: scheduleCsv,
        );
      } else {
        if (giveUpIfStale()) return false;
        await saveSettings(
          enabled: enabled,
          folderIds: newFolderIds,
          finishedFilter: finishedFilter,
          sortOrder: sortOrder,
          reversed: reversed,
          bgColor: bgColor,
          scheduleEnabled: newScheduleEnabled,
          scheduleCsv: scheduleCsv,
        );
      }
      return false;
    } catch (e) {
      debugPrint(
        '[LockScreenService] removeFoldersFromSettingsBatch error: $e',
      );
      return false;
    }
  }
}
