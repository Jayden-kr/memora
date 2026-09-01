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
        [s.start, s.end]
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
      // scheduleEnabled/scheduleCsv 는 null이면 인자에 아예 넣지 않는다 — 네이티브가
      // 기존 저장값을 그대로 보존하게 하려는 의도. main.dart의 앱 시작 복원 경로
      // (_restoreLockScreenService)가 이 두 파라미터를 생략하고 호출하므로, 여기
      // 기본값을 주면 매 앱 실행마다 사용자의 시간대 스케줄이 조용히 사라진다.
      if (scheduleEnabled != null) args['scheduleEnabled'] = scheduleEnabled;
      if (scheduleCsv != null) args['scheduleCsv'] = scheduleCsv;
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

  /// 삭제된 폴더 ID 1개를 잠금화면 설정에서 제거.
  /// repo 전체에 호출자가 없지만 공개 API 유지를 위해 존치 — pruning 로직(스케줄
  /// 슬롯 포함)을 두 곳에 중복 구현하지 않도록 배치 버전에 위임한다.
  static Future<void> removeFolderFromSettings(int folderId) =>
      removeFoldersFromSettingsBatch([folderId]);

  /// 여러 폴더 ID를 잠금화면 설정의 folderIds와 시간대 스케줄 슬롯에서 한 번에 제거.
  /// settings read 1회 + write 1회로 N회 호출 대비 SharedPreferences I/O 최소화.
  /// - 남은 기본 폴더가 있고 서비스 실행 중이면: 갱신된 설정으로 재시작
  /// - 남은 기본 폴더가 없으면: 서비스 중지 + enabled=false 로 저장
  ///   (단, 시간대 슬롯은 기본 폴더와 별개의 유효한 데이터이므로 여기서 건드리지
  ///   않는다 — 사용자가 새 기본 폴더를 고르면 그대로 되살아난다)
  /// - 비활성화/미실행 상태면: 설정만 갱신
  static Future<void> removeFoldersFromSettingsBatch(
      List<int> folderIdsToRemove) async {
    if (folderIdsToRemove.isEmpty) return;
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
      final newFolderIds =
          folderIds.where((id) => !removeSet.contains(id)).toList();

      // 삭제 대상 폴더를 가리키는 시간대 슬롯도 함께 정리 — 그렇지 않으면 기본
      // 폴더 목록에서만 사라지고 슬롯엔 삭제된 폴더 id가 영구히 남는다.
      final slots =
          LockScreenSchedule.decode(settings['scheduleCsv'] as String?);
      final prunedSlots =
          slots.where((s) => !removeSet.contains(s.folderId)).toList();
      final scheduleChanged = prunedSlots.length != slots.length;

      if (newFolderIds.length == folderIds.length && !scheduleChanged) {
        return; // 변경 없음 (기본 폴더도, 슬롯도 이 삭제와 무관)
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
      final finishedFilter = (settings['finishedFilter'] as num?)?.toInt() ?? -1;
      final sortOrder = settings['sortOrder'] as String? ?? 'sequence';
      final reversed = settings['reversed'] as bool? ?? false;
      final bgColor =
          (settings['bgColor'] as num?)?.toInt() ?? 0xFF1A1A2E;

      final running = await isRunning();

      if (newFolderIds.isEmpty) {
        if (running) await stopService();
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
      } else if (running && enabled) {
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
    } catch (e) {
      debugPrint(
          '[LockScreenService] removeFoldersFromSettingsBatch error: $e');
    }
  }
}
