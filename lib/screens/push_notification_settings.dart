import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../database/database_helper.dart';
import '../l10n/app_localizations.dart';
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
  bool _enabled = false;
  List<Folder> _folders = [];
  int? _selectedFolderId;
  bool _soundEnabled = true;
  bool _loading = true;
  bool _saving = false;

  TimeOfDay _intervalStartTime = const TimeOfDay(hour: 9, minute: 0);
  TimeOfDay _intervalEndTime = const TimeOfDay(hour: 22, minute: 0);
  final TextEditingController _intervalMinController =
      TextEditingController(text: '30');

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
    List<Map<String, dynamic>> alarms;
    List<Folder> folders;
    Map<String, String> settings;
    try {
      alarms = await DatabaseHelper.instance.getAllPushAlarms();
      folders = await DatabaseHelper.instance.getNonBundleFolders();
      settings = await DatabaseHelper.instance.getAllSettings();
    } catch (e) {
      debugPrint('[PUSH_SETTINGS] _loadData DB error: $e');
      if (!mounted) return;
      setState(() => _loading = false);
      return;
    }
    if (!mounted) return;

    _enabled = (settings[_settingNotificationEnabled] ?? '').toLowerCase() == 'true';

    Map<String, dynamic>? intervalAlarm;
    for (final alarm in alarms) {
      if ((alarm['mode'] as String? ?? 'fixed') == 'interval') {
        intervalAlarm = alarm;
        break;
      }
    }

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

    if (intervalAlarm != null) {
      _parseAndSetTime(
        intervalAlarm['start_time'] as String?,
        (t) => _intervalStartTime = t,
      );
      _parseAndSetTime(
        intervalAlarm['end_time'] as String?,
        (t) => _intervalEndTime = t,
      );
      final intMin = intervalAlarm['interval_min'] as int?;
      if (intMin != null && intMin >= 5) {
        _intervalMinController.text = intMin.toString();
      }
    }

    setState(() {
      _folders = folders;
      _loading = false;
    });
  }

  void _parseAndSetTime(String? timeStr, void Function(TimeOfDay) setter) {
    if (timeStr == null || !timeStr.contains(':')) return;
    final parts = timeStr.split(':');
    if (parts.length != 2) return;
    final h = int.tryParse(parts[0].trim());
    final m = int.tryParse(parts[1].trim());
    if (h != null && m != null && h >= 0 && h < 24 && m >= 0 && m < 60) {
      setter(TimeOfDay(hour: h, minute: m));
    }
  }

  // ─── Interval mode ───

  Future<void> _saveIntervalAlarm() async {
    if (_saving) return;
    final t = AppLocalizations.of(context);

    final intervalMin = int.tryParse(_intervalMinController.text);
    if (intervalMin == null || intervalMin < 5) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.pushIntervalMinError)),
      );
      return;
    }

    final startMinutes =
        _intervalStartTime.hour * 60 + _intervalStartTime.minute;
    final endMinutes = _intervalEndTime.hour * 60 + _intervalEndTime.minute;
    if (endMinutes == startMinutes) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.pushTimeSameError)),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      await DatabaseHelper.instance
          .upsertSetting(_settingNotificationEnabled, _enabled.toString());

      final startStr = _formatTime(_intervalStartTime);
      final endStr = _formatTime(_intervalEndTime);

      final existingAlarms = await DatabaseHelper.instance.getAllPushAlarms();
      for (final alarm in existingAlarms) {
        if (!mounted) return;
        if ((alarm['mode'] as String? ?? 'fixed') == 'interval') {
          await DatabaseHelper.instance.deletePushAlarm(alarm['id'] as int);
        }
      }
      if (!mounted) return;

      await DatabaseHelper.instance.insertPushAlarm(
        time: startStr,
        mode: 'interval',
        startTime: startStr,
        endTime: endStr,
        intervalMin: intervalMin,
        folderId: _selectedFolderId,
        soundEnabled: _soundEnabled ? 1 : 0,
      );

      if (!mounted) return;

      await NotificationService.rescheduleAll();
      if (!mounted) return;

      try {
        const channel = MethodChannel('com.henry.memora/push_notif');
        await channel.invokeMethod<bool>('requestBatteryOptimization');
      } catch (_) {}

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.pushSaveSuccess)),
      );
    } catch (e) {
      debugPrint('[PUSH_SETTINGS] save failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.pushSaveFail)),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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
    if (!mounted) return;
    try {
      final allAlarms = await DatabaseHelper.instance.getAllPushAlarms();
      for (final alarm in allAlarms) {
        await DatabaseHelper.instance.updatePushAlarm(alarm['id'] as int, {
          'folder_id': _selectedFolderId,
          'sound_enabled': _soundEnabled ? 1 : 0,
        });
      }
      if (!mounted) return;
      await NotificationService.rescheduleAll();
    } catch (e) {
      debugPrint('[PUSH_SETTINGS] global settings apply failed: $e');
    }
  }

  String _formatTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  int get _intervalSlotCount {
    final intervalMin = int.tryParse(_intervalMinController.text) ?? 0;
    if (intervalMin < 5 || intervalMin > 1440) return 0;
    final startTotal =
        _intervalStartTime.hour * 60 + _intervalStartTime.minute;
    final endTotal = _intervalEndTime.hour * 60 + _intervalEndTime.minute;
    if (endTotal == startTotal) return 0;
    final span = endTotal > startTotal
        ? endTotal - startTotal
        : (1440 - startTotal) + endTotal;
    return (span ~/ intervalMin) + 1;
  }

  // ─── Build ───

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.pushTitle),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                ListTile(
                  title: Text(t.pushAlarm),
                  trailing: Transform.scale(
                    scale: 0.8,
                    child: Switch(
                      value: _enabled,
                      onChanged: (v) async {
                        final messenger = ScaffoldMessenger.of(context);
                        try {
                          if (v) {
                            final granted =
                                await NotificationService.requestPermission();
                            if (!granted) {
                              if (!mounted) return;
                              messenger.showSnackBar(
                                SnackBar(
                                  content: Text(t.pushNeedPermission),
                                  action: SnackBarAction(
                                    label: t.pushOpenSettings,
                                    onPressed: () => openAppSettings(),
                                  ),
                                ),
                              );
                              return;
                            }
                          }
                          if (!mounted) return;
                          final previousEnabled = _enabled;
                          setState(() => _enabled = v);
                          try {
                            await DatabaseHelper.instance.upsertSetting(
                                _settingNotificationEnabled, v.toString());
                            if (!mounted) return;
                            await NotificationService.rescheduleAll();
                          } catch (e) {
                            debugPrint('[PUSH_SETTINGS] toggle failed: $e');
                            if (!mounted) return;
                            setState(() => _enabled = previousEnabled);
                            messenger.showSnackBar(
                              SnackBar(content: Text(t.pushToggleFail)),
                            );
                          }
                        } catch (e) {
                          debugPrint('[PUSH_SETTINGS] toggle error: $e');
                          if (!mounted) return;
                          messenger.showSnackBar(
                            SnackBar(content: Text(t.pushToggleFail)),
                          );
                        }
                      },
                    ),
                  ),
                ),
                const Divider(),

                ..._buildIntervalModeUI(t),

                const Divider(),

                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(t.pushFolder,
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: DropdownButton<int?>(
                    isExpanded: true,
                    value: (_selectedFolderId != null &&
                            _folders.any((f) => f.id == _selectedFolderId))
                        ? _selectedFolderId
                        : null,
                    hint: Text(t.pushAllFolders),
                    items: [
                      DropdownMenuItem(
                        value: null,
                        child: Text(t.pushAllFolders),
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

                ListTile(
                  title: Text(t.pushSendTest),
                  leading: Icon(Icons.notifications_active,
                      color: _enabled ? null : Theme.of(context).disabledColor),
                  enabled: _enabled,
                  onTap: _enabled
                      ? () async {
                          final messenger = ScaffoldMessenger.of(context);
                          await NotificationService.showTestNotification();
                          if (!mounted) return;
                          messenger.showSnackBar(
                            SnackBar(content: Text(t.pushTestSent)),
                          );
                        }
                      : null,
                ),
                const Divider(),

                ListTile(
                  title: Text(t.pushSound),
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

  List<Widget> _buildIntervalModeUI(AppLocalizations t) {
    final count = _intervalSlotCount;

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text(t.pushIntervalSetting,
            style: Theme.of(context).textTheme.titleSmall),
      ),

      ListTile(
        title: Text(t.pushIntervalStart),
        trailing: TextButton(
          onPressed: () async {
            final tod = await showTimePicker(
              context: context,
              initialTime: _intervalStartTime,
            );
            if (tod != null && mounted) setState(() => _intervalStartTime = tod);
          },
          child: Text(
            _formatTime(_intervalStartTime),
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      ),

      ListTile(
        title: Text(t.pushIntervalEnd),
        trailing: TextButton(
          onPressed: () async {
            final tod = await showTimePicker(
              context: context,
              initialTime: _intervalEndTime,
            );
            if (tod != null && mounted) setState(() => _intervalEndTime = tod);
          },
          child: Text(
            _formatTime(_intervalEndTime),
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      ),

      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Text(t.pushIntervalLabel),
            const SizedBox(width: 16),
            SizedBox(
              width: 80,
              child: TextField(
                controller: _intervalMinController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                textAlign: TextAlign.center,
                decoration: InputDecoration(
                  suffixText: t.pushIntervalMinutes,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 10),
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            if (count > 0)
              Text(
                t.pushIntervalDailyCount(count),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
          ],
        ),
      ),

      if (count > 0)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            t.pushIntervalPreview(
              _formatTime(_intervalStartTime),
              _formatTime(_intervalEndTime),
              _intervalMinController.text,
            ),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
          ),
        ),

      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: FilledButton.icon(
          onPressed: (_enabled && !_saving) ? _saveIntervalAlarm : null,
          icon: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save),
          label: Text(_saving ? t.pushSaving : t.commonSave),
        ),
      ),
    ];
  }
}
