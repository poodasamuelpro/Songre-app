import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../theme/sauve_theme.dart';
import '../services/app_state.dart';
import 'breakpoints.dart';

// =====================================================================
// ResponsiveScaffold — Scaffold adaptatif SONGRE (Web uniquement)
//
// Mobile Web  (< 600px)  : BottomNavigationBar (identique mobile natif)
// Tablet Web  (600–1024) : NavigationRail latérale + contenu centré
// Desktop Web (> 1024px) : Drawer permanent + contenu sur 2 zones
//
// Sur Android/iOS : ce widget n'est PAS utilisé — les écrans natifs
// gèrent leur propre navigation via la ShellRoute GoRouter.
// =====================================================================

/// Définition d'un item de navigation SONGRE
class SongreNavItem {
  final String route;
  final IconData icon;
  final IconData iconSelected;
  final String label;

  const SongreNavItem({
    required this.route,
    required this.icon,
    required this.iconSelected,
    required this.label,
  });
}

/// Les 4 destinations principales de l'app SONGRE
const List<SongreNavItem> kSongreNavItems = [
  SongreNavItem(
    route: '/home',
    icon: Icons.home_outlined,
    iconSelected: Icons.home,
    label: 'Accueil',
  ),
  SongreNavItem(
    route: '/demandes',
    icon: Icons.favorite_outline,
    iconSelected: Icons.favorite,
    label: 'Demandes',
  ),
  SongreNavItem(
    route: '/notifications',
    icon: Icons.notifications_outlined,
    iconSelected: Icons.notifications,
    label: 'Notifs',
  ),
  SongreNavItem(
    route: '/profil',
    icon: Icons.person_outline,
    iconSelected: Icons.person,
    label: 'Profil',
  ),
];

/// Scaffold responsive utilisé uniquement sur kIsWeb.
/// Wraps the [child] widget with platform-appropriate navigation.
class ResponsiveWebScaffold extends StatelessWidget {
  final Widget child;
  final String currentRoute;

  const ResponsiveWebScaffold({
    super.key,
    required this.child,
    required this.currentRoute,
  });

  int get _selectedIndex {
    for (int i = 0; i < kSongreNavItems.length; i++) {
      if (currentRoute.startsWith(kSongreNavItems[i].route)) return i;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) return child;

    final size = getScreenSize(context);
    return switch (size) {
      ScreenSize.mobile  => _buildMobileLayout(context),
      ScreenSize.tablet  => _buildTabletLayout(context),
      ScreenSize.desktop => _buildDesktopLayout(context),
    };
  }

  // ── Mobile Web (< 600px) ─── BottomNavigationBar ──────────────────────────

  Widget _buildMobileLayout(BuildContext context) {
    return Scaffold(
      backgroundColor: SauveColors.creme,
      body: child,
      bottomNavigationBar: _buildBottomNav(context),
    );
  }

