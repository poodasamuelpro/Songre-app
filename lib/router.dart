import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../theme/sauve_theme.dart';
import '../services/app_state.dart';
import '../screens/home_screen.dart';
import '../screens/demandes_screen.dart';
import '../screens/notifications_screen.dart';
import '../screens/profil_screen.dart';
import '../screens/login_screen.dart';
import '../screens/nouvelle_demande_screen.dart';
import '../screens/detail_demande_screen.dart';
import '../screens/scan_qr_screen.dart';
import '../screens/reset_password_screen.dart';
import '../models/models.dart';

// =====================================================================
// NAVIGATION — Go Router + Bottom Navigation Shell
// =====================================================================

final GlobalKey<NavigatorState> _rootNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'root');
final GlobalKey<NavigatorState> _shellNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'shell');

GoRouter buildRouter(AppState appState) {
  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/',
    redirect: (ctx, state) {
      final isAuth = appState.isAuthenticated;
      final hasProfil = appState.profil != null;
      final isLoading = appState.isLoading;
      final location = state.matchedLocation;
      final isLogin = location == '/';
      final isCompleteProfil = location == '/completer-profil';
      // reset-password : accessible TOUJOURS, qu'on soit auth ou non.
      // Un utilisateur authentifié peut aussi cliquer sur le lien email.
      // On vérifie le début du path pour couvrir les cas avec fragment.
      final isResetPassword = location == '/reset-password' ||
          location.startsWith('/reset-password');

      // reset-password : toujours accessible — aucune redirection
      if (isResetPassword) return null;

      // Guard de transition : pendant le chargement initial ou la déconnexion,
      // ne pas évaluer les règles de navigation pour éviter les redirections
      // vers /completer-profil alors que l'état est en cours de purge.
      // La règle !isLogin est critique ici : sans elle, un utilisateur
      // en cours de déconnexion (isAuth=true transitoire, profil=null) est
      // redirigé vers /completer-profil plutôt que vers / (login).
      if (isLoading) return null;

      // Non authentifié → toujours login
      if (!isAuth && !isLogin) return '/';

      // Authentifié + profil → quitte login vers home
      if (isAuth && hasProfil && isLogin) return '/home';

      // Authentifié SANS profil → forcer la création du profil.
      // Couvre DEUX cas :
      //   1. Authentifié sur '/' (login) sans profil → /completer-profil
      //      (règle distincte de la règle "quitte login" qui exige hasProfil)
      //   2. Authentifié sur n'importe quelle autre route sans profil → /completer-profil
      // !isCompleteProfil évite la boucle redirect infinie sur /completer-profil.
      if (isAuth && !hasProfil && !isCompleteProfil) {
        return '/completer-profil';
      }

      return null;
    },
    refreshListenable: appState,
    routes: [
      // Login
      GoRoute(
        path: '/',
        builder: (ctx, state) => const LoginScreen(),
      ),
      // Shell avec bottom nav
      ShellRoute(
        navigatorKey: _shellNavigatorKey,
        builder: (ctx, state, child) => MainShell(child: child),
        routes: [
          GoRoute(
            path: '/home',
            builder: (ctx, state) => const HomeScreen(),
          ),
          GoRoute(
            path: '/demandes',
            builder: (ctx, state) => const DemandesScreen(),
          ),
          GoRoute(
            path: '/alertes',
            builder: (ctx, state) => const NotificationsScreen(),
          ),
          GoRoute(
            path: '/profil',
            builder: (ctx, state) => const ProfilScreen(),
          ),
        ],
      ),
      // [2.8] Route /completer-profil — formulaire de création de profil
      // Affichée après inscription email si le profil n'est pas encore rempli.
      // LoginScreen avec initialStep=3 réutilise _ProfilForm existant sans duplication.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/completer-profil',
        pageBuilder: (ctx, state) => CustomTransitionPage(
          child: const LoginScreen(initialStep: 3),
          transitionsBuilder: (ctx, animation, _, child) {
            return FadeTransition(opacity: animation, child: child);
          },
        ),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/reset-password',
        pageBuilder: (ctx, state) {
          // ──────────────────────────────────────────────────────────────────
          // EXTRACTION DU TOKEN — Supabase peut envoyer le token de deux façons :
          //
          // 1. QUERY PARAMS (format moderne, PKCEflow) :
          //    songre://reset-password?access_token=eyJ...&type=recovery
          //
          // 2. FRAGMENT HASH (format classique / lien email direct) :
          //    songre://reset-password#access_token=eyJ...&type=recovery
          //    https://songre.vercel.app/reset-password#access_token=eyJ...
          //
          // state.uri.queryParameters ne contient QUE les params après '?'.
          // Le fragment '#...' est dans state.uri.fragment et doit être parsé
          // manuellement car Dart Uri ne le parse pas automatiquement.
          // ──────────────────────────────────────────────────────────────────

          // Étape 1 : tenter les query params (format PKCEflow)
          String accessToken = state.uri.queryParameters['access_token'] ??
              state.uri.queryParameters['token'] ??
              '';
          String type = state.uri.queryParameters['type'] ?? '';

          // Étape 2 : si vide, parser le fragment manuellement
          if (accessToken.isEmpty) {
            final fragment = state.uri.fragment; // ex: "access_token=eyJ...&type=recovery"
            if (fragment.isNotEmpty) {
              final fragmentParams = Uri.splitQueryString(fragment);
              accessToken = fragmentParams['access_token'] ??
                  fragmentParams['token'] ??
                  '';
              if (type.isEmpty) {
                type = fragmentParams['type'] ?? '';
              }
            }
          }

          return CustomTransitionPage(
            child: ResetPasswordScreen(
              accessToken: accessToken,
              type: type,
            ),
            transitionsBuilder: (ctx, animation, _, child) {
              return FadeTransition(opacity: animation, child: child);
            },
          );
        },
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/nouvelle-demande',
        pageBuilder: (ctx, state) => CustomTransitionPage(
          child: const NouvelleDemande(),
          transitionsBuilder: (ctx, animation, _, child) {
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 1),
                end: Offset.zero,
              ).animate(CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
              )),
              child: child,
            );
          },
        ),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/scan-qr',
        redirect: (ctx, state) {
          // [Sécurité T9] Bloc HARD : si demandeurId vide ou absent, refuser la navigation
          // avant même de construire l'écran ScanQrScreen.
          // Cela empêche un utilisateur non authentifié d'accéder au scanner QR.
          final demandeurId = state.extra as String? ?? '';
          if (demandeurId.isEmpty) {
            // Redirection vers l'accueil — l'utilisateur n'est pas authentifié
            // ou AppState.userId est null (ne pas laisser passer un écran cassé)
            return '/home';
          }
          return null; // autoriser la navigation
        },
        pageBuilder: (ctx, state) {
          // demandeurId est garanti non-vide grâce au redirect ci-dessus
          final demandeurId = state.extra as String? ?? '';
          return CustomTransitionPage(
            child: ScanQrScreen(demandeurId: demandeurId),
            transitionsBuilder: (ctx, animation, _, child) {
              return SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 1),
                  end: Offset.zero,
                ).animate(CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutCubic,
                )),
                child: child,
              );
            },
          );
        },
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/demande/:id',
        pageBuilder: (ctx, state) {
          final demande = state.extra as DemandeSang?;
          return CustomTransitionPage(
            child: demande != null
                ? DetailDemandeScreen(demande: demande)
                : const _NotFoundPage(),
            transitionsBuilder: (ctx, animation, _, child) {
              return SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(1, 0),
                  end: Offset.zero,
                ).animate(CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutCubic,
                )),
                child: child,
              );
            },
          );
        },
      ),
    ],
  );
}

