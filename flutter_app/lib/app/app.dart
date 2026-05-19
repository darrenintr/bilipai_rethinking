import 'package:bilipai_flutter/features/home/home_screen.dart';
import 'package:flutter/material.dart';

class BiliPaiApp extends StatelessWidget {
  const BiliPaiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BiliPai Flutter',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFFB7299)),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
