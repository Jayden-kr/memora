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
    extends State<PushNotificationSettingsScreen> with WidgetsBindingObserver {
  bool _enabled = false;
  List<Folder> _folders = [];
  int? _selectedFolderId;
  bool _soundEnabled = true;
  bool _loading = true;
  bool _saving = false;
  // 기본값 true — 실제 체크가 끝나기 전까지 경고 카드가 잠깐 보였다 사라지는 깜빡임 방지.
  bool _exactAlarmPermitted = true;

  TimeOfDay _intervalStartTime = const TimeOfDay(hour: 9, minute: 0);
  TimeOfDay _intervalEndTime = const TimeOfDay(hour: 22, minute: 0);
  final TextEditingController _intervalMinController =
      TextEditingController(text: '30');

  static const _settingNotificationEnabled = 'notification_enabled';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadData();
    _checkExactAlarmPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final hadPendingSettings = _settingsDebounce?.isActive ?? false;
    _settingsDebounce?.cancel();
    if (hadPendingSettings) {
      // 대기 중이던 debounce를 flush — 그냥 취소만 하면 폴더/사운드 변경이
      // DB에 반영되지 않은 채 화면을 벗어나 유실된다. context/setState를 쓰지
      // 않으므로 dispose 이후에도 fire-and-forget으로 안전하게 완료 가능.
      _applyGlobalSettings();
    }
    _intervalMinController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 사용자가 '알람 및 리마인더' 설정 화면에 다녀온 뒤 이 화면으로 돌아왔을 때
    // 재확인 — 설정 변경은 이 화면으로 돌아와야 알 수 있으므로 resume 시점에 체크.
    if (state == AppLifecycleState.resumed) {
      _checkExactAlarmPermission();
    }
  }

  Future<void> _checkExactAlarmPermission() async {
    final permitted = await NotificationService.canScheduleExactAlarms();
    if (!mounted) return;
    setState(() => _exactAlarmPermitted = permitted);
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

  Future<bool> _saveIntervalAlarm() async {
    if (_saving) return false;
    final t = AppLocalizations.of(context);

    final intervalMin = int.tryParse(_intervalMinController.text);
    // NotificationService._rescheduleAllImpl의 범위(5~1440분)와 동일하게 검증 —
    // 그렇지 않으면 저장은 성공 처리되지만 스케줄러가 알람을 거부해 서비스가
    // 조용히 중지된다.
    if (intervalMin == null || intervalMin < 5 || intervalMin > 1440) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.pushIntervalMinError)),
      );
      return false;
    }

    final startMinutes =
        _intervalStartTime.hour * 60 + _intervalStartTime.minute;
    final endMinutes = _intervalEndTime.hour * 60 + _intervalEndTime.minute;
    if (endMinutes == startMinutes) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.pushTimeSameError)),
      );
      return false;
    }

    setState(() => _saving = true);
    try {
      await DatabaseHelper.instance
          .upsertSetting(_settingNotificationEnabled, _enabled.toString());

      final startStr = _formatTime(_intervalStartTime);
      final endStr = _formatTime(_intervalEndTime);

      // delete+insert를 단일 트랜잭션으로 묶어 원자적으로 교체 — 화면이 중간에
      // dispose되거나 insert가 실패해도 기존 알람이 삭제된 채로 남지 않음.
      await DatabaseHelper.instance.replaceIntervalAlarm(
        time: startStr,
        startTime: startStr,
        endTime: endStr,
        intervalMin: intervalMin,
        folderId: _selectedFolderId,
        soundEnabled: _soundEnabled ? 1 : 0,
      );

      // DB 커밋 이후의 재스케줄은 화면 dispose 여부와 무관하게 항상 실행
      // (그렇지 않으면 서비스가 새로 저장된 알람을 반영하지 못한 채로 남음).
      await NotificationService.rescheduleAll();

      if (!mounted) return true;

      try {
        const channel = MethodChannel('com.henry.memora/push_notif');
        await channel.invokeMethod<bool>('requestBatteryOptimization');
      } catch (_) {}

      if (!mounted) return true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.pushSaveSuccess)),
      );
      return true;
    } catch (e) {
      debugPrint('[PUSH_SETTINGS] save failed: $e');
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.pushSaveFail)),
      );
      return false;
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
    // NOTE: context나 setState를 쓰지 않으므로 mounted 가드 불필요 — dispose()가
    // 대기 중인 debounce를 flush할 때도(#20) 안전하게 끝까지 실행되어야 한다.
    try {
      final allAlarms = await DatabaseHelper.instance.getAllPushAlarms();
      for (final alarm in allAlarms) {
        await DatabaseHelper.instance.updatePushAlarm(alarm['id'] as int, {
          'folder_id': _selectedFolderId,
          'sound_enabled': _soundEnabled ? 1 : 0,
        });
      }
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
                if (!_exactAlarmPermitted) _buildExactAlarmPrompt(t),

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
                            // Fresh-install trap: 저장된 알람이 하나도 없으면
                            // rescheduleAll이 빈 알람 목록에서 조용히 반환돼
                            // 토글만 켜질 뿐 실제로는 아무 것도 예약되지 않는다.
                            // Save 버튼과 동일한 경로로 현재 UI 값을 기본
                            // interval 알람으로 저장해 실제로 동작하게 한다.
                            final existingAlarms =
                                await DatabaseHelper.instance.getAllPushAlarms();
                            if (!mounted) return;
                            if (v && existingAlarms.isEmpty) {
                              final created = await _saveIntervalAlarm();
                              if (!created) {
                                // 검증 실패로 알람이 생성되지 않음 — 토글만
                                // ON으로 남고 알람 0개인 상태(#39가 고치려던
                                // 무음 no-op)가 재발하지 않도록 되돌린다.
                                await DatabaseHelper.instance.upsertSetting(
                                    _settingNotificationEnabled,
                                    previousEnabled.toString());
                                if (mounted) {
                                  setState(() => _enabled = previousEnabled);
                                  messenger.showSnackBar(
                                    SnackBar(content: Text(t.pushToggleFail)),
                                  );
                                }
                              }
                            } else {
                              await NotificationService.rescheduleAll();
                            }
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

  /// API 33+에서 SCHEDULE_EXACT_ALARM이 자동 부여되지 않아 사용자가 직접
  /// '알람 및 리마인더'를 허용해야 하는 경우 보여주는 안내 카드.
  /// API 31 미만은 canScheduleExactAlarms가 항상 true를 반환하므로 노출되지 않는다.
  Widget _buildExactAlarmPrompt(AppLocalizations t) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark
        ? Colors.amber.shade900.withValues(alpha: 0.25)
        : Colors.amber.shade50;
    final fg = isDark ? Colors.amber.shade200 : Colors.amber.shade900;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Card(
        color: bg,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: Colors.amber.shade400.withValues(alpha: 0.4)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, color: fg),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.pushExactAlarmTitle,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: fg,
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      t.pushExactAlarmBody,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: fg),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: fg,
                          side: BorderSide(color: fg),
                        ),
                        onPressed: () async {
                          await NotificationService.openExactAlarmSettings();
                          // 설정 화면이 별도 앱 화면이 아니라 다이얼로그로 뜨는
                          // 일부 기기 대비 즉시 1회 재확인 (주 경로는 위의
                          // didChangeAppLifecycleState resumed 콜백).
                          await _checkExactAlarmPermission();
                        },
                        child: Text(t.pushExactAlarmButton),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
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
