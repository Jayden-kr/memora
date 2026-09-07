import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../database/database_helper.dart';
import '../l10n/app_localizations.dart';
import '../models/folder.dart';
import '../utils/folder_label.dart';
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
  /// '다른 앱 위에 표시' 권한 보유 여부(진입 시·resumed 시 갱신). false면 경고 타일.
  bool _canDrawOverlays = true;
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
    if (state != AppLifecycleState.resumed) return;
    // 시스템 설정에서 돌아왔으면 경고 타일 상태를 갱신한다.
    LockScreenService.canDrawOverlays().then((v) {
      if (mounted && v != _canDrawOverlays) setState(() => _canDrawOverlays = v);
    });
    // 오버레이 권한 설정 화면에서 돌아왔을 때 재확인
    if (_enabled && !_checkingOverlay) {
      _checkOverlayAndStart();
    }
  }

  Future<void> _loadData() async {
    final List<Folder> allFolders;
    final Map settings;
    final bool canDraw;
    try {
      // getNonBundleFolders()는 묶음을 빼는 동시에 소속 묶음 이름을 채워준다
      // (목록에서 `묶음 > 폴더`로 표시하는 데 쓴다).
      allFolders = await DatabaseHelper.instance.getNonBundleFolders();
      settings = await LockScreenService.getSettings();
      // 진입 시에도 권한을 본다 — 권한이 나중에 회수되면 스위치는 ON, 알림은 켜짐, 잠금화면은
      // 안 뜨는 침묵 실패가 됐고 이 화면은 resumed/재토글에서만 권한을 다시 봤다.
      canDraw = await LockScreenService.canDrawOverlays();
    } catch (e) {
      // 예전엔 try/catch가 없어 DB/채널 실패 시 스피너가 영원히 돌았다.
      debugPrint('[LOCK_SETTINGS] load failed: $e');
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context).settingsLoadFailed(e.toString()),
          ),
        ),
      );
      return;
    }
    // 번들 폴더 제외 (카드를 직접 갖지 않으므로 잠금화면에 부적합)
    final folders = allFolders;

    // Stage 3: 배경 이미지 경로가 가리키는 파일이 실제로 있는지 확인. 없으면(수동
    // 삭제 등) 없는 파일을 계속 가리키지 않고 "이미지 없음"으로 취급한다.
    var bgImagePath = (settings['bgImagePath'] as String?) ?? '';
    if (bgImagePath.isNotEmpty && !await File(bgImagePath).exists()) {
      bgImagePath = '';
    }
    // 방어적 정리: lock_bg/ 디렉토리에 "최대 1개만 유지" 불변식을 이 화면을 열 때마다
    // 다시 강제한다 — 강제종료 등으로 교체 도중 파일이 두 개 남는 극히 드문 경우를
    // 스스로 회복시킨다. fire-and-forget, 실패해도 무시(다음 방문 때 재시도).
    // getSettings가 실패하면 빈 맵을 돌려준다 — 그걸 "배경 없음"으로 읽고 정리를 돌리면
    // 멀쩡한 배경 파일을 지운다(감사 X4-05). 값이 있을 때만 정리한다.
    if (settings.isNotEmpty) {
      unawaited(_cleanupStaleBgImages(bgImagePath));
    }

    if (!mounted) return;

    setState(() {
      _folders = folders;
      _canDrawOverlays = canDraw;
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
        // 화면만 되돌리지 않고 저장도 한다 — 디바운스 저장이 다이얼로그 사이에 _enabled=true로
        // 발화했을 수 있어, 안 그러면 "화면은 OFF, 저장값은 ON"으로 갈린다.
        await _applySettings();
        return;
      }
    }
    await _applySettings();
  }

  Future<void> _applySettings() async {
    // 이 화면이 열려 있는 동안 다른 화면에서 폴더가 지워질 수 있다. 그때 삭제 쪽
    // 사후정리가 설정에서 그 폴더를 이미 빼 갔는데, 여기서 화면이 들고 있던 옛
    // 목록을 그대로 되쓰면 지운 폴더가 되살아난다(스윕 R5-E). 푸시 규칙 쪽은
    // 트랜잭션으로 막았지만 잠금화면 설정은 네이티브 채널이라 그럴 수 없어,
    // **쓰기 직전에 실재하는 폴더만 남긴다.**
    try {
      final alive = (await DatabaseHelper.instance.getAllFolders())
          .map((f) => f.id)
          .whereType<int>()
          .toSet();
      final staleIds = _selectedFolderIds.where((id) => !alive.contains(id));
      final staleSlots = _slots.where((sl) => !alive.contains(sl.folderId));
      if (staleIds.isNotEmpty || staleSlots.isNotEmpty) {
        _selectedFolderIds.removeWhere((id) => !alive.contains(id));
        _slots.removeWhere((sl) => !alive.contains(sl.folderId));
        if (mounted) setState(() {});
      }
    } catch (e) {
      // 대조에 실패하면 거르지 않고 그대로 저장한다 — 조회 실패를 "폴더가 다 사라졌다"로
      // 읽어 사용자의 선택을 통째로 날리는 쪽이 훨씬 나쁘다.
      debugPrint('[LOCK_SETTINGS] 폴더 실재 확인 실패, 필터 건너뜀: $e');
    }

    // 스위치 ON인데 선택 폴더가 비었으면(저장된 id의 폴더가 삭제된 뒤 다른 설정을 바꾼 경우
    // 등) ON 토글과 같은 규칙으로 첫 폴더를 자동 선택한다 — 빈 목록은 네이티브 사양상
    // "전체 카드"라 화면("폴더 선택" 힌트)과 실제 동작이 갈렸다.
    //
    // ⚠️ 유효한 시간대 슬롯이 있으면 자동 선택하지 않는다 — 기본 폴더 없이 슬롯만으로
    // 도는 것도 정상 상태다(사용자 결정 2026-09-06, LockScreenService.
    // removeFoldersFromSettingsBatch의 keepRunningOnSlots와 같은 규칙). 이 가드가
    // 없으면 슬롯만 남기고 기본 폴더를 지운 뒤 이 화면에서 아무거나(슬롯 편집 등)
    // 건드릴 때마다 되살아나 슬롯 전용 설정이 조용히 되돌아간다(리뷰 발견).
    final hasValidSlots = _scheduleEnabled && _slots.isNotEmpty;
    if (_enabled &&
        _selectedFolderIds.isEmpty &&
        _folders.isNotEmpty &&
        !hasValidSlots) {
      _selectedFolderIds.add(_folders.first.id!);
      if (mounted) setState(() {});
    }
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
    // ⚠️ 유효한 시간대 슬롯이 있으면 기본 폴더 자동선택도, "폴더 없으면 활성화 불가"도
    // 건너뛴다 — 슬롯만으로 도는 것도 정상 상태다. _applySettings의 같은 가드 참고.
    final hasValidSlots = _scheduleEnabled && _slots.isNotEmpty;
    if (value && _selectedFolderIds.isEmpty && _folders.isNotEmpty && !hasValidSlots) {
      // 폴더 미선택 시 첫 번째 폴더 자동 선택
      _selectedFolderIds.add(_folders.first.id!);
    }
    if (value && _selectedFolderIds.isEmpty && !hasValidSlots) {
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

  /// 디바운스를 건너뛰고 지금 즉시 저장한다. 배경 이미지처럼 "설정을 쓰기 전에 파일을 지우면
  /// 그 사이 프로세스가 죽었을 때 배경이 영구 소실되는" 경로에서 쓴다(감사 D4-12).
  Future<void> _flushSettingNow() async {
    _settingDebounce?.cancel();
    _settingDebounce = null;
    await _applySettings();
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
  ///
  /// ⚠️ 1라운드 감사(2026-09-04)에서 발견한 TOCTOU 레이스 방지: 이 fire-and-forget
  /// 정리가 끝나기 전에 사용자가 새 이미지를 골라 복사하면(_pickBackgroundImage),
  /// keepPath가 그 시점 기준 옛 값이라 방금 복사된 새 파일까지 지울 수 있었다.
  /// _pickingBgImage가 세워지면(=선택이 진행 중이면) 그 파일 판단은 새 선택 흐름에
  /// 맡기고 이 루프는 즉시 중단한다 — 지우다 만 파일은 다음 방문 때 다시 정리된다.
  Future<void> _cleanupStaleBgImages(String keepPath) async {
    try {
      final bgDir = await _bgImageDir();
      if (!await bgDir.exists()) return;
      await for (final entity in bgDir.list(followLinks: false)) {
        if (_pickingBgImage) return;
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
      // 새 경로를 확정 저장한 뒤에 옛 파일을 지운다 — 500ms 디바운스 사이에 잠기거나 앱이
      // 죽으면 prefs가 방금 지운 옛 파일을 가리켜 배경이 사라졌다(감사 D4-12).
      await _flushSettingNow();
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

  Future<void> _removeBackgroundImage() async {
    final previousPath = _bgImagePath;
    setState(() => _bgImagePath = '');
    // 제거도 같은 이유로 저장을 먼저 끝낸다(D4-12).
    await _flushSettingNow();
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
                    // 형제 드롭다운(기본 폴더·편집 화면)과 같게 — 없으면 긴 폴더명이
                    // 다이얼로그 폭을 밀어 가로로 넘친다.
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: t.lockScheduleFolder,
                    ),
                    items: _folders
                        .where((f) => f.id != null)
                        .map(
                          (f) => DropdownMenuItem(
                            value: f.id,
                            child: Text(folderDisplayPath(f),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
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

  /// 폴더 드롭다운에 표시할 값 — 정확히 하나가 선택돼 있고 그 폴더가 목록에 있을 때만.
  /// (삭제된 폴더 id가 prefs에 남아 있으면 DropdownButton의 "값은 items 중 하나" 단언에
  /// 걸리므로 그 경우엔 null=힌트로 떨어뜨린다)
  int? _dropdownFolderValue() {
    if (_selectedFolderIds.length != 1) return null;
    final id = _selectedFolderIds.first;
    return _folders.any((f) => f.id == id) ? id : null;
  }

  /// 드롭다운이 가리키는 기본 폴더(없으면 null).
  Folder? get _selectedBaseFolder {
    final id = _dropdownFolderValue();
    if (id == null) return null;
    return _folders.cast<Folder?>().firstWhere((f) => f!.id == id, orElse: () => null);
  }

  /// Background 섹션 안의 소제목. 섹션 제목(titleSmall)보다 한 단계 작고 흐리게 —
  /// 색상/이미지/텍스트 색상이 각각 다른 설정처럼 보이지 않게 한다.
  Widget _bgSubLabel(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
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
        '${folderDisplayPath(folder)} · ${t.lockScheduleFolderEmpty}',
        style: TextStyle(color: errorColor),
      );
    } else {
      folderLine = Text(
        '${folderDisplayPath(folder)} · ${t.cardCountSuffix(folder.cardCount)}',
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
          // 권한이 회수된 상태를 화면에서 드러낸다(푸시 설정의 정확한 알림 안내 카드와 같은 역할).
          if (_enabled && !_canDrawOverlays)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Material(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
                child: ListTile(
                  leading: Icon(Icons.warning_amber_rounded,
                      color: Theme.of(context).colorScheme.onErrorContainer),
                  title: Text(t.lockOverlayPermissionTitle,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onErrorContainer)),
                  subtitle: Text(t.lockOverlayPermissionBody,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onErrorContainer)),
                  trailing: TextButton(
                    onPressed: () => LockScreenService.requestOverlayPermission(),
                    child: Text(t.lockOpenSystemSettings),
                  ),
                ),
              ),
            ),

          // 잠금화면 활성화·기본 폴더·시간대 전환·정렬은 전부 "잠금화면이 뭘 보여줄지"를
          // 이루는 한 덩어리 설정이라, Background 섹션과 같은 규칙으로 구분선 없이
          // 소제목만으로 나눈다(사용자 요청 2026-09-07).
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
          // 폴더가 많아져도 화면을 세로로 길게 차지하지 않도록 라디오 목록 대신 드롭다운
          // (시간대 슬롯 다이얼로그의 폴더 선택과 같은 위젯). 값은 "정확히 하나가 선택돼
          // 있고 그 폴더가 실재할 때"만 표시하고, 아니면 힌트만 보인다.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: DropdownButtonFormField<int>(
              initialValue: _dropdownFolderValue(),
              isExpanded: true,
              decoration: InputDecoration(
                hintText: t.lockSelectFolder,
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
              ),
              items: _folders
                  .where((f) => f.id != null)
                  .map(
                    (folder) => DropdownMenuItem<int>(
                      value: folder.id!,
                      child: Text(
                        '${folderDisplayPath(folder)}  ·  ${t.cardCountSuffix(folder.cardCount)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (id) {
                if (id == null) return;
                setState(() {
                  _selectedFolderIds
                    ..clear()
                    ..add(id);
                });
                _onSettingChanged();
              },
            ),
          ),
          // 선택한 기본 폴더가 비었으면 알린다 — 슬롯·푸시 규칙은 빨간 "카드 없음"을 보이는데
          // 기본 폴더만 없어서, ON 토글이 자동 선택한 첫 폴더가 빈 폴더면 상주 알림만 켜진 채
          // 오버레이가 영영 안 뜨는 침묵 실패였다.
          if (_selectedBaseFolder?.cardCount == 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                t.lockBaseFolderEmpty,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),

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
          // 미리보기는 실제 잠금화면 오버레이와 똑같은 모양을 내야 해서(위 주석 참고)
          // 위젯 안에는 "예시"라고 못 적는다 — 그 문구 자체가 진짜 카드처럼 보이면
          // 안 되기 때문. 대신 미리보기 바깥, 눈에 띄지 않게 작은 안내를 붙인다
          // (사용자 요청 2026-09-07: 프랑스 수도 예시가 실제 카드로 오인될 수 있음).
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              t.lockPreviewExampleNote,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
            ),
          ),

          _bgSubLabel(context, t.lockBgColorLabel),
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

          // 배경 이미지 — 단색 위에 얹는 선택 요소. 없으면 오늘까지와 동일한 단색 배경.
          // 구분선 없이 소제목으로만 나눈다: 색상·이미지·텍스트 색상은 별개 설정이 아니라
          // 하나의 배경 설정을 이루는 항목들이다.
          _bgSubLabel(context, t.lockBgImage),
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
          // 텍스트 색상: auto(BgContrast 자동 판정)/light/dark 강제
          _bgSubLabel(context, t.lockBgTextMode),
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
