import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../database/database_helper.dart';
import '../l10n/app_localizations.dart';
import '../models/folder.dart';
import '../services/notification_service.dart';
import '../services/push_schedule.dart';

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
  bool _soundEnabled = true;
  bool _loading = true;
  // 기본값 true — 실제 체크가 끝나기 전까지 경고 카드가 잠깐 보였다 사라지는 깜빡임 방지.
  bool _exactAlarmPermitted = true;

  // 알림 시간대 규칙 목록 (v1.3.9: 전역 기본값/마스터 활성시간창 없음 — 이 목록이
  // 유일한 스케줄 표현이다).
  List<PushRule> _rules = [];

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
      // 대기 중이던 debounce를 flush — 그냥 취소만 하면 규칙/사운드 변경이
      // DB에 반영되지 않은 채 화면을 벗어나 유실된다. context/setState를 쓰지
      // 않으므로 dispose 이후에도 fire-and-forget으로 안전하게 완료 가능.
      _applyGlobalSettings();
    }
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
    List<Folder> folders;
    Map<String, String> settings;
    try {
      folders = await DatabaseHelper.instance.getNonBundleFolders();
      settings = await DatabaseHelper.instance.getAllSettings();
    } catch (e) {
      debugPrint('[PUSH_SETTINGS] _loadData DB error: $e');
      if (!mounted) return;
      setState(() => _loading = false);
      return;
    }
    if (!mounted) return;

    _enabled =
        (settings[_settingNotificationEnabled] ?? '').toLowerCase() == 'true';
    // NOTE: 존재하지 않는 폴더를 가리키는 규칙을 여기서 걸러내지 않는다.
    // getNonBundleFolders()가 부분 실패로 일부만 반환하면 그 필터가 사용자의
    // 규칙을 조용히 지워버리기 때문. 문제가 있으면 화면에 빨갛게 보여줘서
    // (_buildPushRuleTile) 사용자가 직접 고치게 한다.
    _rules = PushSchedule.decode(settings[PushSchedule.settingRulesKey]);
    final soundStr = settings[PushSchedule.settingSoundKey];
    _soundEnabled = (soundStr ?? 'true').toLowerCase() != 'false';

    setState(() {
      _folders = folders;
      _loading = false;
    });
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
    // 대기 중인 debounce를 flush할 때도 안전하게 끝까지 실행되어야 한다.
    try {
      await DatabaseHelper.instance.upsertSetting(
          PushSchedule.settingRulesKey, PushSchedule.encode(_rules));
      await DatabaseHelper.instance.upsertSetting(
          PushSchedule.settingSoundKey, _soundEnabled.toString());
      await NotificationService.rescheduleAll();
    } catch (e) {
      debugPrint('[PUSH_SETTINGS] global settings apply failed: $e');
    }
  }

  // ─── 알림 시간대 규칙 ───

  Folder? _folderForId(int id) {
    for (final folder in _folders) {
      if (folder.id == id) return folder;
    }
    return null;
  }

  TimeOfDay _timeOfDayFromMinutes(int minutes) =>
      TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60);

  /// 실적용 구간이 사용자가 적어 넣은 구간과 완전히 같은가(= 표시할 필요가 없는가).
  /// LockScreenSchedule.matchesDeclared와 동일한 트리비얼한 판정 — PushRule용으로
  /// 그대로 재구현(값 비교 3줄뿐이라 어댑터로 감쌀 만큼의 복잡도가 아님).
  bool _matchesDeclaredRange(PushRule rule, List<List<int>> ranges) {
    return ranges.length == 1 &&
        ranges[0][0] == rule.start &&
        ranges[0][1] == rule.end;
  }

  Future<void> _onAddPushRuleTapped() async {
    if (_rules.length >= PushSchedule.maxRules) {
      final t = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.pushScheduleMaxReached)),
      );
      return;
    }
    final result = await _showPushRuleDialog();
    if (!mounted) return;
    if (result == null) return;
    setState(() {
      _rules.add(result);
      _rules.sort((a, b) => a.start.compareTo(b.start));
    });
    _updateGlobalSettings();
  }

  Future<void> _onEditPushRuleTapped(int index) async {
    if (index < 0 || index >= _rules.length) return;
    final result = await _showPushRuleDialog(initial: _rules[index]);
    if (!mounted) return;
    if (result == null) return;
    setState(() {
      if (index < _rules.length) {
        _rules[index] = result;
      } else {
        // 다이얼로그가 열려 있던 사이 목록이 바뀐 극단적인 경우의 방어 코드
        _rules.add(result);
      }
      _rules.sort((a, b) => a.start.compareTo(b.start));
    });
    _updateGlobalSettings();
  }

  void _onDeletePushRuleTapped(int index) {
    if (index < 0 || index >= _rules.length) return;
    if (_rules.length == 1) {
      // 불변식: notification_enabled==true인 동안 규칙은 항상 1개 이상.
      // 마지막 규칙을 지우려면 알림 자체를 끄는 것에 동의해야 한다.
      _confirmDeleteLastRule();
      return;
    }
    setState(() => _rules.removeAt(index));
    _updateGlobalSettings();
  }

  Future<void> _confirmDeleteLastRule() async {
    final t = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(t.pushRulesLastDeleteTitle),
        content: Text(t.pushRulesLastDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: Text(t.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: Text(t.pushRulesLastDeleteConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;

    // 알림을 끄는 결정적 동작이라 디바운스 없이 즉시 저장한다.
    _settingsDebounce?.cancel();
    setState(() {
      _rules = [];
      _enabled = false;
    });
    try {
      await DatabaseHelper.instance
          .upsertSetting(_settingNotificationEnabled, 'false');
      await DatabaseHelper.instance
          .upsertSetting(PushSchedule.settingRulesKey, '');
      await DatabaseHelper.instance.upsertSetting(
          PushSchedule.settingSoundKey, _soundEnabled.toString());
      await NotificationService.rescheduleAll();
    } catch (e) {
      debugPrint('[PUSH_SETTINGS] last-rule delete apply failed: $e');
    }
  }

  /// 시간대 추가/편집 다이얼로그. 실제 UI는 [_PushRuleDialog](아래)가 그린다 —
  /// 이 화면은 그 위젯에 초기값과 폴더 목록만 넘겨준다.
  ///
  /// ⚠️ 예전엔 이 메서드 스코프에 클로저 변수로 `TextEditingController`를 만들고
  /// `showDialog(...).whenComplete(() => controller.dispose())`로 정리했었다.
  /// 그게 '_dependents.isEmpty' 크래시의 진짜 원인이었다 — routes.dart의
  /// `TransitionRoute.didPop()`은 퇴장(reverse) 애니메이션을 *시작*만 시키고,
  /// `showDialog`가 반환하는 popped Future는 그 애니메이션이 끝나기 전에 곧바로
  /// complete된다. 그래서 `.whenComplete()`의 dispose()가 다이얼로그가 화면에서
  /// 실제로 사라지기 수백 ms 전에, 아직 마운트된 채로 애니메이션 프레임을 그리고
  /// 있는 트리에 대해 실행돼버렸다. 그 틈에(실기기 재현: 시스템 뒤로가기로 키보드를
  /// 내리면 인셋 변경 애니메이션이 별도로 진행 중이라 트리 전체가 리빌드된다) Material
  /// `TextField`가 `decoration`이 있으면 매 리빌드마다 새
  /// `Listenable.merge([focusNode, controller])`를 만들어 addListener를 거는데
  /// (material/text_field.dart:1753-1754), 그 컨트롤러가 이미 dispose된 상태라
  /// `ChangeNotifier.debugAssertNotDisposed`가 터진다("A TextEditingController was
  /// used after being disposed"). 이 예외가 리빌드 도중 발생해 프레임워크의
  /// InheritedElement dependents 장부가 어긋나고, 잠시 뒤 다이얼로그가 실제로
  /// unmount될 때 'framework.dart:6268 _dependents.isEmpty' 단언이 깨진다.
  /// (직전 시도였던 `FocusScope.unfocus()`가 안 통한 이유: 문제는 포커스 잔류가
  /// 아니라 controller dispose 타이밍이었으므로 focus를 먼저 풀어도 경합이 그대로
  /// 남아 있었다.)
  ///
  /// 고침: controller를 진짜 `State`(=[_PushRuleDialogState])가 소유하게 만들어
  /// dispose()가 Future 콜백이 아니라 Element가 실제로 unmount될 때(=퇴장
  /// 애니메이션이 끝난 뒤)만 불리도록 한다 — 그러면 이 경합 자체가 성립하지 않는다.
  Future<PushRule?> _showPushRuleDialog({PushRule? initial}) {
    return showDialog<PushRule>(
      context: context,
      builder: (dialogCtx) =>
          _PushRuleDialog(initial: initial, folders: _folders),
    );
  }

  /// "알림 시간대" 섹션: 규칙 목록 + 추가 버튼 + 겹침/gap 안내.
  List<Widget> _buildPushRulesSection(AppLocalizations t) {
    final hasOverlap = PushSchedule.overlappingIndices(_rules).isNotEmpty;
    // 표시 전용 계산 — 이 화면 안에서 한 번만 구해 모든 타일이 나눠 쓴다.
    final effectiveRanges = PushSchedule.effectiveRanges(_rules);
    final gaps = PushSchedule.gapRanges(_rules);

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text(t.pushRulesSection,
            style: Theme.of(context).textTheme.titleSmall),
      ),
      ..._rules.asMap().entries.map(
            (entry) => _buildPushRuleTile(
              t,
              entry.key,
              entry.value,
              effectiveRanges[entry.key],
            ),
          ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _onAddPushRuleTapped,
            icon: const Icon(Icons.add),
            label: Text(t.pushScheduleAdd),
          ),
        ),
      ),
      if (hasOverlap)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(t.pushScheduleOverlapHint,
              style: Theme.of(context).textTheme.bodySmall),
        ),
      // 규칙이 하나도 없을 때(gaps == [[0,0]] 전체 wrap)는 별도 안내 없이 위의
      // "+ 시간대 추가" 버튼만 보여준다 — 마스터 스위치 자체가 꺼져 있는 상태와
      // 짝을 이루므로 무슨 일이 벌어지는지는 이미 자명하다.
      if (_rules.isNotEmpty && gaps.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            t.pushRulesGapHint(_formatRanges(gaps)),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
    ];
  }

  String _formatRanges(List<List<int>> ranges) {
    return ranges
        .map((r) =>
            '${_timeOfDayFromMinutes(r[0]).format(context)}–${_timeOfDayFromMinutes(r[1]).format(context)}')
        .join(', ');
  }

  Widget _buildPushRuleTile(
      AppLocalizations t, int index, PushRule rule, List<List<int>> ranges) {
    final isAllFolders = rule.folderId == PushSchedule.allFolders;
    final folder = isAllFolders ? null : _folderForId(rule.folderId);
    final errorColor = Theme.of(context).colorScheme.error;
    final startLabel = _timeOfDayFromMinutes(rule.start).format(context);
    final endLabel = _timeOfDayFromMinutes(rule.end).format(context);

    Widget folderLine;
    if (isAllFolders) {
      folderLine = Text(t.pushAllFolders);
    } else if (folder == null) {
      folderLine = Text(t.pushScheduleFolderMissing,
          style: TextStyle(color: errorColor));
    } else if (folder.cardCount == 0) {
      folderLine = Text(
        '${folder.name} · ${t.pushScheduleFolderEmpty}',
        style: TextStyle(color: errorColor),
      );
    } else {
      folderLine =
          Text('${folder.name} · ${t.cardCountSuffix(folder.cardCount)}');
    }

    final intervalLine = Text(
      '${t.pushIntervalLabel}: ${rule.intervalMin}${t.pushIntervalMinutes}',
      style: Theme.of(context).textTheme.bodySmall,
    );

    Widget? warnLine;
    if (!_matchesDeclaredRange(rule, ranges)) {
      if (ranges.isEmpty) {
        warnLine = Text(
          t.pushScheduleNeverApplies,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: errorColor),
        );
      } else {
        final rangesText = ranges
            .map((r) =>
                '${_timeOfDayFromMinutes(r[0]).format(context)} – ${_timeOfDayFromMinutes(r[1]).format(context)}')
            .join(', ');
        warnLine = Text(
          t.pushScheduleActualRange(rangesText),
          style: Theme.of(context).textTheme.bodySmall,
        );
      }
    }

    final lines = <Widget>[folderLine, intervalLine];
    if (warnLine != null) lines.add(warnLine);

    return ListTile(
      title: Text('$startLabel – $endLabel'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: lines,
      ),
      isThreeLine: lines.length > 2,
      onTap: () => _onEditPushRuleTapped(index),
      trailing: IconButton(
        icon: const Icon(Icons.close),
        onPressed: () => _onDeletePushRuleTapped(index),
      ),
    );
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
                          // 불변식: notification_enabled==true인 동안 규칙은
                          // 항상 1개 이상 — 스위치를 켜는데 규칙이 0개면 여기서
                          // 기본 규칙을 만들어준다(fresh-install trap 방지).
                          final needsDefaultRule = v && _rules.isEmpty;
                          setState(() {
                            _enabled = v;
                            if (needsDefaultRule) {
                              _rules = [
                                const PushRule(
                                  start: 540,
                                  end: 1320,
                                  folderId: PushSchedule.allFolders,
                                  intervalMin: PushSchedule.defaultIntervalMin,
                                )
                              ];
                            }
                          });
                          try {
                            await DatabaseHelper.instance.upsertSetting(
                                _settingNotificationEnabled, v.toString());
                            if (needsDefaultRule) {
                              await DatabaseHelper.instance.upsertSetting(
                                  PushSchedule.settingRulesKey,
                                  PushSchedule.encode(_rules));
                            }
                            if (!mounted) return;
                            if (needsDefaultRule) {
                              messenger.showSnackBar(
                                SnackBar(
                                    content:
                                        Text(t.pushRulesDefaultCreated)),
                              );
                            }
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

                ..._buildPushRulesSection(t),
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
}

