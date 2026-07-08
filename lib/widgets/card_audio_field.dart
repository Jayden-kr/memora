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

  const AudioPlayerButton({
    super.key,
    required this.path,
    this.durationMs,
    this.compact = false,
  });

  @override
  State<AudioPlayerButton> createState() => _AudioPlayerButtonState();
}

class _AudioPlayerButtonState extends State<AudioPlayerButton> {
  late final AudioPlayer _player;
  PlayerState _state = PlayerState.stopped;
  Duration _position = Duration.zero;
  Duration? _duration;

  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    if (widget.durationMs != null && widget.durationMs! > 0) {
      _duration = Duration(milliseconds: widget.durationMs!);
    }
    _subs.add(_player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    }));
    _subs.add(_player.onPositionChanged.listen((pos) {
      if (mounted) setState(() => _position = pos);
    }));
    _subs.add(_player.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _state = s);
    }));
    _subs.add(_player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _state = PlayerState.completed;
          _position = Duration.zero;
        });
      }
    }));
  }

  @override
  void didUpdateWidget(AudioPlayerButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 경로가 바뀌면(재녹음/교체) 재생 상태 초기화
    if (oldWidget.path != widget.path) {
      _player.stop();
      setState(() {
        _state = PlayerState.stopped;
        _position = Duration.zero;
        _duration = (widget.durationMs != null && widget.durationMs! > 0)
            ? Duration(milliseconds: widget.durationMs!)
            : null;
      });
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    try {
      if (_state == PlayerState.playing) {
        await _player.pause();
      } else if (_state == PlayerState.paused) {
        await _player.resume();
      } else {
        // stopped / completed → 처음부터 재생
        await _player.play(DeviceFileSource(widget.path));
      }
    } catch (_) {
      // 파일 손상/미존재 등 — 조용히 무시 (UI는 stopped 유지)
    }
  }

  @override
  Widget build(BuildContext context) {
    final playing = _state == PlayerState.playing;
    final total = _duration ?? Duration.zero;
    final hasTotal = total.inMilliseconds > 0;
    final progress = hasTotal
        ? (_position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
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
                      ? '${_fmtDuration(_position)} / ${_fmtDuration(total)}'
                      : _fmtDuration(_position),
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
  State<CardAudioField> createState() => _CardAudioFieldState();
}

class _CardAudioFieldState extends State<CardAudioField> {
  final AudioRecorder _recorder = AudioRecorder();

  String? _path;
  int? _durationMs;

  bool _recording = false;
  Duration _elapsed = Duration.zero;
  Timer? _timer;

  /// 이 위젯이 이번 세션에 생성한 파일들 (교체/삭제 시 orphan 정리 대상).
  /// 원본(initialPath) 파일은 여기 없으므로, 원본 삭제는 부모의 저장 시점 cleanup이 담당.
  final Set<String> _created = {};

  @override
  void initState() {
    super.initState();
    _path = widget.initialPath;
    _durationMs = widget.initialDurationMs;
  }

  @override
  void dispose() {
    _timer?.cancel();
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

  Future<void> _stopRecording() async {
    _timer?.cancel();
    final durationMs = _elapsed.inMilliseconds;
    String? resultPath;
    try {
      resultPath = await _recorder.stop();
    } catch (_) {
      resultPath = null;
    }
    if (!mounted) return;
    setState(() => _recording = false);
    if (resultPath == null) return;
    _created.add(resultPath);
    _disposeSupersededFile(_path, resultPath);
    _commit(resultPath, durationMs > 0 ? durationMs : null);
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
    if (_recording) {
      content = Row(
        children: [
          Icon(Icons.fiber_manual_record, color: cs.error, size: 18),
          const SizedBox(width: 8),
          Text('${t.cardAudioRecording}  ${_fmtDuration(_elapsed)}'),
          const Spacer(),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.stop),
            label: Text(t.cardAudioStop),
            onPressed: _stopRecording,
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.graphic_eq,
                size: 18, color: Theme.of(context).textTheme.titleSmall?.color),
            const SizedBox(width: 6),
            Text(t.cardAudioSection,
                style: Theme.of(context).textTheme.titleSmall),
          ],
        ),
        const SizedBox(height: 8),
        content,
      ],
    );
  }
}
