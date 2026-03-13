import 'dart:async';

import 'package:flutter/material.dart';

import '../database/database_helper.dart';
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
        _selectedFolderIds = folderIds.map((e) => e as int).toSet();
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
      final goSettings = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('오버레이 권한 필요'),
          content: const Text('잠금화면에 카드를 표시하려면\n다른 앱 위에 표시 권한이 필요합니다.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('설정으로 이동'),
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
      _applySettings();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('잠금화면 설정')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('잠금화면 설정')),
      body: ListView(
        children: [
          // 잠금화면 ON/OFF
          ListTile(
            title: const Text('잠금화면 사용'),
            subtitle: const Text('화면이 꺼질 때마다 카드 표시'),
            trailing: Transform.scale(
              scale: 0.8,
              child: Switch(
                value: _enabled,
                onChanged: _onEnabledChanged,
              ),
            ),
          ),
          const Divider(),

          // 아래 설정은 항상 표시 (OFF 상태에서도 설정 가능)
          // 폴더 선택
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('폴더 선택',
                style: Theme.of(context).textTheme.titleSmall),
          ),
          ..._folders.map((folder) => CheckboxListTile(
                title: Text(folder.name),
                subtitle: Text('${folder.cardCount}장'),
                value: _selectedFolderIds.contains(folder.id),
                onChanged: (checked) {
                  setState(() {
                    if (checked == true) {
                      _selectedFolderIds.add(folder.id!);
                    } else {
                      _selectedFolderIds.remove(folder.id);
                    }
                  });
                  _onSettingChanged();
                },
              )),
          const Divider(),

          // 상태 필터
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('상태 필터',
                style: Theme.of(context).textTheme.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('전체'),
                  selected: _finishedFilter == -1,
                  onSelected: (s) {
                    if (!s) return;
                    setState(() => _finishedFilter = -1);
                    _onSettingChanged();
                  },
                ),
                ChoiceChip(
                  label: const Text('암기 중'),
                  selected: _finishedFilter == 0,
                  onSelected: (s) {
                    if (!s) return;
                    setState(() => _finishedFilter = 0);
                    _onSettingChanged();
                  },
                ),
                ChoiceChip(
                  label: const Text('암기 완료'),
                  selected: _finishedFilter == 1,
                  onSelected: (s) {
                    if (!s) return;
                    setState(() => _finishedFilter = 1);
                    _onSettingChanged();
                  },
                ),
              ],
            ),
          ),
          const Divider(),

          // 카드 순서
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('카드 순서',
                style: Theme.of(context).textTheme.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('순차'),
                  selected: !_randomOrder,
                  onSelected: (s) {
                    if (!s) return;
                    setState(() => _randomOrder = false);
                    _onSettingChanged();
                  },
                ),
                ChoiceChip(
                  label: const Text('랜덤'),
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

          // 문제/정답 바꾸기
          ListTile(
            title: const Text('문제/정답 바꾸기'),
            subtitle: const Text('앞면에 정답, 뒷면에 질문 표시'),
            trailing: Transform.scale(
              scale: 0.8,
              child: Switch(
                value: _reversed,
                onChanged: (v) {
                  setState(() => _reversed = v);
                  _onSettingChanged();
                },
              ),
            ),
          ),
          const Divider(),

          // 배경색
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('배경색',
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