// =====================================================================
// SHELL — Wrapper avec BottomNavigationBar
// =====================================================================
class MainShell extends StatelessWidget {
  final Widget child;

  const MainShell({super.key, required this.child});

  static const List<_NavItem> _items = [
    _NavItem(path: '/home', icon: Icons.home_outlined, activeIcon: Icons.home, label: 'Accueil'),
    _NavItem(path: '/demandes', icon: Icons.list_alt_outlined, activeIcon: Icons.list_alt, label: 'Demandes'),
    _NavItem(path: '/alertes', icon: Icons.notifications_outlined, activeIcon: Icons.notifications, label: 'Alertes'),
    _NavItem(path: '/profil', icon: Icons.person_outline, activeIcon: Icons.person, label: 'Profil'),
  ];

  int _selectedIndex(BuildContext context) {
    final location = GoRouterState.of(context).matchedLocation;
    final idx = _items.indexWhere((item) => location.startsWith(item.path));
    return idx >= 0 ? idx : 0;
  }

  @override
  Widget build(BuildContext context) {
    final selectedIdx = _selectedIndex(context);
    final state = context.watch<AppState>();

    return Scaffold(
      backgroundColor: SauveColors.creme,
      body: child,
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: SauveColors.carte,
          border: Border(top: BorderSide(color: SauveColors.grisClair)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 60,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: List.generate(
                _items.length,
                (i) => _buildNavItem(
                  context,
                  item: _items[i],
                  isSelected: i == selectedIdx,
                  badge: i == 2 ? state.notifNonLues : 0,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(
    BuildContext context, {
    required _NavItem item,
    required bool isSelected,
    int badge = 0,
  }) {
    return Expanded(
      child: InkWell(
        onTap: () => context.go(item.path),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  isSelected ? item.activeIcon : item.icon,
                  size: 22,
                  color: isSelected ? SauveColors.rouge : SauveColors.gris,
                ),
                if (badge > 0)
                  Positioned(
                    top: -6,
                    right: -8,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(
                        color: SauveColors.rouge,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '$badge',
                        style: GoogleFonts.archivo(
                          fontSize: 8,
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              item.label,
              style: GoogleFonts.inter(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: isSelected ? SauveColors.rouge : SauveColors.gris,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem {
  final String path;
  final IconData icon;
  final IconData activeIcon;
  final String label;

  const _NavItem({
    required this.path,
    required this.icon,
    required this.activeIcon,
    required this.label,
  });
}

class _NotFoundPage extends StatelessWidget {
  const _NotFoundPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SauveColors.creme,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 52, color: SauveColors.gris),
            const SizedBox(height: 12),
            Text(
              'Demande introuvable',
              style: GoogleFonts.archivo(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: SauveColors.encre,
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => context.go('/home'),
              child: const Text('Retour à l\'accueil'),
            ),
          ],
        ),
      ),
    );
  }
}
