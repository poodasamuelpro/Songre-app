import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'theme/sauve_theme.dart';
import 'services/app_state.dart';
import 'router.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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

class SauveApp extends StatelessWidget {
  final AppState appState;

  const SauveApp({super.key, required this.appState});

  @override
  Widget build(BuildContext context) {
    final router = buildRouter(appState);

    return MaterialApp.router(
      title: 'SONGRE',
      debugShowCheckedModeBanner: false,
      theme: SauveTheme.light,
      routerConfig: router,
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
