import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../theme/sauve_theme.dart';
import '../services/app_state.dart';
import '../widgets/demande_card.dart';

// =====================================================================
// ÉCRAN 2 — Accueil
// =====================================================================
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final profil = state.profil;
    final ville = profil?.ville ?? 'Ouagadougou';
    final demandes = state.demandes.where((d) => d.estActive).toList();

    return Scaffold(
      backgroundColor: SauveColors.creme,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildBrand(),
                  _buildNotifBadge(context, state),
                ],
              ),
            ),
            // Contenu scrollable
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  await state.actualiserDemandes();
                },
                color: SauveColors.rouge,
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    // Bandeau CTA urgence
                    _buildCtaUrgence(context),
                    const SizedBox(height: 4),
                    // Label section
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Demandes actives · $ville'.toUpperCase(),
                            style: GoogleFonts.archivo(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: SauveColors.gris,
                              letterSpacing: 0.06,
                            ),
                          ),
                          Text(
                            '${demandes.length}',
                            style: GoogleFonts.archivo(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: SauveColors.gris,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Liste des demandes
                    if (demandes.isEmpty)
                      _buildVide()
                    else
                      ...demandes.map(
                        (d) => DemandeCard(
                          demande: d,
                          profil: profil,
                          onTap: () => context.push('/demande/${d.id}', extra: d),
                        ),
                      ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBrand() {
    return Row(
      children: [
        Image.asset(
          'assets/images/logo_songre.png',
          height: 28,
        ),
      ],
    );
  }

  Widget _buildNotifBadge(BuildContext context, AppState state) {
    final count = state.notifNonLues;
    return GestureDetector(
      onTap: () {},
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: SauveColors.carte,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: SauveColors.grisClair),
            ),
            child: const Icon(
              Icons.notifications_outlined,
              size: 18,
              color: SauveColors.encre,
            ),
          ),
          if (count > 0)
            Positioned(
              top: -4,
              right: -4,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: const BoxDecoration(
                  color: SauveColors.rouge,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '$count',
                  style: GoogleFonts.archivo(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCtaUrgence(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
      child: Container(
        decoration: BoxDecoration(
          gradient: SauveColors.gradientUrgence,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: SauveColors.rouge.withValues(alpha: 0.3),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Stack(
          children: [
            // Cercle décoratif
            Positioned(
              right: -30,
              top: -30,
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.08),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'UNE VIE A BESOIN DE VOUS',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      letterSpacing: 0.1,
                      color: Colors.white.withValues(alpha: 0.85),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Besoin urgent de\nsang autour de vous',
                    style: GoogleFonts.archivo(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      height: 1.15,
                    ),
                  ),
                  const SizedBox(height: 14),
                  GestureDetector(
                    onTap: () => context.push('/nouvelle-demande'),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.add,
                            color: SauveColors.rougeFonce,
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Faire une demande',
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: SauveColors.rougeFonce,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVide() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
      child: Center(
        child: Column(
          children: [
            Icon(
              Icons.water_drop_outlined,
              size: 48,
              color: SauveColors.gris.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              'Aucune demande active\ndans votre ville.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 15,
                color: SauveColors.gris,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
