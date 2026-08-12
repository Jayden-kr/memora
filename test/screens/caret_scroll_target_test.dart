import 'package:flutter_test/flutter_test.dart';
import 'package:memora/screens/card_edit_screen.dart';

/// 긴 글을 칠 때 커서가 키보드 아래로 숨는 문제를 막는 계산.
///
/// 필드가 뷰포트보다 커지면 필드 전체를 기준으로 스크롤할 수 없다(필드 끝으로
/// 튄다). 대신 커서 줄이 뷰포트 위/아래 끝에 걸리는 두 스크롤 오프셋 사이를
/// "보이는 구간"으로 보고, 벗어났을 때만 가장 가까운 경계로 움직인다.
void main() {
  group('resolveCaretScrollTarget', () {
    // 커서 줄이 보이는 구간 = [200, 500] (아래 끝 걸침 200, 위 끝 걸침 500)
    const atBottom = 200.0;
    const atTop = 500.0;

    double target(double pixels, {double min = 0, double max = 2000}) =>
        resolveCaretScrollTarget(
          pixels: pixels,
          atTop: atTop,
          atBottom: atBottom,
          minExtent: min,
          maxExtent: max,
        );

    test('이미 보이는 구간 안이면 스크롤하지 않는다', () {
      expect(target(200), 200);
      expect(target(350), 350);
      expect(target(500), 500);
    });

    test('커서가 키보드 아래로 내려갔으면 딱 보일 만큼만 내린다', () {
      // 덜 스크롤된 상태 = 커서 줄이 뷰포트 아래에 있음
      expect(target(0), atBottom);
      expect(target(199), atBottom);
    });

    test('커서가 화면 위로 벗어났으면 딱 보일 만큼만 올린다', () {
      expect(target(501), atTop);
      expect(target(1200), atTop);
    });

    test('스크롤 한계를 넘지 않는다', () {
      // 목표가 max를 넘어가는 경우
      expect(target(0, max: 120), 120);
      // 목표가 min보다 작은 경우
      expect(target(1200, min: 800, max: 2000), 800);
    });

    test('atTop/atBottom 순서를 가정하지 않는다', () {
      final swapped = resolveCaretScrollTarget(
        pixels: 0,
        atTop: atBottom,
        atBottom: atTop,
        minExtent: 0,
        maxExtent: 2000,
      );
      expect(swapped, atBottom);
    });
  });
}