/// 시간대 추가/편집 다이얼로그 본체. [_showPushRuleDialog]가 `showDialog`의
/// `builder`로 이 위젯을 넘긴다. 필드 순서(시작→종료→폴더→간격)는 기존과 동일하게
/// 유지한다. v1.3.9 동작: ①폴더 드롭다운 맨 위에 "전체 폴더"(-1)가 있고 항상 유효한
/// 선택지다(미선택 상태 없음) ②간격 필드는 비우면 30분으로 자동 채워진다(에러 아님)
/// ③검증 실패는 SnackBar가 아니라 다이얼로그 안에 직접 표시한다.
///
/// StatefulWidget으로 만든 이유(중요): [TextEditingController]는 반드시
/// `State.dispose()`에서만 정리해야 한다 — Future 콜백(`.whenComplete()`나
/// `finally`)에 묶으면 Navigator.pop()이 반환하는 popped Future가 퇴장 애니메이션
/// 완료보다 먼저 끝나버려서, 아직 화면에 남아 리빌드 중인 TextField가 이미 dispose된
/// controller를 참조하는 경합이 생긴다(자세한 경위는 [_PushNotificationSettingsScreenState._showPushRuleDialog]
/// 문서 참고 — 여기서 고친 크래시의 근본원인).
class _PushRuleDialog extends StatefulWidget {
  const _PushRuleDialog({required this.initial, required this.folders});

