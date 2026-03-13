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
  String _mode = 'fixed'; // 'fixed' or 'interval'
  List<Map<String, dynamic>> _fixedAlarms = [];
  List<Folder> _folders = [];
  int? _selectedFolderId;
  bool _soundEnabled = true;
  final Set<int> _selectedDays = {1, 2, 3, 4, 5}; // 월~금
  bool _loading = true;

  // 간격 반복 설정
  TimeOfDay _intervalStartTime = const TimeOfDay(hour: 9, minute: 0);
  TimeOfDay _intervalEndTime = const TimeOfDay(hour: 22, minute: 0);
  final TextEditingController _intervalMinController =
      TextEditingController(text: '30');
  int? _intervalAlarmId; // DB에 저장된 interval alarm의 id
  bool _intervalEnabled = true;

  static const _settingNotificationEnabled = 'notification_enabled';
  static const _dayLabels = ['일', '월', '화', '수', '목', '금', '토'];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _globalSettingsDebounce?.cancel();
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

    // 알람을 모드별로 분리
    final fixedAlarms = <Map<String, dynamic>>[];
    Map<String, dynamic>? intervalAlarm;
    for (final alarm in alarms) {
      final mode = alarm['mode'] as String? ?? 'fixed';
      if (mode == 'interval') {
        intervalAlarm = alarm;
      } else {
        fixedAlarms.add(alarm);
      }
    }

    // 글로벌 설정 복원 (첫 번째 알람 기준)
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
      _fixedAlarms = fixedAlarms;
      _folders = folders;
      _loading = false;
    });
  }

  // ─── Fixed mode ───

  Future<void> _addFixedAlarm() async {
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
    await _scheduleAll();
  }

  Future<void> _deleteFixedAlarm(int id) async {
    await NotificationService.cancelNotification(id);
    await DatabaseHelper.instance.deletePushAlarm(id);
    await _loadData();
  }

  Future<void> _toggleFixedAlarm(int id, bool enabled) async {
    await DatabaseHelper.instance.updatePushAlarm(id, {
      'enabled': enabled ? 1 : 0,
    });
    await _loadData();
    await _scheduleAll();
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

    final startStr =
        '${_intervalStartTime.hour.toString().padLeft(2, '0')}:${_intervalStartTime.minute.toString().padLeft(2, '0')}';
    final endStr =
        '${_intervalEndTime.hour.toString().padLeft(2, '0')}:${_intervalEndTime.minute.toString().padLeft(2, '0')}';

    if (_intervalAlarmId != null) {
      await DatabaseHelper.instance.updatePushAlarm(_intervalAlarmId!, {
        'start_time': startStr,
        'end_time': endStr,
        'interval_min': intervalMin,
        'time': startStr,
        'folder_id': _selectedFolderId,
        'days': _selectedDays.join(','),
        'sound_enabled': _soundEnabled ? 1 : 0,
      });
    } else {
      await DatabaseHelper.instance.insertPushAlarm(
        time: startStr,
        mode: 'interval',
        startTime: startStr,
        endTime: endStr,
        intervalMin: intervalMin,
        folderId: _selectedFolderId,
        days: _selectedDays.join(','),
        soundEnabled: _soundEnabled ? 1 : 0,
      );
    }

    await _loadData();
    await _scheduleAll();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('간격 반복 알림이 저장되었습니다.')),
    );
  }

  Future<void> _deleteIntervalAlarm() async {
    if (_intervalAlarmId == null) return;
    await NotificationService.cancelNotification(_intervalAlarmId!);
    await DatabaseHelper.instance.deletePushAlarm(_intervalAlarmId!);
    _intervalAlarmId = null;
    _intervalEnabled = true;
    _intervalStartTime = const TimeOfDay(hour: 9, minute: 0);
    _intervalEndTime = const TimeOfDay(hour: 22, minute: 0);
    _intervalMinController.text = '30';
    await _loadData();
  }

  Future<void> _toggleIntervalAlarm(bool enabled) async {
    if (_intervalAlarmId == null) return;
    _intervalEnabled = enabled;
    await DatabaseHelper.instance.updatePushAlarm(_intervalAlarmId!, {
      'enabled': enabled ? 1 : 0,
    });
    await _loadData();
    await _scheduleAll();
  }

  // ─── Common ───

  Timer? _globalSettingsDebounce;

  void _updateGlobalSettings() {
    // 디바운싱: 빠른 연속 변경 시 마지막만 실제 적용 (500ms)
    _globalSettingsDebounce?.cancel();
    _globalSettingsDebounce = Timer(const Duration(milliseconds: 500), () {
      _applyGlobalSettings();
    });
  }

  Future<void> _applyGlobalSettings() async {
    final daysStr = _selectedDays.join(',');
    // 모든 알람 (fixed + interval) 업데이트
    final allAlarms = await DatabaseHelper.instance.getAllPushAlarms();
    for (final alarm in allAlarms) {
      await DatabaseHelper.instance.updatePushAlarm(alarm['id'] as int, {
        'folder_id': _selectedFolderId,
        'days': daysStr,
        'sound_enabled': _soundEnabled ? 1 : 0,
      });
    }
    await _scheduleAll();
  }

  Future<void> _scheduleAll() async {
    await NotificationService.cancelAllNotifications();
    if (!_enabled) return;

    final allAlarms = await DatabaseHelper.instance.getAllPushAlarms();
    for (final alarm in allAlarms) {
      if ((alarm['enabled'] as int? ?? 1) != 1) continue;

      final id = alarm['id'] as int;
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
      final mode = alarm['mode'] as String? ?? 'fixed';

      if (mode == 'interval') {
        final startTime = alarm['start_time'] as String?;
        final endTime = alarm['end_time'] as String?;
        final intervalMin = alarm['interval_min'] as int?;
        if (startTime == null || endTime == null || intervalMin == null) {
          continue;
        }
        final sp = startTime.split(':');
        final ep = endTime.split(':');
        if (sp.length < 2 || ep.length < 2) continue;
        await NotificationService.scheduleIntervalNotifications(
          id: id,
          startHour: int.tryParse(sp[0]) ?? 0,
          startMinute: int.tryParse(sp[1]) ?? 0,
          endHour: int.tryParse(ep[0]) ?? 0,
          endMinute: int.tryParse(ep[1]) ?? 0,
          intervalMin: intervalMin,
          days: days,
          folderId: folderId,
          soundEnabled: soundEnabled,
        );
      } else {
        final timeStr = alarm['time'] as String? ?? '08:00';
        final parts = timeStr.split(':');
        if (parts.length < 2) continue;
        await NotificationService.scheduleDailyNotification(
          id: id,
          hour: int.tryParse(parts[0]) ?? 0,
          minute: int.tryParse(parts[1]) ?? 0,
          days: days,
          folderId: folderId,
          soundEnabled: soundEnabled,
        );
      }
    }
  }

  String _formatTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  int get _intervalNotificationCount {
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
                          final granted =
                              await NotificationService.requestPermission();
                          if (!granted) {
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content:
                                    const Text('알림 권한이 필요합니다.'),
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
                        DatabaseHelper.instance.upsertSetting(
                            _settingNotificationEnabled, v.toString());
                        _scheduleAll();
                      },
                    ),
                  ),
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

                // 모드 선택
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text('알림 모드',
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                          value: 'fixed',
                          label: Text('시간 알람'),
                          icon: Icon(Icons.access_time)),
                      ButtonSegment(
                          value: 'interval',
                          label: Text('간격 반복'),
                          icon: Icon(Icons.repeat)),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (v) {
                      setState(() => _mode = v.first);
                    },
                  ),
                ),
                const Divider(),

                // 모드별 콘텐츠
                if (_mode == 'fixed') ..._buildFixedModeUI(),
                if (_mode == 'interval') ..._buildIntervalModeUI(),

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

  List<Widget> _buildFixedModeUI() {
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child:
            Text('시간 알람', style: Theme.of(context).textTheme.titleSmall),
      ),
      ..._fixedAlarms.map((alarm) {
        final id = alarm['id'] as int;
        final time = alarm['time'] as String;
        final enabled = (alarm['enabled'] as int? ?? 1) == 1;
        return ListTile(
          title:
              Text(time, style: Theme.of(context).textTheme.titleLarge),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Transform.scale(
                scale: 0.8,
                child: Switch(
                  value: enabled,
                  onChanged: (v) => _toggleFixedAlarm(id, v),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete),
                onPressed: () => _deleteFixedAlarm(id),
              ),
            ],
          ),
        );
      }),
      ListTile(
        leading: const Icon(Icons.add),
        title: const Text('알람 추가'),
        onTap: _addFixedAlarm,
      ),
    ];
  }

  List<Widget> _buildIntervalModeUI() {
    final count = _intervalNotificationCount;

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
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Transform.scale(
                scale: 0.8,
                child: Switch(
                  value: _intervalEnabled,
                  onChanged: (v) => _toggleIntervalAlarm(v),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete),
                onPressed: _deleteIntervalAlarm,
              ),
            ],
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
            if (t != null) setState(() => _intervalStartTime = t);
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
            if (t != null) setState(() => _intervalEndTime = t);
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
                '(하루 ${count}회)',
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
          label: Text(_intervalAlarmId != null ? '저장' : '설정 저장'),
        ),
      ),
    ];
  }
}
