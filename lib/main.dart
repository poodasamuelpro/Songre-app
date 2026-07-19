import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:firebase_core/firebase_core.dart';
import 'theme/sauve_theme.dart';
import 'services/app_state.dart';
import 'responsive/breakpoints.dart';
import 'router.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Firebase — initialisé uniquement sur Android (et iOS le moment venu).
  // Sur Web, Firebase n'est pas configuré (pas de firebase_options.dart,
  // pas de google-services Web) — on évite la tentative silencieuse ratée.
  if (!kIsWeb) {
    try {
      await Firebase.initializeApp();
    } catch (e) {
      if (kDebugMode) debugPrint('[main] Firebase init skipped: $e');
    }
  }

  // Formats de dates en français
  await initializeDateFormatting('fr_FR', null);

  // AppState : chargement complet avant runApp
  final appState = AppState();
  await appState.init();

  runApp(
    ChangeNotifierProvider<AppState>.value(
      value: appState,
      child: SauveApp(appState: appState),
    ),
  );
}

// ---------------------------------------------------------------------------
// SauveApp — StatefulWidget pour conserver le GoRouter dans le State.
// CRITIQUE : si SauveApp est StatelessWidget, buildRouter() est appelé à
// chaque notifyListeners() → nouveau GoRouter → perte d'état → écran noir.
// ---------------------------------------------------------------------------
class SauveApp extends StatefulWidget {
  final AppState appState;
  const SauveApp({super.key, required this.appState});

  @override
  State<SauveApp> createState() => _SauveAppState();
}

class _SauveAppState extends State<SauveApp> {
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _router = buildRouter(widget.appState);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'SONGRE',
      debugShowCheckedModeBanner: false,
      theme: SauveTheme.light,
      routerConfig: _router,
      locale: const Locale('fr', 'FR'),
      // ---------------------------------------------------------------------------
      // CORRECTION ÉCRAN NOIR : le builder ne doit JAMAIS retourner child!
      // sur Android. child peut être null pendant la première frame de GoRouter.
      // Sur mobile on retourne child directement sans contrainte de largeur.
      // Sur web on ajoute la contrainte de largeur max 430px.
      // ---------------------------------------------------------------------------
      builder: (context, child) {
        // child est null uniquement pendant un bref instant au démarrage.
        // On affiche un fond de couleur neutre (pas d'écran noir) en attendant.
        final safeChild = child ?? const Scaffold(
          backgroundColor: SauveColors.creme,
          body: Center(child: CircularProgressIndicator()),
        );

        if (kIsWeb) {
          // Responsive Web : layout adaptatif selon la largeur d'écran.
          // Mobile web (<600px)  → colonne centrée max 430px (UX mobile)
          // Tablet web (600–1024)→ contenu centré max 800px avec marges
          // Desktop web (>1024px)→ contenu centré max 1200px (sidebar gérée par router)
          return LayoutBuilder(
            builder: (context, constraints) {
              final screenSize = getScreenSize(context);
              final double maxWidth = switch (screenSize) {
                ScreenSize.mobile  => 430.0,
                ScreenSize.tablet  => 800.0,
                ScreenSize.desktop => SongreBreakpoints.contentMaxWidth,
              };
              return Container(
                color: SauveColors.creme,
                width: double.infinity,
                height: double.infinity,
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    child: safeChild,
                  ),
                ),
              );
            },
          );
        }

        // Android / iOS : retour direct, aucune contrainte de largeur
        return safeChild;
      },
    );
  }
}
