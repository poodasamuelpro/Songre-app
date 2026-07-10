import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:firebase_core/firebase_core.dart';
import 'theme/sauve_theme.dart';
import 'services/app_state.dart';
import 'router.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialiser Firebase (requis pour FCM notifications push)
  // try/catch : si Firebase échoue (pas de réseau, config manquante),
  // l'app continue quand même — les notifs push ne seront pas disponibles
  // mais l'app reste fonctionnelle.
  try {
    await Firebase.initializeApp();
  } catch (e) {
    if (kDebugMode) debugPrint('[main] Firebase.initializeApp failed: $e');
  }

  // Initialiser les formats de dates en français
  await initializeDateFormatting('fr_FR', null);

  // Créer et initialiser le state
  final appState = AppState();
  await appState.init();

  runApp(
    ChangeNotifierProvider<AppState>.value(
      value: appState,
      child: SauveApp(appState: appState),
    ),
  );
}

class SauveApp extends StatefulWidget {
  final AppState appState;

  const SauveApp({super.key, required this.appState});

  @override
  State<SauveApp> createState() => _SauveAppState();
}

class _SauveAppState extends State<SauveApp> {
  // Le router est créé UNE SEULE FOIS et conservé dans le State.
  // Si on le recrée dans build(), chaque notifyListeners() détruirait
  // l'état de navigation → écran noir / flash blanc.
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
      // Localisation française
      locale: const Locale('fr', 'FR'),
      builder: (context, child) {
        // Limite la taille sur desktop/web pour simuler un mobile
        if (!kIsWeb) return child!;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: Container(
              decoration: const BoxDecoration(
                color: SauveColors.creme,
                boxShadow: [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 60,
                    spreadRadius: 10,
                  ),
                ],
              ),
              child: child,
            ),
          ),
        );
      },
    );
  }
}
