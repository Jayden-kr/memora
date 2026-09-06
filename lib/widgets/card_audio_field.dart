import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import '../l10n/app_localizations.dart';
import '../services/audio_playback_controller.dart';
import '../utils/constants.dart';

/// mm:ss 포맷 (재생 위치/길이 표시용)
String _fmtDuration(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// 재생 전용 위젯. 로컬 오디오 파일 경로 하나를 받아 재생/일시정지 + 위치/길이를 표시.
/// 편집화면의 '음성 있음' 상태와 학습(card_view) 화면에서 공용으로 쓴다.
class AudioPlayerButton extends StatefulWidget {
  final String path;
  final int? durationMs; // DB에 저장된 길이(있으면 초기 표시에 사용)
  final bool compact; // true면 리스트/좁은 곳용 (라벨 축소)
  final bool lazy; // true면 첫 재생(탭) 시점에 player 생성 — 리스트 등 다수 인스턴스용

  const AudioPlayerButton({
    super.key,
    required this.path,
    this.durationMs,
    this.compact = false,
    this.lazy = false,
  });

  @override
  State<AudioPlayerButton> createState() => _AudioPlayerButtonState();
}

class _AudioPlayerButtonState extends State<AudioPlayerButton> {
  // 감사 D2-07: 재생은 더 이상 이 State가 소유하지 않는다. 실제 AudioPlayer는
  // AudioPlaybackController(앱 전역 싱글턴)가 들고 있고, 이 State는 그 상태를
  // 구독해서 그리기만 한다 — 그래서 이 위젯이 dispose돼도(리스트 스크롤 아웃·
  // 카드 접기·선택모드 진입 등) 재생이 끊기지 않는다.
  AudioPlaybackController get _c => AudioPlaybackController.instance;

  @override
  void initState() {
    super.initState();
    // currentPath는 "지금 이 경로가 재생 대상인지" 자체가 바뀔 때(다른 버튼이
    // 재생을 가로챔 등) 필요하므로 항상 구독한다.
    _c.currentPath.addListener(_onPathChanged);
    // state/position/duration은 재생 중 tick마다 바뀌는데, 화면에 여러 버튼이
    // 떠 있을 때(리스트) 재생 중이 아닌 버튼까지 매 tick 다시 그리지 않도록
    // _onTick 안에서 "내 경로가 현재 재생 대상일 때만" 반응한다.
    _c.state.addListener(_onTick);
    _c.position.addListener(_onTick);
    _c.duration.addListener(_onTick);
  }

  void _onPathChanged() {
    if (mounted) setState(() {});
  }

  void _onTick() {
    if (mounted && _c.currentPath.value == widget.path) setState(() {});
  }

  Duration? _knownDuration() =>
      (widget.durationMs != null && widget.durationMs! > 0)
          ? Duration(milliseconds: widget.durationMs!)
          : null;

  @override
  void dispose() {
    // 감사 D2-07: 여기서 player를 stop/dispose하지 않는다 — 그건
    // AudioPlaybackController의 몫이다. 이 위젯은 리스너만 뗀다.
    _c.currentPath.removeListener(_onPathChanged);
    _c.state.removeListener(_onTick);
    _c.position.removeListener(_onTick);
    _c.duration.removeListener(_onTick);
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_c.currentPath.value == widget.path && _c.state.value == PlayerState.playing) {
      await _c.pause();
    } else {
      // 컨트롤러가 "이어 재생/처음부터/다른 파일로 전환"을 알아서 판단한다.
      await _c.play(widget.path, knownDuration: _knownDuration());
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCurrent = _c.currentPath.value == widget.path;
    final state = isCurrent ? _c.state.value : PlayerState.stopped;
    final playing = state == PlayerState.playing;
    final position = isCurrent ? _c.position.value : Duration.zero;
    final total =
        (isCurrent ? _c.duration.value : null) ?? _knownDuration() ?? Duration.zero;
    final hasTotal = total.inMilliseconds > 0;
    final progress = hasTotal
        ? (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final cs = Theme.of(context).colorScheme;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(playing ? Icons.pause_circle : Icons.play_circle),
          iconSize: widget.compact ? 28 : 36,
          color: cs.primary,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          tooltip: playing ? null : null,
          onPressed: _toggle,
        ),
        const SizedBox(width: 8),
        if (!widget.compact)
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(
                  value: hasTotal ? progress : null,
                  minHeight: 3,
                  backgroundColor: cs.surfaceContainerHighest,
                ),
                const SizedBox(height: 4),
                Text(
                  hasTotal
                      ? '${_fmtDuration(position)} / ${_fmtDuration(total)}'
                      : _fmtDuration(position),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          )
        else
          Text(
            hasTotal ? _fmtDuration(total) : '',
            style: Theme.of(context).textTheme.bodySmall,
          ),
      ],
    );
  }
}

/// 편집화면용 카드 음성 필드 (카드당 1개).
/// 상태: 없음(녹음/파일첨부 버튼) · 녹음중(타이머+정지) · 있음(재생+삭제).
/// 파일은 기존 이미지와 같은 앱 문서 images/ 디렉토리에 저장돼 .memk 번들에 자동 포함된다.
class CardAudioField extends StatefulWidget {
  final String? initialPath;
  final int? initialDurationMs;

