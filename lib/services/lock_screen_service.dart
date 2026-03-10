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
    await _channel.invokeMethod('startService', {
      'enabled': enabled,
      'folderIds': folderIds,
      'finishedFilter': finishedFilter,
      'randomOrder': randomOrder,
      'reversed': reversed,
      'bgColor': bgColor,
    });
  }

  /// 서비스 중지 (설정은 유지)
  static Future<void> stopService() async {
    await _channel.invokeMethod('stopService');
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
    await _channel.invokeMethod('saveSettings', {
      'enabled': enabled,
      'folderIds': folderIds,
      'finishedFilter': finishedFilter,
      'randomOrder': randomOrder,
      'reversed': reversed,
      'bgColor': bgColor,
    });
  }

  static Future<bool> isRunning() async {
    final result = await _channel.invokeMethod<bool>('isRunning');
    return result ?? false;
  }

  static Future<bool> canDrawOverlays() async {
    final result = await _channel.invokeMethod<bool>('canDrawOverlays');
    return result ?? false;
  }

  static Future<void> requestOverlayPermission() async {
    await _channel.invokeMethod('requestOverlayPermission');
  }

  static Future<Map<String, dynamic>> getSettings() async {
    final result = await _channel.invokeMethod<Map>('getSettings');
    if (result == null) return {};
    return Map<String, dynamic>.from(result);
  }
}
