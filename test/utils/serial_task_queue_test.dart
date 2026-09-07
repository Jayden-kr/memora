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

      final a = q.run(() => body('A', const Duration(milliseconds: 60)),
          timeout: const Duration(seconds: 5), onTimeout: () => 'timeout');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final b = q.run(() => body('B', const Duration(milliseconds: 10)),
          timeout: const Duration(seconds: 5), onTimeout: () => 'timeout');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final c = q.run(() => body('C', const Duration(milliseconds: 10)),
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

      final a = q.run(() => write('A', 1, hung.future),
          timeout: const Duration(milliseconds: 40), onTimeout: () => -1);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final b = q.run(() => write('B', 10, Future<void>.value()),
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

      final a = q.run(() => hung.future.then((_) => 'A'),
          timeout: const Duration(milliseconds: 30), onTimeout: () => 'gave-up');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final b = q.run(() async => 'B',
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
        () async => throw StateError('boom'),
        timeout: const Duration(seconds: 5),
        onTimeout: () => 'timeout',
        onError: errors.add,
      );
      expect(await a, 'timeout'); // 실패도 onTimeout 값으로 돌려준다
      final b = q.run(() async => 'B',
          timeout: const Duration(seconds: 5), onTimeout: () => 'timeout');
      expect(await b, 'B', reason: '앞 작업이 던져도 다음 사람은 돌아야 한다');
      expect(errors, isNotEmpty);
    });
  });
}
