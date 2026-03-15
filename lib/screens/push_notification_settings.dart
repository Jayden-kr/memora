import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../database/database_helper.dart';
import '../models/folder.dart';
import '../services/notification_service.dart';

class PushNotificationSettingsScreen extends StatefulWidget {
  const PushNotificationSettingsScreen({super.key});

  @override
  State<PushNotificationSettingsScreen> createState() =>
      _PushNotificationSettingsScreenState();
}

class _PushNotificationSettingsScreenState
    extends State<PushNotificationSettingsScreen> {
  bool _enabled = true;
  List<Folder> _folders = [];
  int? _selectedFolderId;
  bool _soundEnabled = true;
  bool _loading = true;

  // 간격 반복 설정
  TimeOfDay _intervalStartTime = const TimeOfDay(hour: 9, minute: 0);
  TimeOfDay _intervalEndTime = const TimeOfDay(hour: 22, minute: 0);
  final TextEditingController _intervalMinController =
      TextEditingController(text: '30');
  int? _intervalAlarmId;
  bool _intervalEnabled = true;

  static const _settingNotificationEnabled = 'notification_enabled';

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _settingsDebounce?.cancel();
    _intervalMinController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final alarms = await DatabaseHelper.instance.getAllPushAlarms();
    final folders = await DatabaseHelper.instance.getNonBundleFolders();
    final settings = await DatabaseHelper.instance.getAllSettings();
    if (!mounted) return;

    final enabledStr = settings[_settingNotificationEnabled];
    if (enabledStr != null) {
      _enabled = enabledStr == 'true';
    }

    // interval 알람 찾기
    Map<String, dynamic>? intervalAlarm;
    for (final alarm in alarms) {
      if ((alarm['mode'] as String? ?? 'fixed') == 'interval') {
        intervalAlarm = alarm;
        break;
      }
    }

    // 글로벌 설정 복원
    if (alarms.isNotEmpty) {
      final first = alarms.first;
      final restoredFolderId = first['folder_id'] as int?;
      if (restoredFolderId != null &&
          folders.any((f) => f.id == restoredFolderId)) {
        _selectedFolderId = restoredFolderId;
      } else {
        _selectedFolderId = null;
      }
      _soundEnabled = (first['sound_enabled'] as int? ?? 1) == 1;
    }

    // 간격 알람 복원
    if (intervalAlarm != null) {
      _intervalAlarmId = intervalAlarm['id'] as int;
      _intervalEnabled = (intervalAlarm['enabled'] as int? ?? 1) == 1;
      final startStr = intervalAlarm['start_time'] as String?;
      final endStr = intervalAlarm['end_time'] as String?;
      final intMin = intervalAlarm['interval_min'] as int?;
      if (startStr != null && startStr.contains(':')) {
        final sp = startStr.split(':');
        final h = int.tryParse(sp[0]);
        final m = sp.length > 1 ? int.tryParse(sp[1]) : null;
        if (h != null && m != null) {
          _intervalStartTime = TimeOfDay(hour: h, minute: m);
        }
      }
      if (endStr != null && endStr.contains(':')) {
        final ep = endStr.split(':');
        final h = int.tryParse(ep[0]);
        final m = ep.length > 1 ? int.tryParse(ep[1]) : null;
        if (h != null && m != null) {
          _intervalEndTime = TimeOfDay(hour: h, minute: m);
        }
      }
      if (intMin != null) {
        _intervalMinController.text = intMin.toString();
      }
    }

    setState(() {
      _folders = folders;
      _loading = false;
    });
  }

  // ─── Interval mode ───

  Future<void> _saveIntervalAlarm() async {
    final intervalMin = int.tryParse(_intervalMinController.text);
    if (intervalMin == null || intervalMin < 5) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('간격은 최소 5분이어야 합니다.')),
      );
      return;
    }

    final startMinutes =
        _intervalStartTime.hour * 60 + _intervalStartTime.minute;
    final endMinutes = _intervalEndTime.hour * 60 + _intervalEndTime.minute;
    if (endMinutes <= startMinutes) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('종료 시간은 시작 시간보다 이후여야 합니다.')),
      );
      return;
    }

    try {
      await DatabaseHelper.instance
          .upsertSetting(_settingNotificationEnabled, _enabled.toString());

      final startStr =
          '${_intervalStartTime.hour.toString().padLeft(2, '0')}:${_intervalStartTime.minute.toString().padLeft(2, '0')}';
      final endStr =
          '${_intervalEndTime.hour.toString().padLeft(2, '0')}:${_intervalEndTime.minute.toString().padLeft(2, '0')}';

      // 기존 interval 알람 삭제 후 새로 1개만 생성 (누적 방지)
      final existingAlarms = await DatabaseHelper.instance.getAllPushAlarms();
      for (final alarm in existingAlarms) {
        if ((alarm['mode'] as String? ?? 'fixed') == 'interval') {
          await DatabaseHelper.instance.deletePushAlarm(alarm['id'] as int);
        }
      }

      final newId = await DatabaseHelper.instance.insertPushAlarm(
        time: startStr,
        mode: 'interval',
        startTime: startStr,
        endTime: endStr,
        intervalMin: intervalMin,
        folderId: _selectedFolderId,
        soundEnabled: _soundEnabled ? 1 : 0,
      );
      _intervalAlarmId = newId;

      await _loadData();
      await NotificationService.rescheduleAll();

      // Samsung 등에서 배터리 최적화 해제 요청
      try {
        const channel = MethodChannel('com.henry.amki_wang/push_notif');
        await channel.invokeMethod<bool>('requestBatteryOptimization');
      } catch (_) {}

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('간격 반복 알림이 저장되었습니다.')),
      );
    } catch (e) {
      debugPrint('[PUSH_SETTINGS] 저장 실패: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('저장 실패: $e')),
      );
    }
  }

  Future<void> _toggleIntervalAlarm(bool enabled) async {
    if (_intervalAlarmId == null) return;
    setState(() => _intervalEnabled = enabled);
    await DatabaseHelper.instance.updatePushAlarm(_intervalAlarmId!, {
      'enabled': enabled ? 1 : 0,
    });
    await NotificationService.rescheduleAll();
  }

  // ─── Common ───

  Timer? _settingsDebounce;

  void _updateGlobalSettings() {
    _settingsDebounce?.cancel();
    _settingsDebounce = Timer(const Duration(milliseconds: 500), () {
      if (mounted) _applyGlobalSettings();
    });
  }

  Future<void> _applyGlobalSettings() async {
    final allAlarms = await DatabaseHelper.instance.getAllPushAlarms();
    for (final alarm in allAlarms) {
      await DatabaseHelper.instance.updatePushAlarm(alarm['id'] as int, {
        'folder_id': _selectedFolderId,
        'sound_enabled': _soundEnabled ? 1 : 0,
      });
    }
    await NotificationService.rescheduleAll();
  }

  String _formatTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  int get _intervalSlotCount {
    final intervalMin = int.tryParse(_intervalMinController.text) ?? 0;
    if (intervalMin < 5) return 0;
    final startTotal =
        _intervalStartTime.hour * 60 + _intervalStartTime.minute;
    final endTotal = _intervalEndTime.hour * 60 + _intervalEndTime.minute;
    if (endTotal <= startTotal) return 0;
    return ((endTotal - startTotal) ~/ intervalMin) + 1;
  }

  // ─── Build ───

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('카드 푸시 알림'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                // 알림 ON/OFF
                ListTile(
                  title: const Text('알림'),
                  trailing: Transform.scale(
                    scale: 0.8,
                    child: Switch(
                      value: _enabled,
                      onChanged: (v) async {
                        if (v) {
                          final messenger = ScaffoldMessenger.of(context);
                          final granted =
                              await NotificationService.requestPermission();
                          if (!granted) {
                            if (!mounted) return;
                            messenger.showSnackBar(
                              SnackBar(
                                content: const Text('알림 권한이 필요합니다.'),
                                action: SnackBarAction(
                                  label: '설정 열기',
                                  onPressed: () => openAppSettings(),
                                ),
                              ),
                            );
                            return;
                          }
                        }
                        if (!mounted) return;
                        setState(() => _enabled = v);
                        await DatabaseHelper.instance.upsertSetting(
                            _settingNotificationEnabled, v.toString());
                        await NotificationService.rescheduleAll();
                      },
                    ),
                  ),
                ),
                const Divider(),

                // 간격 반복 설정
                ..._buildIntervalModeUI(),

                const Divider(),

                // 폴더 선택
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text('폴더',
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: DropdownButton<int?>(
                    isExpanded: true,
                    value: _selectedFolderId,
                    hint: const Text('전체 폴더'),
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('전체 폴더'),
                      ),
                      ..._folders.map((f) => DropdownMenuItem(
                            value: f.id,
                            child: Text(f.name),
                          )),
                    ],
                    onChanged: (v) {
                      setState(() => _selectedFolderId = v);
                      _updateGlobalSettings();
                    },
                  ),
                ),
                const Divider(),

                // 테스트 알림
                ListTile(
                  title: const Text('테스트 알림 보내기'),
                  leading: const Icon(Icons.notifications_active),
                  onTap: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    await NotificationService.showTestNotification();
                    if (!mounted) return;
                    messenger.showSnackBar(
                      const SnackBar(content: Text('테스트 알림을 보냈습니다.')),
                    );
                  },
                ),
                const Divider(),

                // 알림음
                ListTile(
                  title: const Text('알림음'),
                  trailing: Transform.scale(
                    scale: 0.8,
                    child: Switch(
                      value: _soundEnabled,
                      onChanged: (v) {
                        setState(() => _soundEnabled = v);
                        _updateGlobalSettings();
                      },
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  List<Widget> _buildIntervalModeUI() {
    final count = _intervalSlotCount;

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text('간격 반복 설정',
            style: Theme.of(context).textTheme.titleSmall),
      ),

      // ON/OFF (저장된 간격 알람이 있을 때만)
      if (_intervalAlarmId != null)
        ListTile(
          title: const Text('간격 반복 알림'),
          trailing: Transform.scale(
            scale: 0.8,
            child: Switch(
              value: _intervalEnabled,
              onChanged: (v) => _toggleIntervalAlarm(v),
            ),
          ),
        ),

      // 시작 시간
      ListTile(
        title: const Text('시작 시간'),
        trailing: TextButton(
          onPressed: () async {
            final t = await showTimePicker(
              context: context,
              initialTime: _intervalStartTime,
            );
            if (t != null && mounted) setState(() => _intervalStartTime = t);
          },
          child: Text(
            _formatTime(_intervalStartTime),
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      ),

      // 종료 시간
      ListTile(
        title: const Text('종료 시간'),
        trailing: TextButton(
          onPressed: () async {
            final t = await showTimePicker(
              context: context,
              initialTime: _intervalEndTime,
            );
            if (t != null && mounted) setState(() => _intervalEndTime = t);
          },
          child: Text(
            _formatTime(_intervalEndTime),
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      ),

      // 간격 입력
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            const Text('간격'),
            const SizedBox(width: 16),
            SizedBox(
              width: 80,
              child: TextField(
                controller: _intervalMinController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                textAlign: TextAlign.center,
                decoration: const InputDecoration(
                  suffixText: '분',
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            if (count > 0)
              Text(
                '(하루 $count회)',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
          ],
        ),
      ),

      // 미리보기
      if (count > 0)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            '${_formatTime(_intervalStartTime)} ~ ${_formatTime(_intervalEndTime)}, ${_intervalMinController.text}분마다',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
          ),
        ),

      // 저장 버튼
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: FilledButton.icon(
          onPressed: _saveIntervalAlarm,
          icon: const Icon(Icons.save),
          label: const Text('저장'),
        ),
      ),
    ];
  }
}