  /// 유효 음성이 바뀔 때마다 호출: (경로, 길이ms). 삭제 시 (null, null).
  final void Function(String? path, int? durationMs) onChanged;

  const CardAudioField({
    super.key,
    required this.initialPath,
    required this.initialDurationMs,
    required this.onChanged,
  });

  @override
  State<CardAudioField> createState() => CardAudioFieldState();
}

class CardAudioFieldState extends State<CardAudioField> {
  final AudioRecorder _recorder = AudioRecorder();

  String? _path;
  int? _durationMs;

  bool _recording = false;
  Duration _elapsed = Duration.zero;
  Timer? _timer;

  /// 녹음 중인 파일의 목적지 경로. _stopRecording으로 정지되기 전에 화면이
  /// 닫히면 dispose()가 이 경로로 orphan 정리를 한다.
  String? _activeRecordingPath;

  /// 이 위젯이 이번 세션에 생성한 파일들 (교체/삭제 시 orphan 정리 대상).
  /// 원본(initialPath) 파일은 여기 없으므로, 원본 삭제는 부모의 저장 시점 cleanup이 담당.
  final Set<String> _created = {};

  /// 녹음 진행 중인지 (부모의 미저장 변경 감지용 — 예: 뒤로가기 시 폐기 다이얼로그).
  bool get isRecording => _recording;

  /// 정지 요청 후 recorder.stop()이 끝나기 전 — 이 사이 UI가 '음성 없음'으로 되돌아가 녹음
  /// 버튼이 살아나면 새 녹음이 _activeRecordingPath를 덮어 이전 파일 추적이 끊겼다(D3-06).
  bool _stopping = false;

