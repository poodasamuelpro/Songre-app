import 'package:flutter/material.dart';

// =====================================================================
// SONGRE — Système de breakpoints responsive
//
// Mobile  : < 600 px  → layout 1 colonne, navigation bottom bar
// Tablet  : 600–1024 px → layout 2 colonnes potentiel, marges augmentées
// Desktop : > 1024 px → layout 3 colonnes, navigation rail ou drawer
//
// Ces breakpoints ne s'appliquent QUE sur kIsWeb — sur Android/iOS le
// layout natif est inchangé (aucune contrainte de largeur ajoutée).
// =====================================================================

class SongreBreakpoints {
  SongreBreakpoints._();

  static const double mobile = 600.0;
  static const double tablet = 1024.0;

  // Largeur maximale du contenu centré en mode desktop
  static const double contentMaxWidth = 1200.0;

  // Largeur du panneau latéral en mode desktop (drawer permanent)
  static const double sidebarWidth = 280.0;

  // Largeur d'une "colonne formulaire" — même en desktop, les formulaires
  // restent lisibles et ergonomiques avec une largeur limitée
  static const double formMaxWidth = 600.0;
}

enum ScreenSize { mobile, tablet, desktop }

/// Retourne la taille d'écran actuelle selon les breakpoints SONGRE.
ScreenSize getScreenSize(BuildContext context) {
  final width = MediaQuery.of(context).size.width;
  if (width < SongreBreakpoints.mobile) return ScreenSize.mobile;
  if (width < SongreBreakpoints.tablet) return ScreenSize.tablet;
  return ScreenSize.desktop;
}

/// Widget utilitaire : applique un padding horizontal adaptatif selon la taille.
class ResponsivePadding extends StatelessWidget {
  final Widget child;
  final double mobilePadding;
  final double tabletPadding;
  final double desktopPadding;

  const ResponsivePadding({
    super.key,
    required this.child,
    this.mobilePadding = 20.0,
    this.tabletPadding = 40.0,
    this.desktopPadding = 80.0,
  });

  @override
  Widget build(BuildContext context) {
    final size = getScreenSize(context);
    final padding = switch (size) {
      ScreenSize.mobile  => mobilePadding,
      ScreenSize.tablet  => tabletPadding,
      ScreenSize.desktop => desktopPadding,
    };
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: padding),
      child: child,
    );
  }
}

/// Conteneur centré avec largeur maximale — utilisé pour les formulaires
/// et les vues "card" sur desktop/tablet.
class ResponsiveCenter extends StatelessWidget {
  final Widget child;
  final double maxWidth;

  const ResponsiveCenter({
    super.key,
    required this.child,
    this.maxWidth = SongreBreakpoints.formMaxWidth,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
