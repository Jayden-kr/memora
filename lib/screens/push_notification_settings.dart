import 'package:flutter/material.dart';

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
  List<Map<String, dynamic>> _alarms = [];
  List<Folder> _folders = [];
  int? _selectedFolderId;
  bool _soundEnabled = true;
  final Set<int> _selectedDays = {1, 2, 3, 4, 5}; // 월~금
  bool _loading = true;

  static const _settingNotificationEnabled = 'notification_enabled';

  static const _dayLabels = ['일', '월', '화', '수', '목', '금', '토'];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final alarms = await DatabaseHelper.instance.getAllPushAlarms();
    final folders = await DatabaseHelper.instance.getNonBundleFolders();
    final settings = await DatabaseHelper.instance.getAllSettings();
    if (!mounted) return;

    // 알림 ON/OFF 상태 복원
    final enabledStr = settings[_settingNotificationEnabled];
    if (enabledStr != null) {
      _enabled = enabledStr == 'true';
    }

    // 첫 번째 알람에서 글로벌 설정 복원
    if (alarms.isNotEmpty) {
      final first = alarms.first;
      final daysStr = first['days'] as String?;
      if (daysStr != null && daysStr.isNotEmpty) {
        _selectedDays.clear();
        for (final d in daysStr.split(',')) {
          final parsed = int.tryParse(d.trim());
          if (parsed != null) _selectedDays.add(parsed);
        }
      }
      _selectedFolderId = first['folder_id'] as int?;
      _soundEnabled = (first['sound_enabled'] as int? ?? 1) == 1;
    }

    setState(() {
      _alarms = alarms;
      _folders = folders;
      _loading = false;
    });
  }

  Future<void> _addAlarm() async {
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (time == null) return;

    final timeStr =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    await DatabaseHelper.instance.insertPushAlarm(
      time: timeStr,
      folderId: _selectedFolderId,
      days: _selectedDays.join(','),
      soundEnabled: _soundEnabled ? 1 : 0,
    );
    await _loadData();
    await _scheduleAlarms();
  }

  Future<void> _deleteAlarm(int id) async {
    await NotificationService.cancelNotification(id);
    await DatabaseHelper.instance.deletePushAlarm(id);
    await _loadData();
  }

  Future<void> _toggleAlarm(int id, bool enabled) async {
    await DatabaseHelper.instance.updatePushAlarm(id, {
      'enabled': enabled ? 1 : 0,
    });
    await _loadData();
    await _scheduleAlarms();
  }

  /// 글로벌 설정 변경 시 모든 알람에 반영
  Future<void> _updateGlobalSettings() async {
    final daysStr = _selectedDays.join(',');
    for (final alarm in _alarms) {
      await DatabaseHelper.instance.updatePushAlarm(alarm['id'] as int, {
        'folder_id': _selectedFolderId,
        'days': daysStr,
        'sound_enabled': _soundEnabled ? 1 : 0,
      });
    }
    await _scheduleAlarms();
  }

  Future<void> _scheduleAlarms() async {
    await NotificationService.cancelAllNotifications();

    if (!_enabled) return;

    for (final alarm in _alarms) {
      if ((alarm['enabled'] as int? ?? 1) != 1) continue;

      final timeStr = alarm['time'] as String;
      final parts = timeStr.split(':');
      final hour = int.parse(parts[0]);
      final minute = int.parse(parts[1]);
      final id = alarm['id'] as int;

      // 알람별 요일 파싱
      final daysStr = alarm['days'] as String?;
      Set<int>? days;
      if (daysStr != null && daysStr.isNotEmpty) {
        days = daysStr
            .split(',')
            .map((d) => int.tryParse(d.trim()))
            .whereType<int>()
            .toSet();
      }

      final folderId = alarm['folder_id'] as int?;
      final soundEnabled = (alarm['sound_enabled'] as int? ?? 1) == 1;

      await NotificationService.scheduleDailyNotification(
        id: id,
        hour: hour,
        minute: minute,
        days: days,
        folderId: folderId,
        soundEnabled: soundEnabled,
      );
    }
  }

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
                SwitchListTile(
                  title: const Text('알림'),
                  value: _enabled,
                  onChanged: (v) {
                    setState(() => _enabled = v);
                    DatabaseHelper.instance.upsertSetting(
                        _settingNotificationEnabled, v.toString());
                    _scheduleAlarms();
                  },
                ),
                const Divider(),

                // 반복 요일
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text('반복 요일',
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Wrap(
                    spacing: 8,
                    children: List.generate(7, (index) {
                      final selected = _selectedDays.contains(index);
                      return ChoiceChip(
                        label: Text(_dayLabels[index]),
                        selected: selected,
                        onSelected: (s) {
                          setState(() {
                            if (s) {
                              _selectedDays.add(index);
                            } else {
                              _selectedDays.remove(index);
                            }
                          });
                          _updateGlobalSettings();
                        },
                      );
                    }),
                  ),
                ),
                const Divider(),

                // 시간 알람 리스트
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text('시간 알람',
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                ..._alarms.map((alarm) {
                  final id = alarm['id'] as int;
                  final time = alarm['time'] as String;
                  final enabled = (alarm['enabled'] as int? ?? 1) == 1;
                  return ListTile(
                    title: Text(time,
                        style: Theme.of(context).textTheme.titleLarge),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Switch(
                          value: enabled,
                          onChanged: (v) => _toggleAlarm(id, v),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete),
                          onPressed: () => _deleteAlarm(id),
                        ),
                      ],
                    ),
                  );
                }),
                ListTile(
                  leading: const Icon(Icons.add),
                  title: const Text('알람 추가'),
                  onTap: _addAlarm,
                ),
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

                // 알림음
                SwitchListTile(
                  title: const Text('알림음'),
                  value: _soundEnabled,
                  onChanged: (v) {
                    setState(() => _soundEnabled = v);
                    _updateGlobalSettings();
                  },
                ),
              ],
            ),
    );
  }
}
