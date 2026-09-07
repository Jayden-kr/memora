import 'dart:async';

/// 같은 자원을 건드리는 작업들을 **한 번에 하나씩** 실행시키는 큐.
///
/// 폴더 삭제 사후정리처럼 "설정을 읽고 → 고치고 → 되쓰기" 하는 작업이 두 화면에서
/// 동시에 시작될 수 있을 때 쓴다. 겹치면 늦게 끝난 쪽이 옛 스냅샷으로 먼저 끝난
/// 쪽의 쓰기를 덮는다.
///
/// 이 클래스는 같은 경쟁을 다섯 번 잘못 고치고 나서야 나온 모양이다. 아래 네 가지는
/// 전부 실제로 사고를 냈던 것이라 **하나도 바꾸지 말 것.** 각각 회귀 테스트가 있다
/// (test/utils/serial_task_queue_test.dart).
///
/// ① **자리 예약은 첫 `await`보다 먼저.** `await`는 이미 완료된 Future라도
///    continuation을 다음 마이크로태스크로 미룬다. 예약이 `await previous` 뒤에
///    있으면, 내가 기다리는 동안 큐에는 아직 앞사람 링크가 남아 **세 번째 호출이
///    나와 같은 것을 기다리다 함께 깨어난다.** 둘이 겹칠 땐 안 보이고 셋부터 보인다.
///
/// ② **자리는 실제 작업이 끝나야 비운다.** 기본은 타임아웃으로 풀지 않는다 —
///    `Future.timeout`은 대상을 취소하지 못해서, 자리를 비우는 순간 뒷사람이
///    들어오고 고아가 된 앞 작업이 나중에 옛 스냅샷 그대로 뒷사람의 쓰기를 덮을
///    수 있다. round7: 그래도 네이티브가 영영 답을 안 주는 최악의 경우 이후 모든
///    호출이 영구히 쌓이는 쪽이 더 나쁠 때는 [queueBackstop]으로 그 시간이 지나면
///    자리를 강제로 비울 수 있다 — 대신 [task]는 자신이 여전히 [activeGeneration]인지
///    쓰기 직전에 확인해서, 고아가 된 뒤에는 스스로 물러나야 한다(아래 [run] 참고).
///
/// ③ **호출자 상한은 "줄 서기 + 내 작업" 전체를 덮는다.** 내 작업에만 걸면 앞사람이
///    멈췄을 때 나는 줄에서 영원히 기다린다 — 첫 호출자만 보호되고 그 뒤는 전부
///    영구 정지한다.
///
/// ④ **상한이 끝나도 작업은 취소되지 않는다.** 포기하는 것은 "결과 보고"뿐이다.
///    줄 서는 중에 상한이 끝났다고 작업을 건너뛰면, 정리가 조용히 사라져 데이터가
///    낡은 채로 남는다 — 기다리게 하는 것보다 나쁘다.
class SerialTaskQueue {
  Future<void> _tail = Future<void>.value();

  /// round7: 예약 순서대로 늘어나는 세대 번호와, 지금 "네이티브를 두드려도 되는"
  /// 활성 세대. [queueBackstop]이 자리를 강제로 비워 다음 세대가 나보다 먼저
  /// 활성화되면, 뒤늦게 깨어난 옛 세대는 [activeGeneration]이 자기 번호를 앞질러
  /// 있는 걸 보고 쓰기를 건너뛸 수 있다 — 그 판단은 [task] 쪽 책임이라 세대 번호를
  /// 그대로 인자로 넘겨준다. **예약만 되고 아직 차례가 안 온 세대는 세지 않는다**:
  /// 정상적으로 줄을 선 것뿐이라 그동안 [activeGeneration]은 그대로다(안 그러면
  /// 뒤에 아무나 줄만 서도 앞사람이 스스로를 stale로 오판한다).
  int _generationSeq = 0;
  int _activeGeneration = 0;
  int get activeGeneration => _activeGeneration;

  /// [task]를 앞선 작업이 **실제로** 끝난 뒤에 실행한다. [task]는 이번 호출의 세대
  /// 번호를 인자로 받는다 — [queueBackstop]을 쓸 때 [activeGeneration]과 비교해
  /// 자신이 여전히 최신인지 확인하는 용도다.
  ///
  /// 반환은 [timeout] 안에 결과가 안 나오면 [onTimeout]의 값으로 돌아온다. 그래도
  /// **작업은 취소되지 않고 순서대로 끝까지 실행된다** — 호출자만 놓아줄 뿐이다.
  ///
  /// [queueBackstop]을 주면, 그 시간이 지나도 [task]가 안 끝났을 때 큐 자리를
  /// 강제로 비운다(②). 생략(기본값 null)하면 자리는 계속 실제 작업이 끝날 때까지만
  /// 비워진다. **[queueBackstop]을 쓰는 [task]는 실제로 쓰기 전에 반드시
  /// `activeGeneration != (자신에게 주어진 세대)`로 고아가 됐는지 확인해야 한다** —
  /// 그러지 않으면 뒤늦게 깨어난 고아가 최신 결과를 옛 스냅샷으로 덮어쓴다(리뷰 R6-1).
  Future<T> run<T>(
    Future<T> Function(int generation) task, {
    required Duration timeout,
    required T Function() onTimeout,
    void Function(Object error)? onError,
    Duration? queueBackstop,
  }) {
    final myGeneration = ++_generationSeq;
    final previous = _tail;
    final slot = Completer<void>();
    _tail = slot.future; // ① 첫 await보다 먼저

    // ④ 호출자와 무관하게 돌아간다. 상한이 끝나도 이 Future는 계속 진행한다.
    final running = () async {
      try {
        await previous;
      } catch (e) {
        onError?.call(e);
      }
      _activeGeneration = myGeneration; // 이제 내 차례 — 활성 세대 갱신
      return await task(myGeneration);
    }();

    // ② 자리는 원칙적으로 이 작업이 실제로 끝나야 비워진다. [queueBackstop]이
    // 있으면 그 시간이 지났을 때도 강제로 비운다. 그 뒤로도 [running] 자체는
    // 취소되지 않고 계속 실행된다 — 뒤늦게 끝났을 때 스스로 활성 세대가 아님을
    // 보고 쓰기를 건너뛰는 건 [task] 쪽 책임이다.
    final released =
        queueBackstop == null ? running : running.timeout(queueBackstop);
    unawaited(released.then<void>((_) {}, onError: (Object e) {
      onError?.call(e);
    }).whenComplete(() {
      if (!slot.isCompleted) slot.complete();
    }));

    // ③ 상한은 줄 서기까지 포함한 전체를 덮는다.
    return running.timeout(timeout, onTimeout: onTimeout).catchError((Object e) {
      onError?.call(e);
      return onTimeout();
    });
  }
}
