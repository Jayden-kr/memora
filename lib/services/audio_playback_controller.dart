import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// 감사 D2-07: 카드 음성 "재생"을 위젯 트리에서 완전히 분리한 앱 전역 싱글턴.
///
/// 배경(예전 버그): `AudioPlayerButton`의 State가 `AudioPlayer`를 직접 소유하고
/// `dispose()`에서 그 player를 같이 dispose했다. 그런데 카드 리스트는
/// `ListView.builder`로 타일을 지연 생성/폐기하기 때문에, 스크롤로 타일이
/// 뷰포트를 벗어나거나 · 카드를 접거나 · 선택모드에 들어가는 — 전부 지극히 정상적인
/// 조작 — 만으로도 위젯이 unmount되어 재생 중이던 음성이 뚝 끊겼다.
///
/// 여기서는 `AudioPlayer` 인스턴스를 이 싱글턴이 계속 들고 있고, 화면에 떠 있는
/// `AudioPlayerButton`들은 그저 (경로, 상태, 위치, 길이)를 구독해서 그리고
/// play/pause 같은 명령만 보낼 뿐 — 위젯이 사라져도 재생기는 죽지 않는다.
///
/// 동시에 하나의 파일만 재생한다(경로가 바뀌면 이전 재생은 정지+해제).
class AudioPlaybackController {
  AudioPlaybackController._();

  static final AudioPlaybackController instance = AudioPlaybackController._();

  AudioPlayer? _player;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<void>? _completeSub;

  /// 지금 이 컨트롤러가 추적 중인 파일 경로 (없으면 null).
  final ValueNotifier<String?> currentPath = ValueNotifier<String?>(null);
  final ValueNotifier<PlayerState> state =
      ValueNotifier<PlayerState>(PlayerState.stopped);
  final ValueNotifier<Duration> position =
      ValueNotifier<Duration>(Duration.zero);
  final ValueNotifier<Duration?> duration = ValueNotifier<Duration?>(null);

  /// [path]를 재생한다.
  /// - 이미 이 경로가 현재 추적 대상이면: playing이면 아무것도 안 하고,
  ///   paused면 이어서 재생하고, stopped/completed면 처음부터 다시 튼다.
  /// - 다른 경로면: 기존 재생을 정지+해제하고 새 player로 시작한다(동시 1개만 재생).
  /// [knownDuration]은 DB에 저장된 길이 — 실제 onDurationChanged가 오기 전
  /// 진행바/텍스트에 쓸 초기값 힌트일 뿐이다.
  /// 상태를 바꾸는 명령들의 직렬화 큐. 겹쳐 들어오면 한쪽의 `_resetToIdle()`과 다른 쪽의
  /// player 생성이 교차해 `AudioPlayer`가 두 개 살아남을 수 있었다(리뷰 D-02) — 앞선 명령이
  /// 끝난 뒤에만 다음 명령이 돈다.
  Future<void> _queue = Future<void>.value();

  Future<void> _serial(Future<void> Function() action) {
    final next = _queue.then((_) => action()).catchError((Object e) {
      debugPrint('[AUDIO] 재생 명령 실패: $e');
    });
    _queue = next;
    return next;
  }

  Future<void> play(String path, {Duration? knownDuration}) =>
      _serial(() => _playImpl(path, knownDuration: knownDuration));

  Future<void> _playImpl(String path, {Duration? knownDuration}) async {
    if (currentPath.value == path && _player != null) {
      final player = _player!;
      final s = state.value;
      try {
        if (s == PlayerState.playing) {
          return; // 이미 재생 중 — 중복 호출 무시
        } else if (s == PlayerState.paused) {
          await player.resume();
        } else {
          // stopped / completed → 처음부터 재생
          await player.play(DeviceFileSource(path));
        }
      } catch (_) {
        // 파일 손상/미존재 등 — 조용히 무시하고 idle로 되돌린다(기존 동작과 동일,
        // invariant: 죽은 파일이 crash로 이어지면 안 됨). 그 사이 다른 play() 호출이
        // 이미 새 player로 갈아탔다면 그건 건드리지 않는다.
        if (identical(_player, player)) {
          await _resetToIdle();
        }
      }
      return;
    }

    // 다른 파일(혹은 아무 것도 재생 중이 아님) → 기존 것을 완전히 정지+해제.
    await _resetToIdle();

    final player = AudioPlayer();
    _player = player;
    currentPath.value = path;
    state.value = PlayerState.stopped;
    position.value = Duration.zero;
    duration.value = knownDuration;

    _durationSub = player.onDurationChanged.listen((d) {
      duration.value = d;
    });
    _positionSub = player.onPositionChanged.listen((pos) {
      position.value = pos;
    });
    _stateSub = player.onPlayerStateChanged.listen((s) {
      state.value = s;
    });
    _completeSub = player.onPlayerComplete.listen((_) {
      state.value = PlayerState.completed;
      position.value = Duration.zero;
    });

    try {
      await player.play(DeviceFileSource(path));
    } catch (_) {
      // 파일 손상/미존재 — 조용히 무시(UI는 stopped로 유지). 그 사이 또 다른
      // play() 호출로 이미 갈아탄 상태라면 그 player는 건드리지 않는다.
      if (identical(_player, player)) {
        await _resetToIdle();
      }
    }
  }

  /// pause/seek도 같은 큐를 탄다 — 대기 중인 stop/play가 player를 해제하는 중에
  /// 끼어들면 이미 dispose된 player를 건드릴 수 있다(리뷰 APC-01).
  Future<void> pause() => _serial(() async {
        try {
          await _player?.pause();
        } catch (_) {}
      });

  Future<void> seek(Duration to) => _serial(() async {
        try {
          await _player?.seek(to);
        } catch (_) {}
      });

  /// 전체 정지 + player 해제.
  Future<void> stop() => _serial(_resetToIdle);

  /// [path]가 지금 추적/재생 중이면 정지+해제한다.
  /// 그 파일이 디스크에서 곧 삭제될 때(재녹음 교체, 수동 삭제) 호출해서
  /// 사라질 파일을 가리키는 player가 남지 않게 한다(감사 D2-07 invariant 6).
  Future<void> stopIfPlaying(String path) => _serial(() async {
        if (currentPath.value == path) {
          await _resetToIdle();
        }
      });

  /// player를 정지→해제하고 모든 상태를 idle로 되돌린다.
  /// ⚠️ dispose는 항상 이 async 함수 안에서 await 순서대로 직접 호출한다 —
  /// `Future.whenComplete(() => dispose())` 같은 콜백 체인에 얹지 않는다.
  /// 이 코드베이스는 그 패턴으로 `_dependents.isEmpty` assertion 크래시를 낸 전례가
  /// 있다(card_audio_field.dart의 녹음 정리 로직 참고). 여기서는 그런 콜백에
  /// dispose를 얹지 않고, 항상 명시적인 순차 흐름에서만 정리한다.
  Future<void> _resetToIdle() async {
    final player = _player;
    _player = null;
    await _durationSub?.cancel();
    await _positionSub?.cancel();
    await _stateSub?.cancel();
    await _completeSub?.cancel();
    _durationSub = null;
    _positionSub = null;
    _stateSub = null;
    _completeSub = null;

    currentPath.value = null;
    state.value = PlayerState.stopped;
    position.value = Duration.zero;
    duration.value = null;

    if (player != null) {
      try {
        await player.stop();
      } catch (_) {}
      try {
        await player.dispose();
      } catch (_) {}
    }
  }
}
