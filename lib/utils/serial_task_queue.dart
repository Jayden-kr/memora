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
/// ② **자리는 실제 작업이 끝나야 비운다. 타임아웃으로 풀지 않는다.**
///    `Future.timeout`은 대상을 취소하지 못한다. 자리를 비우는 순간 뒷사람이
///    들어오고, 고아가 된 앞 작업이 나중에 옛 스냅샷 그대로 뒷사람의 쓰기를 덮는다
///    — 없애려던 그 경쟁이 그대로 돌아온다. 상한을 30초에서 5분으로 늘려도 모양이
///    같으면 사고도 같다.
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

  /// [task]를 앞선 작업이 **실제로** 끝난 뒤에 실행한다.
  ///
  /// 반환은 [timeout] 안에 결과가 안 나오면 [onTimeout]의 값으로 돌아온다. 그래도
  /// **작업은 취소되지 않고 순서대로 끝까지 실행된다** — 호출자만 놓아줄 뿐이다.
  Future<T> run<T>(
    Future<T> Function() task, {
    required Duration timeout,
    required T Function() onTimeout,
    void Function(Object error)? onError,
  }) {
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
      return await task();
    }();

    // ② 자리는 이 작업이 실제로 끝나야 비워진다.
    unawaited(running.then<void>((_) {}, onError: (Object e) {
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
