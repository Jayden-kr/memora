import 'package:flutter/material.dart';

import 'l10n/app_localizations.dart';
import 'screens/home_screen.dart';
import 'services/locale_service.dart';

/// 전역 테마 모드 notifier
final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier(ThemeMode.system);

/// 전역 네비게이터 키 (알림 탭 시 화면 이동용)
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// 화면 밖(알림·잠금화면 콜백)에서 SnackBar를 띄우기 위한 전역 키. 이 경로들은
/// 특정 화면의 BuildContext를 갖고 있지 않다.
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// 전역 RouteObserver (RouteAware 위젯에서 화면 복귀 감지용)
final RouteObserver<ModalRoute<void>> routeObserver =
    RouteObserver<ModalRoute<void>>();

class MemoraApp extends StatelessWidget {
  const MemoraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, themeMode, _) {
        return ValueListenableBuilder<Locale?>(
          valueListenable: LocaleService.localeNotifier,
          builder: (context, locale, _) {
            return MaterialApp(
              title: 'Memora',
              navigatorKey: navigatorKey,
              scaffoldMessengerKey: scaffoldMessengerKey,
              navigatorObservers: [routeObserver],
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
              locale: locale,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const HomeScreen(),
              debugShowCheckedModeBanner: false,
            );
          },
        );
      },
    );
  }
}