  @override
  void initState() {
    super.initState();
    // ''(파일 없음을 빈 문자열로 기록한 DB 값)는 null과 같다 — 이걸 그대로 받으면
    // 재생 버튼도 안 먹는 "유령 재생기"가 뜨고 녹음/첨부 버튼이 사라진다.
    final initial = widget.initialPath;
    _path = (initial == null || initial.isEmpty) ? null : initial;
    _durationMs = _path == null ? null : widget.initialDurationMs;
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_recording) {
      // 정지 없이(Save/뒤로가기 등으로) 녹음 중 화면이 닫히는 경우 —
      // 정지 후 부분 녹음 파일을 삭제해 orphan을 남기지 않는다.
      final orphan = _activeRecordingPath;
      _recorder.stop().whenComplete(() {
        if (orphan != null) File(orphan).delete().ignore();
      }).ignore();
    }
    _recorder.dispose();
    super.dispose();
  }

  Future<Directory> _mediaDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final media = Directory(p.join(dir.path, AppConstants.imageDir));
    if (!await media.exists()) {
      await media.create(recursive: true);
    }
    return media;
  }

  String _newFileName(String ext) {
    final uuid = const Uuid().v4();
    final ts = DateTime.now().millisecondsSinceEpoch;
    return 'R_$uuid-audio-$ts.$ext';
  }

  /// 이전에 이 위젯이 만든 파일이 새 파일로 교체되면 orphan을 즉시 삭제.
  void _disposeSupersededFile(String? oldPath, String newPath) {
    if (oldPath != null &&
        oldPath != newPath &&
        _created.contains(oldPath)) {
      // 감사 D2-07 invariant 6: 이 파일이 지금 전역 재생기에서 재생/추적
      // 중이었다면, 파일을 지우기 전에 먼저 정지+해제한다 — 안 그러면 방금
      // 지운 파일을 가리키는 player가 남는다.
      AudioPlaybackController.instance.stopIfPlaying(oldPath).ignore();
      File(oldPath).delete().ignore();
      _created.remove(oldPath);
    }
  }

  void _commit(String? path, int? durationMs) {
    setState(() {
      _path = path;
      _durationMs = durationMs;
    });
    widget.onChanged(path, durationMs);
  }

  Future<void> _startRecording() async {
    if (_recording || _stopping) return;
    final t = AppLocalizations.of(context);
    try {
      if (!await _recorder.hasPermission()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.cardAudioPermissionDenied)),
        );
        return;
      }
      final media = await _mediaDir();
      final dest = p.join(media.path, _newFileName('m4a'));
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: dest,
      );
      if (!mounted) return;
      setState(() {
        _recording = true;
        _elapsed = Duration.zero;
        _activeRecordingPath = dest;
      });
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() => _elapsed += const Duration(seconds: 1));
        }
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.cardAudioRecordFail(e.toString()))),
      );
    }
  }

  /// [commit]=false면 정지만 하고 결과 파일은 커밋하지 않은 채 삭제한다 (폐기용).
  Future<void> _stopRecording({bool commit = true}) async {
    // 재진입 가드: finishRecording(commit)과 cancelRecording(폐기)이 await 사이에
    // 동시 진입하면 stop()이 두 번 불려 두 번째가 같은 경로를 echo→방금 커밋한
    // 파일을 삭제하는 경합이 생긴다. await 전에 플래그를 내려 2차 호출을 차단.
    if (!_recording) return;
    final partialPath = _activeRecordingPath;
    _stopping = true;
    if (mounted) {
      setState(() => _recording = false);
    } else {
      _recording = false;
    }
    _timer?.cancel();
    final durationMs = _elapsed.inMilliseconds;
    String? resultPath;
    Object? stopError;
    try {
      resultPath = await _recorder.stop();
    } catch (e) {
      resultPath = null;
      stopError = e;
    }
    _activeRecordingPath = null;
    _stopping = false;
    if (!mounted) {
      // 정지 완료를 기다리는 사이 위젯이 dispose됨 — 완성된 파일을 이제 아무도
      // 추적하지 않으므로(orphan) 즉시 삭제.
      if (resultPath != null) File(resultPath).delete().ignore();
      return;
    }
    setState(() {});
    if (resultPath == null) {
      // 정지 실패(전화 수신·마이크 뺏김·저장공간 부족) — 부분 파일을 지우고, 커밋하려던
      // 녹음이었으면 왜 사라졌는지 알린다(D3-07: 예전엔 무음으로 증발).
      if (partialPath != null) File(partialPath).delete().ignore();
      if (commit) {
        final t = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.cardAudioRecordFail('${stopError ?? 'stop'}'))),
        );
      }
      return;
    }
    if (!commit) {
      File(resultPath).delete().ignore();
      return;
    }
    _created.add(resultPath);
    _disposeSupersededFile(_path, resultPath);
    _commit(resultPath, durationMs > 0 ? durationMs : null);
  }

  /// 부모(CardEditScreen)의 저장 흐름에서 호출: 녹음 중이면 정지 후 커밋까지
  /// 마쳐서, 정지 버튼을 누르지 않고 저장해도 진행 중이던 녹음이 포함되게 한다.
  Future<void> finishRecording() async {
    if (_recording) await _stopRecording();
  }

  /// 부모의 폐기(뒤로가기 확인) 흐름에서 호출: 녹음 중이면 정지 후 파일을 버린다.
  Future<void> cancelRecording() async {
    if (_recording) await _stopRecording(commit: false);
  }

  Future<void> _attachFile() async {
    final t = AppLocalizations.of(context);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        withData: false,
      );
      final picked = result?.files.single.path;
      if (picked == null) return;
      final media = await _mediaDir();
      final ext = p.extension(picked).replaceFirst('.', '');
      final dest = p.join(
          media.path, _newFileName(ext.isEmpty ? 'm4a' : ext));
      await File(picked).copy(dest);
      if (!mounted) {
        // 큰 오디오를 복사하는 동안 화면이 닫혔다 — 이 복사본은 아무도 참조하지 않으니
        // 지운다(_commit의 setState가 죽은 State에 걸려 예외를 삼키던 경로).
        File(dest).delete().ignore();
        return;
      }
      _created.add(dest);
      _disposeSupersededFile(_path, dest);
      _commit(dest, null); // 첨부 파일 길이는 재생 시 audioplayers가 산출
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.cardAudioAttachFail(e.toString()))),
      );
    }
  }

  void _delete() {
    final old = _path;
    // 이 위젯이 만든 파일이면 즉시 삭제. 원본 파일이면 부모의 저장 cleanup이 처리.
    if (old != null && _created.contains(old)) {
      // 감사 D2-07 invariant 6: 지금 지우는 파일이 전역 재생기에서 재생/추적
      // 중이었다면 먼저 정지+해제 — 삭제된 파일을 가리키는 player가 안 남게.
      AudioPlaybackController.instance.stopIfPlaying(old).ignore();
      File(old).delete().ignore();
      _created.remove(old);
    }
    _commit(null, null);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;

    Widget content;
    if (_recording || _stopping) {
      // 정지가 끝날 때까지 이 줄을 유지한다(버튼만 비활성) — 녹음 버튼이 되살아나지 않게.
      content = Row(
        children: [
          Icon(Icons.fiber_manual_record, color: cs.error, size: 18),
          const SizedBox(width: 8),
          Text('${t.cardAudioRecording}  ${_fmtDuration(_elapsed)}'),
          const Spacer(),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.stop),
            label: Text(t.cardAudioStop),
            onPressed: _stopping ? null : _stopRecording,
          ),
        ],
      );
    } else if (_path != null) {
      content = Row(
        children: [
          Expanded(
            child: AudioPlayerButton(
              key: ValueKey(_path),
              path: _path!,
              durationMs: _durationMs,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            color: cs.error,
            tooltip: t.cardAudioDelete,
            onPressed: _delete,
          ),
        ],
      );
    } else {
      content = Row(
        children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.mic),
            label: Text(t.cardAudioRecord),
            onPressed: _startRecording,
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.attach_file),
            label: Text(t.cardAudioAttach),
            onPressed: _attachFile,
          ),
        ],
      );
    }

    // 섹션 헤더("음성")는 편집 화면의 _sectionHeader가 제공하므로 여기선 내용만.
    return content;
  }
}