  Widget _buildBottomNav(BuildContext context) {
    final selected = _selectedIndex;
    return BottomNavigationBar(
      currentIndex: selected,
      type: BottomNavigationBarType.fixed,
      backgroundColor: SauveColors.carte,
      selectedItemColor: SauveColors.rouge,
      unselectedItemColor: SauveColors.gris,
      selectedLabelStyle: GoogleFonts.inter(
        fontSize: 10,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelStyle: GoogleFonts.inter(fontSize: 10),
      onTap: (i) => context.go(kSongreNavItems[i].route),
      items: kSongreNavItems.map((item) {
        final isSelected = kSongreNavItems.indexOf(item) == selected;
        return BottomNavigationBarItem(
          icon: Icon(isSelected ? item.iconSelected : item.icon),
          label: item.label,
        );
      }).toList(),
    );
  }

  // ── Tablet Web (600–1024px) ── NavigationRail ─────────────────────────────

  Widget _buildTabletLayout(BuildContext context) {
    final selected = _selectedIndex;
    return Scaffold(
      backgroundColor: SauveColors.creme,
      body: Row(
        children: [
          // Rail de navigation
          Container(
            width: 80,
            decoration: const BoxDecoration(
              color: SauveColors.carte,
              border: Border(
                right: BorderSide(color: SauveColors.grisClair, width: 1),
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  const SizedBox(height: 16),
                  // Logo compact
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: SauveColors.rouge,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(
                      child: Text(
                        'S',
                        style: GoogleFonts.archivo(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  ...kSongreNavItems.asMap().entries.map((entry) {
                    final i = entry.key;
                    final item = entry.value;
                    final isSelected = i == selected;
                    return _buildRailItem(context, item, i, isSelected);
                  }),
                ],
              ),
            ),
          ),
          // Contenu principal
          Expanded(
            child: ClipRect(child: child),
          ),
        ],
      ),
    );
  }

  Widget _buildRailItem(
    BuildContext context,
    SongreNavItem item,
    int index,
    bool isSelected,
  ) {
    return GestureDetector(
      onTap: () => context.go(item.route),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 64,
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? SauveColors.rouge.withValues(alpha: 0.1)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isSelected ? item.iconSelected : item.icon,
              color: isSelected ? SauveColors.rouge : SauveColors.gris,
              size: 22,
            ),
            const SizedBox(height: 4),
            Text(
              item.label,
              style: GoogleFonts.inter(
                fontSize: 9,
                color: isSelected ? SauveColors.rouge : SauveColors.gris,
                fontWeight:
                    isSelected ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Desktop Web (> 1024px) ── Drawer permanent + header ───────────────────

  Widget _buildDesktopLayout(BuildContext context) {
    final selected = _selectedIndex;
    return Scaffold(
      backgroundColor: SauveColors.creme,
      body: Row(
        children: [
          // Sidebar permanente
          SizedBox(
            width: SongreBreakpoints.sidebarWidth,
            child: _buildDesktopSidebar(context, selected),
          ),
          // Diviseur
          const VerticalDivider(
            width: 1,
            color: SauveColors.grisClair,
          ),
          // Zone contenu principale — centrée avec largeur max
          Expanded(
            child: Column(
              children: [
                // Barre supérieure desktop
                _buildDesktopTopBar(context),
                // Contenu scrollable centré
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: SongreBreakpoints.contentMaxWidth,
                      ),
                      child: ClipRect(child: child),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopSidebar(BuildContext context, int selected) {
    return Container(
      color: SauveColors.carte,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // En-tête sidebar
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: SauveColors.rouge,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Center(
                      child: Text(
                        'S',
                        style: GoogleFonts.archivo(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'SONGRE',
                    style: GoogleFonts.archivo(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: SauveColors.encre,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
              child: Text(
                'Application de don de sang',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: SauveColors.gris,
                ),
              ),
            ),
            const Divider(color: SauveColors.grisClair, height: 1),
            const SizedBox(height: 12),
            // Items navigation
            ...kSongreNavItems.asMap().entries.map((entry) {
              final i = entry.key;
              final item = entry.value;
              final isSelected = i == selected;
              return _buildSidebarItem(context, item, isSelected);
            }),
            const Spacer(),
            const Divider(color: SauveColors.grisClair, height: 1),
            // Déconnexion
            _buildSidebarLogout(context),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildSidebarItem(
    BuildContext context,
    SongreNavItem item,
    bool isSelected,
  ) {
    return GestureDetector(
      onTap: () => context.go(item.route),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected
              ? SauveColors.rouge.withValues(alpha: 0.1)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              isSelected ? item.iconSelected : item.icon,
              color: isSelected ? SauveColors.rouge : SauveColors.gris,
              size: 20,
            ),
            const SizedBox(width: 14),
            Text(
              item.label,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight:
                    isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected ? SauveColors.rouge : SauveColors.encre,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSidebarLogout(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        if (!state.isAuthenticated) return const SizedBox.shrink();
        return GestureDetector(
          onTap: () async {
            await state.seDeconnecter();
            if (context.mounted) context.go('/');
          },
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(Icons.logout,
                    color: SauveColors.rouge, size: 20),
                const SizedBox(width: 14),
                Text(
                  'Déconnexion',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: SauveColors.rouge,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDesktopTopBar(BuildContext context) {
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 32),
      decoration: const BoxDecoration(
        color: SauveColors.carte,
        border: Border(
          bottom: BorderSide(color: SauveColors.grisClair, width: 1),
        ),
      ),
      child: Row(
        children: [
          Text(
            _labelForRoute(),
            style: GoogleFonts.archivo(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: SauveColors.encre,
            ),
          ),
          const Spacer(),
          // Badge rouge SONGRE
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: SauveColors.rouge.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'Don de sang · Burkina Faso',
              style: GoogleFonts.inter(
                fontSize: 12,
                color: SauveColors.rouge,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _labelForRoute() {
    if (currentRoute.startsWith('/home')) return 'Tableau de bord';
    if (currentRoute.startsWith('/demandes')) return 'Demandes de sang';
    if (currentRoute.startsWith('/notifications')) return 'Notifications';
    if (currentRoute.startsWith('/profil')) return 'Mon profil';
    if (currentRoute.startsWith('/carte')) return 'Carte des structures';
    return 'SONGRE';
  }
}
