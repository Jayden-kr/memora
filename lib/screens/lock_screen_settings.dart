import 'dart:async';

import 'package:flutter/material.dart';

import '../database/database_helper.dart';
import '../l10n/app_localizations.dart';
import '../models/folder.dart';
import '../services/lock_screen_service.dart';

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
  bool _randomOrder = true;
  bool _reversed = false;
  int _bgColor = 0xFF1A1A2E;
  bool _loading = true;
  bool _checkingOverlay = false;

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
    _settingDebounce?.cancel();
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
      _randomOrder = settings['randomOrder'] as bool? ?? true;
      _reversed = settings['reversed'] as bool? ?? false;
      _bgColor = settings['bgColor'] as int? ?? 0xFF1A1A2E;
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
    if (_enabled) {
      await LockScreenService.startService(
        enabled: true,
        folderIds: _selectedFolderIds.toList(),
        finishedFilter: _finishedFilter,
        randomOrder: _randomOrder,
        reversed: _reversed,
        bgColor: _bgColor,
      );
    } else {
      // 설정만 저장하고 서비스 중지
      await LockScreenService.saveSettings(
        enabled: false,
        folderIds: _selectedFolderIds.toList(),
        finishedFilter: _finishedFilter,
        randomOrder: _randomOrder,
        reversed: _reversed,
        bgColor: _bgColor,
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.homeNoFolderFirst)),
      );
      return;
    }
    setState(() => _enabled = value);
    if (value) {
      await _checkOverlayAndStart();
    } else {
      await _applySettings();
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
              child: Switch(
                value: _enabled,
                onChanged: _onEnabledChanged,
              ),
            ),
          ),
          const Divider(),

          // 폴더 선택 (단일 선택)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(t.lockSelectFolder,
                style: Theme.of(context).textTheme.titleSmall),
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
              children: _folders.where((f) => f.id != null).map((folder) => RadioListTile<int>(
                    title: Text(folder.name),
                    subtitle: Text(t.cardCountSuffix(folder.cardCount)),
                    value: folder.id!,
                  )).toList(),
            ),
          ),
          const Divider(),

          // 카드 순서
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(t.lockOrder,
                style: Theme.of(context).textTheme.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: Text(t.lockOrderSequential),
                  selected: !_randomOrder,
                  onSelected: (s) {
                    if (!s) return;
                    setState(() => _randomOrder = false);
                    _onSettingChanged();
                  },
                ),
                ChoiceChip(
                  label: Text(t.lockOrderRandom),
                  selected: _randomOrder,
                  onSelected: (s) {
                    if (!s) return;
                    setState(() => _randomOrder = true);
                    _onSettingChanged();
                  },
                ),
              ],
            ),
          ),
          const Divider(),

          // 배경색
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(t.lockBgColor,
                style: Theme.of(context).textTheme.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(
              spacing: 12,
              children: _bgColorPresets.map((color) {
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
                              width: 3)
                          : Border.all(
                              color: Theme.of(context).colorScheme.outline,
                              width: 1),
                    ),
                  ),
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
