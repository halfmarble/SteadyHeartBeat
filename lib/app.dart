import 'package:flutter/material.dart';
import 'constants.dart';
import 'screens/home_screen.dart';

class SteadyHeartBeatApp extends StatelessWidget {
  const SteadyHeartBeatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SteadyHeartBeat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBackground,
        colorScheme: const ColorScheme.dark(
          primary: kAccent,
          secondary: kAccent,
          surface: kSurface,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: kBackground,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        textTheme: const TextTheme(
          displayLarge: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w200,
            letterSpacing: -2,
          ),
          bodyMedium: TextStyle(color: kTextMuted),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: kAccent,
            foregroundColor: Colors.white,
            minimumSize: const Size(double.infinity, kButtonHeight),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kButtonRadius)),
            textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
