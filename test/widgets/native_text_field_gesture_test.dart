import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memora/widgets/native_text_field.dart';

/// 편집 화면 스크롤 회귀 방지.
///
/// NativeTextField는 네이티브 EditText를 AndroidView로 띄운다. 여기에
/// EagerGestureRecognizer를 물리면 필드 위에서 시작된 포인터를 네이티브가
/// 전부 선점해 편집 화면(SingleChildScrollView)이 스크롤되지 않는다.
/// EditText는 내용 높이만큼 늘어나(minLines=1, maxLines=MAX_VALUE) 내부
/// 스크롤도 없으므로, 그 상태에선 드래그가 아무 일도 하지 않는다.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 테스트 환경엔 플랫폼 뷰 엔진이 없다 — create 응답만 흉내낸다.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
      if (call.method == 'create') return 0;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, null);
  });

  testWidgets('세로 드래그는 부모 스크롤에 양보하고 탭/롱프레스만 네이티브로 넘긴다',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: NativeTextField(initialText: 'hello'),
          ),
        ),
      ),
    );
    // 플랫폼 뷰 생성 실패는 이 테스트의 관심사가 아니다(엔진 없음).
    tester.takeException();

    final androidView = tester.widget<AndroidView>(find.byType(AndroidView));
    final recognizers =
        (androidView.gestureRecognizers ?? const {}).map((f) => f.constructor()).toList();
    addTearDown(() {
      for (final r in recognizers) {
        r.dispose();
      }
    });

    expect(
      recognizers.whereType<EagerGestureRecognizer>(),
      isEmpty,
      reason: 'Eager를 물면 필드 위 드래그를 네이티브가 선점해 편집 화면이 스크롤되지 않는다',
    );
    expect(
      recognizers.whereType<TapGestureRecognizer>(),
      isNotEmpty,
      reason: '탭이 네이티브로 가야 포커스/커서 배치가 된다',
    );
    expect(
      recognizers.whereType<LongPressGestureRecognizer>(),
      isNotEmpty,
      reason: '롱프레스가 네이티브로 가야 텍스트 선택이 된다',
    );
  });
}
