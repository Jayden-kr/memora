import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class LockScreenService {
  static const _channel = MethodChannel('com.henry.memora/lockscreen');

  /// 설정 저장 + 서비스 시작
  static Future<void> startService({
    required bool enabled,
    required List<int> folderIds,
    int finishedFilter = -1,
    bool randomOrder = true,
    bool reversed = false,
    int bgColor = 0xFF1A1A2E,
  }) async {
    try {
      await _channel.invokeMethod('startService', {
        'enabled': enabled,
        'folderIds': folderIds,
        'finishedFilter': finishedFilter,
        'randomOrder': randomOrder,
        'reversed': reversed,
        'bgColor': bgColor,
      });
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
    bool randomOrder = true,
    bool reversed = false,
    int bgColor = 0xFF1A1A2E,
  }) async {
    try {
      await _channel.invokeMethod('saveSettings', {
        'enabled': enabled,
        'folderIds': folderIds,
        'finishedFilter': finishedFilter,
        'randomOrder': randomOrder,
        'reversed': reversed,
        'bgColor': bgColor,
      });
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

  /// 삭제된 폴더 ID를 잠금화면 설정의 folderIds에서 제거.
  /// - 남은 폴더가 있고 서비스 실행 중이면: 갱신된 설정으로 재시작
  /// - 남은 폴더가 없으면: 서비스 중지 + enabled=false 로 저장
  /// - 비활성화/미실행 상태면: 설정만 갱신
  static Future<void> removeFolderFromSettings(int folderId) async {
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
      if (!folderIds.contains(folderId)) return;

      final newFolderIds = folderIds.where((id) => id != folderId).toList();
      final enabled = settings['enabled'] as bool? ?? false;
      final finishedFilter = (settings['finishedFilter'] as num?)?.toInt() ?? -1;
      final randomOrder = settings['randomOrder'] as bool? ?? true;
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
          randomOrder: randomOrder,
          reversed: reversed,
          bgColor: bgColor,
        );
      } else if (running && enabled) {
        await startService(
          enabled: enabled,
          folderIds: newFolderIds,
          finishedFilter: finishedFilter,
          randomOrder: randomOrder,
          reversed: reversed,
          bgColor: bgColor,
        );
      } else {
        await saveSettings(
          enabled: enabled,
          folderIds: newFolderIds,
          finishedFilter: finishedFilter,
          randomOrder: randomOrder,
          reversed: reversed,
          bgColor: bgColor,
        );
      }
    } catch (e) {
      debugPrint('[LockScreenService] removeFolderFromSettings error: $e');
    }
  }
}
