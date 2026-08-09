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
      // Dynamic Type, bounded. Every label is a Text widget, so it already
      // follows the system text-size setting; this clamp keeps the extremes
      // safe rather than opting out: cap at 1.4× so fixed-height chrome (the
      // BPM display, control bar, stat chips, chart axes) scales without
      // clipping, and floor at 1.0× so a "smaller text" setting never shrinks
      // workout-critical numbers below their designed size.
      builder: (context, child) {
        final clamped = MediaQuery.textScalerOf(context)
            .clamp(minScaleFactor: 1.0, maxScaleFactor: 1.4);
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: clamped),
          child: child!,
        );
      },
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
