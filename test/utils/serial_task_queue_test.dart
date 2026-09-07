// SerialTaskQueue 회귀 테스트.
//
// 이 세 가지는 전부 폴더 삭제 사후정리에서 실제로 사고를 냈던 것이다. 다섯 계층에
// 걸쳐 리뷰가 하나씩 잡아냈고, 그때마다 검증은 커밋 메시지에만 남는 임시 스크립트였다.
// 그래서 다음 계층이 같은 것을 또 깨뜨렸다 — 여기 못으로 박는다.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:memora/utils/serial_task_queue.dart';

void main() {
  group('SerialTaskQueue', () {
    test('세 개가 겹쳐도 한 번에 하나만 돈다', () async {
      // 둘이 겹칠 땐 드러나지 않는다. 자리 예약이 첫 await 뒤에 있으면 세 번째가
      // 두 번째와 같은 것을 기다리다 함께 깨어난다(실제 사고).
      final q = SerialTaskQueue();
      var concurrent = 0;
      var maxConcurrent = 0;
      final finished = <String>[];

      Future<String> body(String tag, Duration d) async {
        concurrent++;
        if (concurrent > maxConcurrent) maxConcurrent = concurrent;
        await Future<void>.delayed(d);
        concurrent--;
        finished.add(tag);
        return tag;
      }

      final a = q.run((_) => body('A', const Duration(milliseconds: 60)),
          timeout: const Duration(seconds: 5), onTimeout: () => 'timeout');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final b = q.run((_) => body('B', const Duration(milliseconds: 10)),
          timeout: const Duration(seconds: 5), onTimeout: () => 'timeout');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final c = q.run((_) => body('C', const Duration(milliseconds: 10)),
          timeout: const Duration(seconds: 5), onTimeout: () => 'timeout');

      await Future.wait([a, b, c]);
      expect(maxConcurrent, 1, reason: '동시에 둘 이상이 돌면 안 된다');
      expect(finished, ['A', 'B', 'C'], reason: '들어온 순서대로 끝나야 한다');
    });

    test('앞 작업이 멈춰 있으면 뒷사람은 기다린다 — 자리를 타임아웃으로 비우지 않는다',
        () async {
      // 자리를 타임아웃으로 비우면, 고아가 된 앞 작업이 나중에 옛 스냅샷으로
      // 뒷사람의 쓰기를 덮는다. 30초든 5분이든 모양이 같으면 사고도 같다.
      final q = SerialTaskQueue();
      final hung = Completer<void>();
      var store = 0;
      final log = <String>[];

      Future<int> write(String tag, int add, Future<void> gate) async {
        final snapshot = store;
        await gate;
        store = snapshot + add;
        log.add('$tag:$store');
        return store;
      }

      final a = q.run((_) => write('A', 1, hung.future),
          timeout: const Duration(milliseconds: 40), onTimeout: () => -1);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final b = q.run((_) => write('B', 10, Future<void>.value()),
          timeout: const Duration(milliseconds: 40), onTimeout: () => -1);

      // A는 상한에 걸려 호출자에게 먼저 돌아온다.
      expect(await a, -1);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(log, isEmpty, reason: 'A가 멈춰 있는 동안 B가 먼저 쓰면 안 된다');

      // B의 호출자도 상한에 걸려 이미 돌아왔다(③). 하지만 작업은 취소되지 않는다(④).
      expect(await b, -1);
      expect(log, isEmpty, reason: 'B의 호출자가 포기해도 아직 A 차례다');

      hung.complete(); // 네이티브가 뒤늦게 답했다
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(log, ['A:1', 'B:11'],
          reason: '호출자가 포기해도 두 작업은 순서대로 끝까지 실행돼야 한다');
      expect(store, 11);
    });

    test('앞사람이 멈춰도 뒷사람 호출자는 상한 안에 돌아온다', () async {
      // 상한을 "내 작업"에만 걸면 앞사람이 멈췄을 때 뒷사람은 줄 서기에서 영원히
      // 기다린다. 첫 호출자만 보호되고 그 뒤는 전부 영구 정지했다(실제 사고).
      final q = SerialTaskQueue();
      final hung = Completer<void>();

      final a = q.run((_) => hung.future.then((_) => 'A'),
          timeout: const Duration(milliseconds: 30), onTimeout: () => 'gave-up');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final b = q.run((_) async => 'B',
          timeout: const Duration(milliseconds: 30), onTimeout: () => 'gave-up');

      expect(await a, 'gave-up');
      expect(await b, 'gave-up',
          reason: '줄 서기까지 상한이 덮어야 두 번째 호출자도 풀려난다');

      hung.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });

    test('작업이 던져도 큐가 막히지 않는다', () async {
      final q = SerialTaskQueue();
      final errors = <Object>[];
      final a = q.run<String>(
        (_) async => throw StateError('boom'),
        timeout: const Duration(seconds: 5),
        onTimeout: () => 'timeout',
        onError: errors.add,
      );
      expect(await a, 'timeout'); // 실패도 onTimeout 값으로 돌려준다
      final b = q.run((_) async => 'B',
          timeout: const Duration(seconds: 5), onTimeout: () => 'timeout');
      expect(await b, 'B', reason: '앞 작업이 던져도 다음 사람은 돌아야 한다');
      expect(errors, isNotEmpty);
    });

    test('세대는 예약이 아니라 실행 시작 시점에 올라간다 — 정상 큐잉은 stale이 아니다',
        () async {
      // round7: activeGeneration을 "예약된 최댓값"으로 재면, 뒷사람이 줄만 서도
      // 아직 정상 실행 중인 앞사람이 스스로를 고아로 오판한다. activeGeneration은
      // 반드시 "실행이 시작된" 세대만 가리켜야 한다.
      final q = SerialTaskQueue();
      final aStarted = Completer<void>();
      final releaseA = Completer<void>();

      final a = q.run((gen) async {
        aStarted.complete();
        await releaseA.future;
        return gen;
      }, timeout: const Duration(seconds: 5), onTimeout: () => -1);

      await aStarted.future;
      expect(q.activeGeneration, 1, reason: 'A가 도는 동안엔 활성 세대가 1이어야 한다');

      // B는 예약만 해둔다 — 아직 A 차례라 실행되지 않는다.
      final b = q.run((gen) async => gen,
          timeout: const Duration(seconds: 5), onTimeout: () => -1);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(q.activeGeneration, 1, reason: '''
B가 예약만 됐을 뿐 아직 시작 전이면 활성 세대는 그대로 A(1)여야 한다.
정상적으로 줄을 선 것뿐인데 A가 스스로 stale로 오판하면 A의 정당한 쓰기까지
건너뛰게 된다.
''');

      releaseA.complete();
      expect(await a, 1);
      expect(await b, 2);
      expect(q.activeGeneration, 2);
    });

    test(
        '백스톱으로 자리가 강제로 비워진 뒤 옛 작업이 뒤늦게 깨어나면, activeGeneration으로 '
        '스스로 쓰기를 건너뛴다', () async {
      // round7: LockScreenService.removeFoldersFromSettingsBatch가 실제로 겪는
      // 모양 그대로다 — 5분 백스톱이 자리를 비워 뒷사람이 먼저 쓰고 끝나면, 뒤늦게
      // 깨어난 앞사람이 옛 스냅샷으로 그 결과를 덮어쓸 수 있다(리뷰 R6-1). task가
      // 쓰기 직전에 자기 세대를 확인해 스스로 물러나야 한다.
      final q = SerialTaskQueue();
      final hungA = Completer<void>();
      var store = 0;
      final log = <String>[];
      const staleSkip = -99;

      Future<int> writeIfCurrent(
          String tag, int generation, int add, Future<void> gate) async {
        await gate;
        if (q.activeGeneration != generation) {
          log.add('$tag:stale-skip');
          return staleSkip; // 더 최신 세대가 이미 활성 — 옛 스냅샷 쓰기 포기
        }
        store += add;
        log.add('$tag:$store');
        return store;
      }

      final a = q.run(
        (gen) => writeIfCurrent('A', gen, 1, hungA.future),
        timeout: const Duration(seconds: 5),
        onTimeout: () => -1,
        queueBackstop: const Duration(milliseconds: 30),
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final b = q.run(
        (gen) => writeIfCurrent('B', gen, 10, Future<void>.value()),
        timeout: const Duration(seconds: 5),
        onTimeout: () => -1,
      );

      // A는 백스톱(30ms)에 걸려 자리를 비워주고, B가 그 자리를 이어받아 즉시 쓴다.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(log, ['B:10'],
          reason: 'A가 아직 안 깨어난 동안 B가 활성 세대로 먼저 써야 한다');
      expect(store, 10);

      hungA.complete(); // A가 뒤늦게 깨어난다
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(log, ['B:10', 'A:stale-skip'], reason: '''
A는 자신이 더 이상 활성 세대가 아님을 보고 옛 스냅샷 쓰기를 건너뛰어야 한다.
이게 없으면 A가 store를 11로 되돌려 B가 이미 반영한 10을 지운다.
''');
      expect(store, 10, reason: 'A의 stale write가 B의 결과를 덮으면 안 된다');
      expect(await a, staleSkip);
      expect(await b, 10);
    });
  });
}
