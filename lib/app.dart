import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

class AmkiWangApp extends StatelessWidget {
  const AmkiWangApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '암기왕',
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
