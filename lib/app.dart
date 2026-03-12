import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

/// 전역 테마 모드 notifier
final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier(ThemeMode.system);

/// 전역 네비게이터 키 (알림 탭 시 화면 이동용)
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class MemoraApp extends StatelessWidget {
  const MemoraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, themeMode, _) {
        return MaterialApp(
          title: 'Memora',
          navigatorKey: navigatorKey,
          theme: ThemeData(
            colorSchemeSeed: const Color(0xFFFF6B6B),
            useMaterial3: true,
            brightness: Brightness.light,
            fontFamily: 'Pretendard',
          ),
          darkTheme: ThemeData(
            colorSchemeSeed: const Color(0xFFFF6B6B),
            useMaterial3: true,
            brightness: Brightness.dark,
            fontFamily: 'Pretendard',
          ),
          themeMode: themeMode,
          home: const HomeScreen(),
          debugShowCheckedModeBanner: false,
        );
      },
    );
  }
}
