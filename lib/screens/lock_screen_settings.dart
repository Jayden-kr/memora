import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../database/database_helper.dart';
import '../l10n/app_localizations.dart';
import '../models/folder.dart';
import '../services/lock_screen_service.dart';
import '../utils/constants.dart';
import '../widgets/color_picker_dialog.dart';
import '../widgets/lock_screen_preview.dart';

class LockScreenSettingsScreen extends StatefulWidget {
  const LockScreenSettingsScreen({super.key});

  @override
  State<LockScreenSettingsScreen> createState() =>
      _LockScreenSettingsScreenState();
}

class _LockScreenSettingsScreenState extends State<LockScreenSettingsScreen>
    with WidgetsBindingObserver {
  bool _enabled = false;
  List<Folder> _folders = [];
  Set<int> _selectedFolderIds = {};
  int _finishedFilter = -1; // -1=전체, 0=암기중, 1=완료
  String _sortOrder =
      'sequence'; // sequence | newest | oldest | name_asc | random
  bool _reversed = false;
  int _bgColor = 0xFF1A1A2E;
  // "auto" | "light" | "dark" — LockScreenService(네이티브)의 applyPalette()와 동일 의미.
  String _bgTextMode = 'auto';
  // Stage 3: 배경 이미지. 빈 문자열 = 이미지 없음. 절대경로, lock_bg/ 안에 최대 1개만
  // 유지한다(images/와 분리 — DatabaseHelper.cleanupOrphanMediaFiles()가 스캔하지 않음).
  String _bgImagePath = '';
  int _bgImageAlpha = 255;
  int _bgScrimAlpha = 102;
  bool _pickingBgImage = false;
  bool _loading = true;
  bool _checkingOverlay = false;
  final _picker = ImagePicker();

  static const _bgTextModeOptions = <String>['auto', 'light', 'dark'];

  // 시간대별 폴더 자동 전환
  bool _scheduleEnabled = false;
  List<LockScreenSlot> _slots = [];

  static const _sortOptions = <String>[
    'sequence',
    'newest',
    'oldest',
    'name_asc',
    'random',
  ];

  static const List<int> _bgColorPresets = [
    0xFF1A1A2E,
    0xFF16213E,
    0xFF0F3460,
    0xFF1A1A1A,
    0xFF2D132C,
    0xFF1B1B2F,
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadData();
  }

  @override
  void dispose() {
    final hadPendingSettings = _settingDebounce?.isActive ?? false;
    _settingDebounce?.cancel();
    if (hadPendingSettings) {
      // 대기 중이던 debounce를 flush — 그냥 취소만 하면 폴더/정렬/배경색 변경이
      // 네이티브에 반영되지 않은 채 화면을 벗어나 유실된다. context/setState를 쓰지
      // 않으므로 dispose 이후에도 fire-and-forget으로 안전하게 완료 가능.
      _applySettings();
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 오버레이 권한 설정 화면에서 돌아왔을 때 재확인
    if (state == AppLifecycleState.resumed && _enabled && !_checkingOverlay) {
      _checkOverlayAndStart();
    }
  }

  Future<void> _loadData() async {
    final allFolders = await DatabaseHelper.instance.getAllFolders();
    // 번들 폴더 제외 (카드를 직접 갖지 않으므로 잠금화면에 부적합)
    final folders = allFolders.where((f) => !f.isBundle).toList();
    final settings = await LockScreenService.getSettings();

    // Stage 3: 배경 이미지 경로가 가리키는 파일이 실제로 있는지 확인. 없으면(수동
    // 삭제 등) 없는 파일을 계속 가리키지 않고 "이미지 없음"으로 취급한다.
    var bgImagePath = (settings['bgImagePath'] as String?) ?? '';
    if (bgImagePath.isNotEmpty && !await File(bgImagePath).exists()) {
      bgImagePath = '';
    }
    // 방어적 정리: lock_bg/ 디렉토리에 "최대 1개만 유지" 불변식을 이 화면을 열 때마다
    // 다시 강제한다 — 강제종료 등으로 교체 도중 파일이 두 개 남는 극히 드문 경우를
    // 스스로 회복시킨다. fire-and-forget, 실패해도 무시(다음 방문 때 재시도).
    unawaited(_cleanupStaleBgImages(bgImagePath));

    if (!mounted) return;

    setState(() {
      _folders = folders;
      _enabled = settings['enabled'] as bool? ?? false;
      final folderIds = settings['folderIds'];
      if (folderIds is List) {
        final validIds = folders.map((f) => f.id).toSet();
        _selectedFolderIds = folderIds
            .map((e) => e as int)
            .where((id) => validIds.contains(id))
            .toSet();
      }
      _finishedFilter = settings['finishedFilter'] as int? ?? -1;
      final rawSort = settings['sortOrder'];
      if (rawSort is String && _sortOptions.contains(rawSort)) {
        _sortOrder = rawSort;
      } else {
        // 구버전 prefs(random_order bool) 호환
        final legacyRandom = settings['randomOrder'] as bool? ?? false;
        _sortOrder = legacyRandom ? 'random' : 'sequence';
      }
      _reversed = settings['reversed'] as bool? ?? false;
      _bgColor = settings['bgColor'] as int? ?? 0xFF1A1A2E;
      final rawTextMode = settings['bgTextMode'];
      _bgTextMode =
          rawTextMode is String && _bgTextModeOptions.contains(rawTextMode)
          ? rawTextMode
          : 'auto';
      _bgImagePath = bgImagePath;
      _bgImageAlpha = (settings['bgImageAlpha'] as num?)?.toInt() ?? 255;
      _bgScrimAlpha = (settings['bgScrimAlpha'] as num?)?.toInt() ?? 102;
      _scheduleEnabled = settings['scheduleEnabled'] as bool? ?? false;
      // NOTE: folderIds와 달리, 존재하지 않는 폴더를 가리키는 슬롯을 여기서 걸러
      // 내지 않는다 — getAllFolders()가 어떤 이유로든 일부만 반환하면 그 필터가
      // 사용자의 슬롯을 조용히 지워버리기 때문. 문제가 있으면 화면에 빨갛게
      // 보여줘서(_buildSlotTile) 사용자가 직접 고치게 한다.
      _slots = LockScreenSchedule.decode(settings['scheduleCsv'] as String?);
      _loading = false;
    });
  }

  Future<void> _checkOverlayAndStart() async {
    if (_checkingOverlay) return;
    _checkingOverlay = true;
    try {
      await _checkOverlayAndStartImpl();
    } finally {
      _checkingOverlay = false;
    }
  }

  Future<void> _checkOverlayAndStartImpl() async {
    final canDraw = await LockScreenService.canDrawOverlays();
    if (!canDraw) {
      if (!mounted) return;
      final t = AppLocalizations.of(context);
      final goSettings = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t.lockOverlayPermissionTitle),
          content: Text(t.lockOverlayPermissionBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.commonCancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.lockOpenSystemSettings),
            ),
          ],
        ),
      );
      if (goSettings == true) {
        await LockScreenService.requestOverlayPermission();
        // 돌아오면 didChangeAppLifecycleState에서 재확인
        return;
      } else {
        if (!mounted) return;
        setState(() => _enabled = false);
        return;
      }
    }
    await _applySettings();
  }

  Future<void> _applySettings() async {
    final scheduleCsv = LockScreenSchedule.encode(_slots);
    if (_enabled) {
      await LockScreenService.startService(
        enabled: true,
        folderIds: _selectedFolderIds.toList(),
        finishedFilter: _finishedFilter,
        sortOrder: _sortOrder,
        reversed: _reversed,
        bgColor: _bgColor,
        scheduleEnabled: _scheduleEnabled,
        scheduleCsv: scheduleCsv,
        bgTextMode: _bgTextMode,
        bgImagePath: _bgImagePath,
        bgImageAlpha: _bgImageAlpha,
        bgScrimAlpha: _bgScrimAlpha,
      );
    } else {
      // 설정만 저장하고 서비스 중지
      await LockScreenService.saveSettings(
        enabled: false,
        folderIds: _selectedFolderIds.toList(),
        finishedFilter: _finishedFilter,
        sortOrder: _sortOrder,
        reversed: _reversed,
        bgColor: _bgColor,
        scheduleEnabled: _scheduleEnabled,
        scheduleCsv: scheduleCsv,
        bgTextMode: _bgTextMode,
        bgImagePath: _bgImagePath,
        bgImageAlpha: _bgImageAlpha,
        bgScrimAlpha: _bgScrimAlpha,
      );
      await LockScreenService.stopService();
    }
  }

  Future<void> _onEnabledChanged(bool value) async {
    if (value && _selectedFolderIds.isEmpty && _folders.isNotEmpty) {
      // 폴더 미선택 시 첫 번째 폴더 자동 선택
      _selectedFolderIds.add(_folders.first.id!);
    }
    if (value && _selectedFolderIds.isEmpty) {
      // 폴더가 아예 없으면 활성화 불가
      if (!mounted) return;
      final t = AppLocalizations.of(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t.homeNoFolderFirst)));
      return;
    }
    setState(() => _enabled = value);
    if (value) {
      await _checkOverlayAndStart();
    } else {
      await _applySettings();
    }
  }

  String _sortLabel(AppLocalizations t, String opt) {
    switch (opt) {
      case 'newest':
        return t.cardListSortNewest;
      case 'oldest':
        return t.cardListSortOldest;
      case 'name_asc':
        return t.cardListSortName;
      case 'random':
        return t.cardListSortRandom;
      case 'sequence':
      default:
        return t.cardListSortDefault;
    }
  }

  String _bgTextModeLabel(AppLocalizations t, String opt) {
    switch (opt) {
      case 'light':
        return t.lockBgTextModeLight;
      case 'dark':
        return t.lockBgTextModeDark;
      case 'auto':
      default:
        return t.lockBgTextModeAuto;
    }
  }

  Timer? _settingDebounce;

  void _onSettingChanged() {
    // 디바운싱: 빠른 연속 변경 시 마지막 변경만 적용 (500ms)
    _settingDebounce?.cancel();
    _settingDebounce = Timer(const Duration(milliseconds: 500), () {
      if (mounted) _applySettings();
    });
  }

  // ─── 시간대별 폴더 자동 전환 ───

  Folder? _folderForId(int id) {
    for (final folder in _folders) {
      if (folder.id == id) return folder;
    }
    return null;
  }

  TimeOfDay _timeOfDayFromMinutes(int minutes) =>
      TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60);

  Future<void> _onAddSlotTapped() async {
    if (_slots.length >= LockScreenSchedule.maxSlots) {
      final t = AppLocalizations.of(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t.lockScheduleMaxReached)));
      return;
    }
    final result = await _showSlotDialog();
    if (!mounted) return;
    if (result == null) return;
    setState(() {
      _slots.add(result);
      _slots.sort((a, b) => a.start.compareTo(b.start));
    });
    _onSettingChanged();
  }

  Future<void> _onEditSlotTapped(int index) async {
    if (index < 0 || index >= _slots.length) return;
    final result = await _showSlotDialog(initial: _slots[index]);
    if (!mounted) return;
    if (result == null) return;
    setState(() {
      if (index < _slots.length) {
        _slots[index] = result;
      } else {
        // 다이얼로그가 열려 있던 사이 목록이 바뀐 극단적인 경우의 방어 코드
        _slots.add(result);
      }
      _slots.sort((a, b) => a.start.compareTo(b.start));
    });
    _onSettingChanged();
  }

  void _onDeleteSlotTapped(int index) {
    setState(() => _slots.removeAt(index));
    _onSettingChanged();
  }

  // ─── 배경색 ───

  Future<void> _openCustomColorPicker() async {
    final result = await showColorPickerDialog(
      context: context,
      initialColor: _bgColor,
    );
    if (!mounted) return;
    if (result == null) return;
    setState(() => _bgColor = result);
    _onSettingChanged();
  }

  // ─── 배경 이미지 ───

  Future<Directory> _bgImageDir() async {
    final dir = await getApplicationDocumentsDirectory();
    return Directory(p.join(dir.path, AppConstants.lockBgImageDir));
  }

  /// lock_bg/ 디렉토리에서 [keepPath]가 아닌 파일을 전부 지운다("최대 1개만 유지"
  /// 불변식 강제). keepPath가 빈 문자열이면 전부 지운다. 실패해도 조용히 무시한다 —
  /// 다음에 이 화면을 열 때 다시 시도되므로 영구히 남지 않는다.
  Future<void> _cleanupStaleBgImages(String keepPath) async {
    try {
      final bgDir = await _bgImageDir();
      if (!await bgDir.exists()) return;
      await for (final entity in bgDir.list(followLinks: false)) {
        if (entity is! File) continue;
        if (keepPath.isNotEmpty && p.equals(entity.path, keepPath)) continue;
        try {
          await entity.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 갤러리에서 이미지를 골라 lock_bg/에 다운스케일 저장하고 이전 파일을 지운다.
  /// 원본을 그대로 저장하지 않는다 — pickImage의 maxWidth/maxHeight/imageQuality가
  /// 이미 디코딩 부담과 디스크 사용량을 줄여서 반환한다.
  Future<void> _pickBackgroundImage() async {
    if (_pickingBgImage) return;
    _pickingBgImage = true;
    try {
      final XFile? picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1440,
        maxHeight: 2960,
        imageQuality: 85,
      );
      if (picked == null || !mounted) return;

      final bgDir = await _bgImageDir();
      try {
        if (!await bgDir.exists()) {
          await bgDir.create(recursive: true);
        }
      } catch (e) {
        if (!await bgDir.exists()) rethrow;
      }

      final ext = p.extension(picked.path);
      final fileName =
          'bg_${DateTime.now().millisecondsSinceEpoch}${ext.isNotEmpty ? ext : '.jpg'}';
      final destPath = p.join(bgDir.path, fileName);
      await File(picked.path).copy(destPath);

      // 복사가 끝난 뒤에만 이전 파일을 지운다 — 복사가 실패해도 이전 배경을 잃지 않는다.
      final previousPath = _bgImagePath;
      if (!mounted) {
        // 화면이 이미 닫혔다 — 새로 저장한 파일은 다음 방문 시 _cleanupStaleBgImages가 정리.
        return;
      }
      setState(() => _bgImagePath = destPath);
      _onSettingChanged();
      if (previousPath.isNotEmpty && previousPath != destPath) {
        File(previousPath).delete().ignore();
      }
    } catch (e) {
      if (!mounted) return;
      final t = AppLocalizations.of(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t.lockBgImagePickFail)));
    } finally {
      _pickingBgImage = false;
    }
  }

  void _removeBackgroundImage() {
    final previousPath = _bgImagePath;
    setState(() => _bgImagePath = '');
    _onSettingChanged();
    if (previousPath.isNotEmpty) {
      File(previousPath).delete().ignore();
    }
  }

  /// 시간대 추가/편집 다이얼로그. 저장 버튼을 눌렀을 때만 검증(시작==종료, 폴더
  /// 미선택)하고 실패하면 다이얼로그를 닫지 않는다. 겹침은 여기서 막지 않음 —
  /// 자정 교차 슬롯을 편집하는 도중엔 일시적으로 겹치는 상태가 정상이라 목록
  /// 화면의 경고 문구로만 처리한다.
  ///
  /// 검증 실패는 SnackBar가 아니라 다이얼로그 안에 직접 표시한다. SnackBar는
  /// 다이얼로그의 모달 배리어 뒤(= 어둡게 깔린 Scaffold 위)에 그려져서 정작
  /// 사용자가 봐야 할 순간에 잘 안 보인다.
  Future<LockScreenSlot?> _showSlotDialog({LockScreenSlot? initial}) {
    final t = AppLocalizations.of(context);
    TimeOfDay start = initial != null
        ? _timeOfDayFromMinutes(initial.start)
        : const TimeOfDay(hour: 9, minute: 0);
    TimeOfDay end = initial != null
        ? _timeOfDayFromMinutes(initial.end)
        : const TimeOfDay(hour: 18, minute: 0);
    // 삭제된 폴더를 가리키던 슬롯을 편집하는 경우 드롭다운 목록에 그 값이 없으므로
    // 미선택 상태로 시작 — 사용자가 새로 골라야 저장할 수 있다.
    int? folderId = initial?.folderId;
    if (folderId != null && !_folders.any((f) => f.id == folderId)) {
      folderId = null;
    }
    String? errorText;

    return showDialog<LockScreenSlot>(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return AlertDialog(
              title: Text(
                initial == null
                    ? t.lockScheduleAddTitle
                    : t.lockScheduleEditTitle,
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    title: Text(t.lockScheduleStart),
                    trailing: TextButton(
                      onPressed: () async {
                        final picked = await showTimePicker(
                          context: dialogCtx,
                          initialTime: start,
                        );
                        if (picked != null) {
                          setDialogState(() {
                            start = picked;
                            errorText = null;
                          });
                        }
                      },
                      child: Text(start.format(dialogCtx)),
                    ),
                  ),
                  ListTile(
                    title: Text(t.lockScheduleEnd),
                    trailing: TextButton(
                      onPressed: () async {
                        final picked = await showTimePicker(
                          context: dialogCtx,
                          initialTime: end,
                        );
                        if (picked != null) {
                          setDialogState(() {
                            end = picked;
                            errorText = null;
                          });
                        }
                      },
                      child: Text(end.format(dialogCtx)),
                    ),
                  ),
                  DropdownButtonFormField<int>(
                    initialValue: folderId,
                    decoration: InputDecoration(
                      labelText: t.lockScheduleFolder,
                    ),
                    items: _folders
                        .where((f) => f.id != null)
                        .map(
                          (f) => DropdownMenuItem(
                            value: f.id,
                            child: Text(f.name),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setDialogState(() {
                      folderId = v;
                      errorText = null;
                    }),
                  ),
                  if (errorText != null) ...[
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        errorText!,
                        style: TextStyle(
                          color: Theme.of(dialogCtx).colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogCtx),
                  child: Text(t.commonCancel),
                ),
                TextButton(
                  onPressed: () {
                    final startMin = start.hour * 60 + start.minute;
                    final endMin = end.hour * 60 + end.minute;
                    if (startMin == endMin) {
                      setDialogState(
                        () => errorText = t.lockScheduleSameTimeError,
                      );
                      return;
                    }
                    final pickedFolderId = folderId;
                    if (pickedFolderId == null) {
                      setDialogState(
                        () => errorText = t.lockScheduleNoFolderError,
                      );
                      return;
                    }
                    Navigator.pop(
                      dialogCtx,
                      LockScreenSlot(
                        start: startMin,
                        end: endMin,
                        folderId: pickedFolderId,
                      ),
                    );
                  },
                  child: Text(t.commonSave),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 스케줄이 켜져 있을 때만 보여줄 슬롯 목록 + 추가 버튼 + 안내 문구.
  List<Widget> _buildScheduleSection(AppLocalizations t) {
    final hasOverlap = LockScreenSchedule.overlappingIndices(_slots).isNotEmpty;
    // 표시 전용 계산 — 이 화면 안에서 한 번만 구해 모든 타일이 나눠 쓴다(타일마다
    // 다시 1440분을 순회하지 않도록).
    final effectiveRanges = LockScreenSchedule.effectiveRanges(_slots);

    return [
      if (_slots.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            t.lockScheduleEmpty,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        )
      else
        ..._slots.asMap().entries.map(
          (entry) => _buildSlotTile(
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
            onPressed: _folders.isEmpty ? null : _onAddSlotTapped,
            icon: const Icon(Icons.add),
            label: Text(t.lockScheduleAdd),
          ),
        ),
      ),
      if (hasOverlap)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            t.lockScheduleOverlapHint,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text(
          t.lockScheduleApplyNote,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    ];
  }

  Widget _buildSlotTile(
    AppLocalizations t,
    int index,
    LockScreenSlot slot,
    List<List<int>> ranges,
  ) {
    final folder = _folderForId(slot.folderId);
    final errorColor = Theme.of(context).colorScheme.error;
    final startLabel = _timeOfDayFromMinutes(slot.start).format(context);
    final endLabel = _timeOfDayFromMinutes(slot.end).format(context);

    Widget folderLine;
    if (folder == null) {
      folderLine = Text(
        t.lockScheduleFolderMissing,
        style: TextStyle(color: errorColor),
      );
    } else if (folder.cardCount == 0) {
      // "카드 0개 · 카드 없음"은 같은 말을 두 번 하는 것이라 개수는 생략한다.
      folderLine = Text(
        '${folder.name} · ${t.lockScheduleFolderEmpty}',
        style: TextStyle(color: errorColor),
      );
    } else {
      folderLine = Text(
        '${folder.name} · ${t.cardCountSuffix(folder.cardCount)}',
      );
    }

    // 실제 적용 구간이 사용자가 적어 넣은 구간과 같으면(가장 흔한 경우) 아무것도
    // 덧붙이지 않는다 — 오늘까지의 화면과 완전히 동일하게 유지.
    Widget? extraLine;
    if (!LockScreenSchedule.matchesDeclared(slot, ranges)) {
      if (ranges.isEmpty) {
        extraLine = Text(
          t.lockScheduleNeverApplies,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: errorColor),
        );
      } else {
        final rangesText = ranges
            .map(
              (r) =>
                  '${_timeOfDayFromMinutes(r[0]).format(context)} – ${_timeOfDayFromMinutes(r[1]).format(context)}',
            )
            .join(', ');
        extraLine = Text(
          t.lockScheduleActualRange(rangesText),
          style: Theme.of(context).textTheme.bodySmall,
        );
      }
    }

    final subtitle = extraLine == null
        ? folderLine
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [folderLine, extraLine],
          );

    return ListTile(
      title: Text('$startLabel – $endLabel'),
      subtitle: subtitle,
      isThreeLine: extraLine != null,
      onTap: () => _onEditSlotTapped(index),
      trailing: IconButton(
        icon: const Icon(Icons.close),
        onPressed: () => _onDeleteSlotTapped(index),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(t.lockTitle)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(t.lockTitle)),
      body: ListView(
        children: [
          // 잠금화면 ON/OFF
          ListTile(
            title: Text(t.lockEnable),
            subtitle: Text(t.lockEnableSubtitle),
            trailing: Transform.scale(
              scale: 0.8,
              child: Switch(value: _enabled, onChanged: _onEnabledChanged),
            ),
          ),
          const Divider(),

          // 폴더 선택 (단일 선택) — 스케줄이 켜지면 "폴더 선택" 대신 "기본 폴더"로 표기
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _scheduleEnabled ? t.lockBaseFolder : t.lockSelectFolder,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                if (_scheduleEnabled) ...[
                  const SizedBox(height: 2),
                  Text(
                    t.lockBaseFolderHint,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
          RadioGroup<int>(
            groupValue: _selectedFolderIds.length == 1
                ? _selectedFolderIds.first
                : -1,
            onChanged: (id) {
              if (id == null || id == -1) return;
              setState(() {
                _selectedFolderIds
                  ..clear()
                  ..add(id);
              });
              _onSettingChanged();
            },
            child: Column(
              children: _folders
                  .where((f) => f.id != null)
                  .map(
                    (folder) => RadioListTile<int>(
                      title: Text(folder.name),
                      subtitle: Text(t.cardCountSuffix(folder.cardCount)),
                      value: folder.id!,
                    ),
                  )
                  .toList(),
            ),
          ),

          const Divider(),

          // 시간대별 폴더 자동 전환
          SwitchListTile(
            title: Text(t.lockScheduleEnable),
            subtitle: Text(t.lockScheduleEnableSubtitle),
            value: _scheduleEnabled,
            onChanged: (v) {
              setState(() => _scheduleEnabled = v);
              _onSettingChanged();
            },
          ),
          if (_scheduleEnabled) ..._buildScheduleSection(t),
          const Divider(),

          // 카드 순서
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              t.lockOrder,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: _sortOptions.map((opt) {
                return ChoiceChip(
                  label: Text(_sortLabel(t, opt)),
                  selected: _sortOrder == opt,
                  onSelected: (s) {
                    if (!s) return;
                    setState(() => _sortOrder = opt);
                    _onSettingChanged();
                  },
                );
              }).toList(),
            ),
          ),
          const Divider(),

          // 배경색
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              t.lockBgColor,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),

          // 라이브 미리보기 — 실제 잠금화면 카드를 축소한 목업. _bgColor/_bgTextMode가
          // 바뀌면(스와치 탭, 커스텀 색상 다이얼로그 적용, 텍스트 모드 칩 선택) 이
          // build()가 다시 불려 즉시 갱신된다.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: LockScreenPreview(
              bgColor: _bgColor,
              bgTextMode: _bgTextMode,
              bgImagePath: _bgImagePath,
              bgImageAlpha: _bgImageAlpha,
              bgScrimAlpha: _bgScrimAlpha,
            ),
          ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                // 현재 _bgColor가 6개 프리셋 중 어느 것과도 일치하지 않으면(=커스텀
                // 색이 적용된 상태) 그 사실을 보여주는 별도 스와치.
                if (!_bgColorPresets.contains(_bgColor))
                  GestureDetector(
                    onTap: _openCustomColorPicker,
                    child: Tooltip(
                      message: t.lockBgCustomColor,
                      child: Container(
                        width: 40,
                        height: 40,
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Theme.of(context).colorScheme.primary,
                            width: 3,
                          ),
                        ),
                        child: ColorSwatchPreview(
                          color: Color(_bgColor),
                          size: 36,
                        ),
                      ),
                    ),
                  ),
                ..._bgColorPresets.map((color) {
                  final selected = _bgColor == color;
                  return GestureDetector(
                    onTap: () {
                      setState(() => _bgColor = color);
                      _onSettingChanged();
                    },
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Color(color),
                        shape: BoxShape.circle,
                        border: selected
                            ? Border.all(
                                color: Theme.of(context).colorScheme.primary,
                                width: 3,
                              )
                            : Border.all(
                                color: Theme.of(context).colorScheme.outline,
                                width: 1,
                              ),
                      ),
                    ),
                  );
                }),
                Tooltip(
                  message: t.lockBgCustomColor,
                  child: GestureDetector(
                    onTap: _openCustomColorPicker,
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outline,
                          width: 1,
                        ),
                      ),
                      child: Icon(
                        Icons.add,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          const Divider(),

          // 배경 이미지 — 단색 위에 얹는 선택 요소. 없으면 오늘까지와 동일한 단색 배경.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              t.lockBgImage,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _bgImagePath.isEmpty
                      ? Container(
                          width: 56,
                          height: 56,
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.image_outlined,
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        )
                      : Image.file(
                          File(_bgImagePath),
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            width: 56,
                            height: 56,
                            color: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                            child: Icon(
                              Icons.broken_image_outlined,
                              color: Theme.of(context).colorScheme.outline,
                            ),
                          ),
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: _pickingBgImage
                            ? null
                            : _pickBackgroundImage,
                        child: Text(t.lockBgImagePick),
                      ),
                      if (_bgImagePath.isNotEmpty)
                        OutlinedButton(
                          onPressed: _removeBackgroundImage,
                          child: Text(t.lockBgImageRemove),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_bgImagePath.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                t.lockBgImageOpacity,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: _bgImageAlpha.toDouble(),
                      min: 0,
                      max: 255,
                      onChanged: (v) {
                        setState(() => _bgImageAlpha = v.round());
                        _onSettingChanged();
                      },
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      '${(_bgImageAlpha / 255 * 100).round()}%',
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                t.lockBgScrimOpacity,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: _bgScrimAlpha.toDouble(),
                      min: 0,
                      max: 255,
                      onChanged: (v) {
                        setState(() => _bgScrimAlpha = v.round());
                        _onSettingChanged();
                      },
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      '${(_bgScrimAlpha / 255 * 100).round()}%',
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const Divider(),

          // 텍스트 색상: auto(BgContrast 자동 판정)/light/dark 강제
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text(
              t.lockBgTextMode,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: _bgTextModeOptions.map((opt) {
                return ChoiceChip(
                  label: Text(_bgTextModeLabel(t, opt)),
                  selected: _bgTextMode == opt,
                  onSelected: (s) {
                    if (!s) return;
                    setState(() => _bgTextMode = opt);
                    _onSettingChanged();
                  },
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
