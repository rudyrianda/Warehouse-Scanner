import 'package:flutter/material.dart';

class AppTheme {
  static const Color primaryBlue = Color(0xFF0050C9);
  static const Color lightBlue = Color(0xFFE8F0FE);
  static const Color borderBlue = Color(0xFFB3C8F5);

  static ThemeData get theme => ThemeData(
        useMaterial3: true,
        colorSchemeSeed: primaryBlue,
        scaffoldBackgroundColor: const Color(0xFFF5F5F5),
        inputDecorationTheme: const InputDecorationTheme(
          isDense: true,
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        ),
      );
}