  final PushRule? initial;
  final List<Folder> folders;

  @override
  State<_PushRuleDialog> createState() => _PushRuleDialogState();
}

class _PushRuleDialogState extends State<_PushRuleDialog> {
  late TimeOfDay _start;
  late TimeOfDay _end;
  late int _folderId;
  late final TextEditingController _intervalController;
  String? _errorText;

  static TimeOfDay _timeOfDayFromMinutes(int minutes) =>
      TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60);

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _start = initial != null
        ? _timeOfDayFromMinutes(initial.start)
        : const TimeOfDay(hour: 9, minute: 0);
    _end = initial != null
        ? _timeOfDayFromMinutes(initial.end)
        : const TimeOfDay(hour: 18, minute: 0);
    // 삭제된 폴더를 가리키던 규칙을 편집하는 경우 드롭다운 목록에 그 값이 없으므로
    // 전체 폴더로 되돌린다 — allFolders(-1)는 항상 유효한 선택지라 잠금화면 화면과
    // 달리 "미선택" 상태가 필요 없다.
    _folderId = initial?.folderId ?? PushSchedule.allFolders;
    if (_folderId != PushSchedule.allFolders &&
        !widget.folders.any((f) => f.id == _folderId)) {
      _folderId = PushSchedule.allFolders;
    }
    _intervalController = TextEditingController(
      text: initial != null ? initial.intervalMin.toString() : '',
    );
  }

  @override
  void dispose() {
    // 여기서만 dispose한다 — Element가 실제로 unmount될 때(=다이얼로그 퇴장
    // 애니메이션이 끝난 뒤)만 프레임워크가 이 메서드를 부르므로, 아직 마운트돼 리빌드
    // 중인 TextField가 dispose된 controller를 참조할 여지가 구조적으로 없다.
    _intervalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.initial == null
          ? t.pushScheduleAddTitle
          : t.pushScheduleEditTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(t.pushScheduleStart),
              trailing: TextButton(
                onPressed: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: _start,
                  );
                  if (picked != null) {
                    setState(() {
                      _start = picked;
                      _errorText = null;
                    });
                  }
                },
                child: Text(_start.format(context)),
              ),
            ),
            ListTile(
              title: Text(t.pushScheduleEnd),
              trailing: TextButton(
                onPressed: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: _end,
                  );
                  if (picked != null) {
                    setState(() {
                      _end = picked;
                      _errorText = null;
                    });
                  }
                },
                child: Text(_end.format(context)),
              ),
            ),
            DropdownButtonFormField<int>(
              initialValue: _folderId,
              decoration: InputDecoration(labelText: t.pushFolder),
              items: [
                DropdownMenuItem(
                  value: PushSchedule.allFolders,
                  child: Text(t.pushAllFolders),
                ),
                ...widget.folders
                    .where((f) => f.id != null)
                    .map((f) => DropdownMenuItem(
                          value: f.id,
                          child: Text(f.name),
                        )),
              ],
              onChanged: (v) => setState(() {
                _folderId = v ?? PushSchedule.allFolders;
                _errorText = null;
              }),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _intervalController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: t.pushScheduleInterval,
                suffixText: t.pushIntervalMinutes,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() => _errorText = null),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                t.pushScheduleIntervalDefault,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (_errorText != null) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _errorText!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.commonCancel),
        ),
        TextButton(
          onPressed: () {
            final startMin = _start.hour * 60 + _start.minute;
            final endMin = _end.hour * 60 + _end.minute;
            if (startMin == endMin) {
              setState(() => _errorText = t.pushScheduleSameTimeError);
              return;
            }
            var intervalMin = PushSchedule.defaultIntervalMin;
            final intervalText = _intervalController.text.trim();
            if (intervalText.isNotEmpty) {
              final parsed = int.tryParse(intervalText);
              if (parsed == null || parsed < 5 || parsed > 1440) {
                setState(() => _errorText = t.pushScheduleIntervalError);
                return;
              }
              intervalMin = parsed;
            }
            Navigator.pop(
              context,
              PushRule(
                start: startMin,
                end: endMin,
                folderId: _folderId,
                intervalMin: intervalMin,
              ),
            );
          },
          child: Text(t.commonSave),
        ),
      ],
    );
  }
}
