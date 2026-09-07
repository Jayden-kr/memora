// LockScreenService.isDeviceSecure()의 실기기 채널 계약을 목 채널로 검증한다.
//
// "잠금화면 알림 내용 숨기기"가 화면 잠금(PIN/패턴/비밀번호) 없는 기기에서
// 조용히 무동작이던 문제(리뷰 발견)의 방어선 — 네이티브가 뭘 돌려주든/던지든
// 여기서 항상 "경고를 보여줘야 하는 쪽(false)"으로 fail해야 한다는 계약을 고정한다.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memora/services/lock_screen_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.henry.memora/lockscreen');

  void mockChannel(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('isDeviceSecure', () {
    test('네이티브가 true를 돌려주면 true', () async {
      mockChannel((call) async {
        expect(call.method, 'isDeviceSecure');
        return true;
      });
      expect(await LockScreenService.isDeviceSecure(), true);
    });

    test('네이티브가 false를 돌려주면 false', () async {
      mockChannel((call) async => false);
      expect(await LockScreenService.isDeviceSecure(), false);
    });

    test('채널이 예외를 던지면 false로 fail(경고를 보여주는 쪽)', () async {
      mockChannel((call) async {
        throw PlatformException(code: 'ERROR', message: 'boom');
      });
      expect(await LockScreenService.isDeviceSecure(), false);
    });

    test('채널이 null을 돌려줘도 false로 fail', () async {
      mockChannel((call) async => null);
      expect(await LockScreenService.isDeviceSecure(), false);
    });
  });

  group('openSecuritySettings', () {
    test('채널 호출 실패해도 던지지 않는다', () async {
      mockChannel((call) async {
        expect(call.method, 'openSecuritySettings');
        throw PlatformException(code: 'ERROR');
      });
      await expectLater(LockScreenService.openSecuritySettings(), completes);
    });
  });
}
