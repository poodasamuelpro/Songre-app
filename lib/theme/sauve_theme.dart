import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// =====================================================================
// PALETTE — fidèle à la charte graphique du cahier des charges
// =====================================================================
class SauveColors {
  SauveColors._();

  // Rouges
  static const Color rouge = Color(0xFFC81E3A);
  static const Color rougeFonce = Color(0xFF7A1226);

  // Fonds
  static const Color creme = Color(0xFFFAF6F4);
  static const Color carte = Color(0xFFFFFFFF);

  // Textes
  static const Color encre = Color(0xFF201A1B);
  static const Color gris = Color(0xFF8B7D7A);
  static const Color grisClair = Color(0xFFEDE3E1);

  // Succès
  static const Color vert = Color(0xFF2F7D5C);
  static const Color vertFond = Color(0xFFE7F3ED);

  // Gradient urgence
  static const LinearGradient gradientUrgence = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [rouge, rougeFonce],
  );

  // Erreur (même rouge)
  static const Color erreur = rouge;
}

// =====================================================================
// THÈME PRINCIPAL
// =====================================================================
class SauveTheme {
  SauveTheme._();

  static ThemeData get light {
    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: SauveColors.creme,
      colorScheme: ColorScheme.fromSeed(
        seedColor: SauveColors.rouge,
        primary: SauveColors.rouge,
        secondary: SauveColors.rougeFonce,
        surface: SauveColors.carte,
        error: SauveColors.erreur,
        brightness: Brightness.light,
      ),
      textTheme: _buildTextTheme(),
      appBarTheme: AppBarTheme(
        backgroundColor: SauveColors.creme,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: GoogleFonts.archivo(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: SauveColors.encre,
        ),
        iconTheme: const IconThemeData(color: SauveColors.encre),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: SauveColors.rouge,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.symmetric(vertical: 16),
          textStyle: GoogleFonts.archivo(
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: SauveColors.rouge,
          side: const BorderSide(color: SauveColors.rouge, width: 1.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(vertical: 13),
          textStyle: GoogleFonts.archivo(
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      cardTheme: CardThemeData(
        color: SauveColors.carte,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: SauveColors.grisClair),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: SauveColors.carte,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: SauveColors.grisClair, width: 1.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: SauveColors.grisClair, width: 1.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: SauveColors.rouge, width: 1.5),
        ),
        contentPadding: const EdgeInsets.all(14),
        labelStyle: GoogleFonts.inter(
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          color: SauveColors.gris,
          letterSpacing: 0.04,
        ),
        hintStyle: GoogleFonts.inter(
          fontSize: 14.5,
          color: SauveColors.gris,
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: SauveColors.carte,
        selectedItemColor: SauveColors.rouge,
        unselectedItemColor: SauveColors.gris,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
        selectedLabelStyle: GoogleFonts.inter(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelStyle: GoogleFonts.inter(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
        ),
      ),
      dividerColor: SauveColors.grisClair,
      dividerTheme: const DividerThemeData(
        color: SauveColors.grisClair,
        thickness: 1,
        space: 0,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return Colors.white;
          return SauveColors.gris;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return SauveColors.vert;
          return SauveColors.grisClair;
        }),
      ),
    );
  }

  static TextTheme _buildTextTheme() {
    return TextTheme(
      // Titres display (Archivo)
      displayLarge: GoogleFonts.archivo(
        fontSize: 32, fontWeight: FontWeight.w900, color: SauveColors.encre,
      ),
      displayMedium: GoogleFonts.archivo(
        fontSize: 28, fontWeight: FontWeight.w800, color: SauveColors.encre,
      ),
      displaySmall: GoogleFonts.archivo(
        fontSize: 22, fontWeight: FontWeight.w700, color: SauveColors.encre,
      ),
      // Titres (Archivo)
      headlineLarge: GoogleFonts.archivo(
        fontSize: 20, fontWeight: FontWeight.w700, color: SauveColors.encre,
      ),
      headlineMedium: GoogleFonts.archivo(
        fontSize: 18, fontWeight: FontWeight.w700, color: SauveColors.encre,
      ),
      headlineSmall: GoogleFonts.archivo(
        fontSize: 16, fontWeight: FontWeight.w700, color: SauveColors.encre,
      ),
      // Corps de texte (Inter)
      bodyLarge: GoogleFonts.inter(
        fontSize: 15, fontWeight: FontWeight.w400, color: SauveColors.encre,
      ),
      bodyMedium: GoogleFonts.inter(
        fontSize: 14, fontWeight: FontWeight.w400, color: SauveColors.encre,
      ),
      bodySmall: GoogleFonts.inter(
        fontSize: 12.5, fontWeight: FontWeight.w400, color: SauveColors.gris,
      ),
      // Labels
      labelLarge: GoogleFonts.inter(
        fontSize: 14, fontWeight: FontWeight.w600, color: SauveColors.encre,
      ),
      labelMedium: GoogleFonts.inter(
        fontSize: 12.5, fontWeight: FontWeight.w600, color: SauveColors.gris,
      ),
      labelSmall: GoogleFonts.inter(
        fontSize: 11, fontWeight: FontWeight.w600, color: SauveColors.gris,
        letterSpacing: 0.08,
      ),
    );
  }
}
