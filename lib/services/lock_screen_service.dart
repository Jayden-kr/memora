import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class LockScreenService {
  static const _channel = MethodChannel('com.henry.amki_wang/lockscreen');

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
}
