import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../theme/sauve_theme.dart';
import '../services/app_state.dart';
import '../models/models.dart';
import '../widgets/demande_card.dart';

// =====================================================================
// ÉCRAN — Liste complète des demandes TOUTES VILLES (onglet "Demandes")
// Distinct de l'accueil qui filtre par la ville du profil utilisateur.
// =====================================================================
class DemandesScreen extends StatefulWidget {
  const DemandesScreen({super.key});

  @override
  State<DemandesScreen> createState() => _DemandesScreenState();
}

class _DemandesScreenState extends State<DemandesScreen> {
  GroupeSanguin? _filtreGroupe;

  @override
  void initState() {
    super.initState();
    // Charger toutes les demandes dès l'ouverture de l'onglet.
    // addPostFrameCallback garantit que le contexte Provider est disponible.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<AppState>().actualiserToutesLesDemandes();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final profil = state.profil;
    // [P6] Utiliser toutesLesDemandes (toutes villes) au lieu de demandes (filtrée par ville)
    var demandes = state.toutesLesDemandes.where((d) => d.estActive).toList();

    // Filtre optionnel par groupe sanguin (choix utilisateur dans l'UI)
    if (_filtreGroupe != null) {
      demandes = demandes
          .where((d) => d.groupeSanguinRecherche == _filtreGroupe)
          .toList();
    }

    return Scaffold(
      backgroundColor: SauveColors.creme,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Demandes',
                    style: GoogleFonts.archivo(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      color: SauveColors.encre,
                    ),
                  ),
                  // Bouton créer
                  GestureDetector(
                    onTap: () => context.push('/nouvelle-demande'),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: SauveColors.rouge,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.add, size: 16, color: Colors.white),
                          const SizedBox(width: 4),
                          Text(
                            'Créer',
                            style: GoogleFonts.archivo(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Filtre par groupe
            _buildFiltreGroupe(),
            const SizedBox(height: 8),
            // Liste
            Expanded(
              child: RefreshIndicator(
                // [P6] Pull-to-refresh recharge toutes les demandes (sans filtre ville)
                onRefresh: () async =>
                    state.actualiserToutesLesDemandes(),
                color: SauveColors.rouge,
                child: demandes.isEmpty
                    ? _buildVide()
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 20),
                        itemCount: demandes.length,
                        itemBuilder: (ctx, i) => DemandeCard(
                          demande: demandes[i],
                          profil: profil,
                          onTap: () => context.push(
                            '/demande/${demandes[i].id}',
                            extra: demandes[i],
                          ),
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFiltreGroupe() {
    return SizedBox(
      height: 38,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        children: [
          // "Tous"
          _buildFiltreChip(null, 'Tous'),
          const SizedBox(width: 8),
          ...GroupeSanguin.values.map(
            (g) => Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _buildFiltreChip(g, g.label),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFiltreChip(GroupeSanguin? g, String label) {
    final selected = _filtreGroupe == g;
    return GestureDetector(
      onTap: () => setState(() => _filtreGroupe = g),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? SauveColors.encre : SauveColors.carte,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? SauveColors.encre : SauveColors.grisClair,
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : SauveColors.encre,
          ),
        ),
      ),
    );
  }

  Widget _buildVide() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.search_off_outlined,
            size: 48,
            color: SauveColors.gris.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            'Aucune demande trouvée',
            style: GoogleFonts.inter(fontSize: 15, color: SauveColors.gris),
          ),
          if (_filtreGroupe != null) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () => setState(() => _filtreGroupe = null),
              child: Text(
                'Effacer le filtre',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: SauveColors.rouge,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
