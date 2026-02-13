import 'package:flutter/material.dart';

/// App-wide dark theme.
///
/// Minimalist, high-contrast, privacy-oriented design.
/// No playful colors — this is a security tool, not a social app.
class AppTheme {
  AppTheme._();

  static const Color _background = Color(0xFF0D0D0D);
  static const Color _surface = Color(0xFF1A1A1A);
  static const Color _primary = Color(0xFF4FC3F7);
  static const Color _onPrimary = Color(0xFF000000);
  static const Color _error = Color(0xFFEF5350);
  static const Color _warning = Color(0xFFFFB74D);
  static const Color _success = Color(0xFF66BB6A);
  static const Color _text = Color(0xFFE0E0E0);
  static const Color _textSecondary = Color(0xFF9E9E9E);

  static Color get primary => _primary;
  static Color get error => _error;
  static Color get warning => _warning;
  static Color get success => _success;
  static Color get surface => _surface;
  static Color get textPrimary => _text;
  static Color get textSecondary => _textSecondary;

  static ThemeData get dark => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _background,
        colorScheme: const ColorScheme.dark(
          primary: _primary,
          onPrimary: _onPrimary,
          surface: _surface,
          error: _error,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: _surface,
          foregroundColor: _text,
          elevation: 0,
          centerTitle: true,
        ),
        cardTheme: CardTheme(
          color: _surface,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.white.withOpacity(0.06)),
          ),
        ),
        iconTheme: const IconThemeData(color: _textSecondary),
        textTheme: const TextTheme(
          headlineLarge: TextStyle(
            color: _text,
            fontSize: 24,
            fontWeight: FontWeight.w600,
          ),
          headlineMedium: TextStyle(
            color: _text,
            fontSize: 20,
            fontWeight: FontWeight.w500,
          ),
          bodyLarge: TextStyle(color: _text, fontSize: 16),
          bodyMedium: TextStyle(color: _text, fontSize: 14),
          bodySmall: TextStyle(color: _textSecondary, fontSize: 12),
          labelLarge: TextStyle(
            color: _primary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: _surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: _primary),
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: _primary,
            foregroundColor: _onPrimary,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: _primary,
            side: const BorderSide(color: _primary),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          ),
        ),
        dividerTheme: DividerThemeData(
          color: Colors.white.withOpacity(0.06),
          thickness: 1,
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: _surface,
          contentTextStyle: const TextStyle(color: _text),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
}

