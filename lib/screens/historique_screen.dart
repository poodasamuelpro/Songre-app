import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../theme/sauve_theme.dart';
import '../services/app_state.dart';
import '../services/supabase_service.dart';

// =====================================================================
// ÉCRAN — Historique du donneur (S5)
// Affiche dons effectués + demandes publiées, combinés et triés par date.
// Pagination : 25 éléments par page, chargement supplémentaire au scroll.
// =====================================================================

/// Un événement unifié dans le fil historique.
/// Encapsule soit un [HistoriqueDon], soit une [HistoriqueDemande].
class _HistoriqueEvent {
  final DateTime date;
  final HistoriqueDon? don;
  final HistoriqueDemande? demande;

  _HistoriqueEvent.don(HistoriqueDon d)
      : don = d,
        demande = null,
        date = d.dateDon;

  _HistoriqueEvent.demande(HistoriqueDemande dem)
      : demande = dem,
        don = null,
        date = dem.createdAt;
}

class HistoriqueScreen extends StatefulWidget {
  const HistoriqueScreen({super.key});

  @override
  State<HistoriqueScreen> createState() => _HistoriqueScreenState();
}

class _HistoriqueScreenState extends State<HistoriqueScreen> {
  static const int _pageSize = 25;

  final ScrollController _scrollCtrl = ScrollController();
  final List<_HistoriqueEvent> _events = [];

  int _page = 0;
  bool _isLoading = false;
  bool _isFirstLoad = true;
  bool _aUnePageSuivante = true;
  String? _erreur;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _chargerPage());
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollCtrl.position.pixels >=
        _scrollCtrl.position.maxScrollExtent - 200) {
      if (!_isLoading && _aUnePageSuivante) {
        _chargerPage();
      }
    }
  }

  Future<void> _chargerPage() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _erreur = null;
    });

    try {
      final userId = context.read<AppState>().userId;
      if (userId == null) {
        setState(() {
          _erreur = 'Session invalide. Veuillez vous reconnecter.';
          _isLoading = false;
          _isFirstLoad = false;
        });
        return;
      }

      final result = await SupabaseService.lireHistoriqueUtilisateur(
        userId: userId,
        page: _page,
        pageSize: _pageSize,
      );

      // Combiner dons + demandes en une liste unifiée, triée par date DESC.
      final List<_HistoriqueEvent> nouveaux = [
        ...result.dons.map(_HistoriqueEvent.don),
        ...result.demandes.map(_HistoriqueEvent.demande),
      ];
      nouveaux.sort((a, b) => b.date.compareTo(a.date));

      if (mounted) {
        setState(() {
          _events.addAll(nouveaux);
          _aUnePageSuivante = result.aUnePageSuivante;
          _page++;
          _isLoading = false;
          _isFirstLoad = false;
        });
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[HistoriqueScreen] _chargerPage error: $e');
      if (mounted) {
        setState(() {
          _erreur = 'Erreur de chargement. Vérifiez votre connexion.';
          _isLoading = false;
          _isFirstLoad = false;
        });
      }
    }
  }

  Future<void> _rafraichir() async {
    setState(() {
      _events.clear();
      _page = 0;
      _aUnePageSuivante = true;
      _isFirstLoad = true;
      _erreur = null;
    });
    await _chargerPage();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SauveColors.creme,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(child: _buildContenu()),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: SauveColors.carte,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: SauveColors.grisClair),
              ),
              child: const Icon(Icons.arrow_back,
                  color: SauveColors.encre, size: 18),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              'Mon historique',
              style: GoogleFonts.archivo(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: SauveColors.encre,
              ),
            ),
          ),
          GestureDetector(
            onTap: _rafraichir,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: SauveColors.carte,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: SauveColors.grisClair),
              ),
              child: const Icon(Icons.refresh,
                  color: SauveColors.encre, size: 18),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContenu() {
    // Premier chargement : spinner centré
    if (_isFirstLoad && _isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: SauveColors.rouge),
      );
    }

    // Erreur lors du premier chargement
    if (_erreur != null && _events.isEmpty) {
      return _buildEtatVide(
        icon: Icons.error_outline,
        couleur: SauveColors.rouge,
        titre: 'Erreur de chargement',
        sousTitre: _erreur!,
        boutonLabel: 'Réessayer',
        onBouton: _rafraichir,
      );
    }

    // Aucun événement
    if (!_isLoading && _events.isEmpty) {
      return _buildEtatVide(
        icon: Icons.history_outlined,
        couleur: SauveColors.gris,
        titre: 'Aucun historique',
        sousTitre:
            'Vos dons effectués et demandes publiées apparaîtront ici.',
        boutonLabel: null,
        onBouton: null,
      );
    }

    return RefreshIndicator(
      color: SauveColors.rouge,
      onRefresh: _rafraichir,
      child: ListView.builder(
        controller: _scrollCtrl,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        itemCount: _events.length + (_isLoading ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == _events.length) {
            // Indicateur de chargement en bas de liste (pagination)
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: CircularProgressIndicator(color: SauveColors.rouge),
              ),
            );
          }
          final event = _events[index];
          final bool afficherSeparateur = index == 0 ||
              !_memeMois(_events[index - 1].date, event.date);

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (afficherSeparateur) _buildSeparateurMois(event.date),
              if (event.don != null)
                _buildCarteDon(event.don!)
              else
                _buildCarteDemande(event.demande!),
            ],
          );
        },
      ),
    );
  }

  bool _memeMois(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month;

  Widget _buildSeparateurMois(DateTime date) {
    final label = DateFormat('MMMM yyyy', 'fr_FR').format(date);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
      child: Text(
        label[0].toUpperCase() + label.substring(1),
        style: GoogleFonts.archivo(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: SauveColors.gris,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  Widget _buildCarteDon(HistoriqueDon don) {
    final dateStr =
        DateFormat('d MMM yyyy', 'fr_FR').format(don.dateDon);
    final icone =
        don.estQrValide ? Icons.qr_code_scanner : Icons.volunteer_activism;
    final couleurType =
        don.estQrValide ? const Color(0xFF059669) : SauveColors.rouge;
    final typeLabel =
        don.estQrValide ? 'Don validé par QR' : 'Don déclaratif';

    return _buildCarteBase(
      icone: icone,
      couleurIcone: couleurType,
      fondIcone: couleurType.withValues(alpha: 0.1),
      titre: typeLabel,
      date: dateStr,
      badge: null,
      badgeCouleur: null,
    );
  }

  Widget _buildCarteDemande(HistoriqueDemande demande) {
    final dateStr =
        DateFormat('d MMM yyyy', 'fr_FR').format(demande.createdAt);
    final ville = demande.villeNom?.isNotEmpty == true
        ? ' · ${demande.villeNom}'
        : '';
    final titre =
        'Demande ${demande.groupeSanguinRecherche}$ville';
    final badge = demande.statutLabel;
    final Color badgeCouleur;
    switch (demande.statut) {
      case 'satisfaite':
        badgeCouleur = const Color(0xFF2563EB);
        break;
      case 'active':
        badgeCouleur = demande.estActive
            ? const Color(0xFF059669)
            : const Color(0xFF9CA3AF);
        break;
      default:
        badgeCouleur = const Color(0xFF9CA3AF);
    }

    return _buildCarteBase(
      icone: Icons.bloodtype_outlined,
      couleurIcone: SauveColors.rouge,
      fondIcone: SauveColors.rouge.withValues(alpha: 0.1),
      titre: titre,
      date: dateStr,
      badge: badge,
      badgeCouleur: badgeCouleur,
    );
  }

  Widget _buildCarteBase({
    required IconData icone,
    required Color couleurIcone,
    required Color fondIcone,
    required String titre,
    required String date,
    required String? badge,
    required Color? badgeCouleur,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: SauveColors.carte,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: SauveColors.grisClair),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: fondIcone,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icone, color: couleurIcone, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  titre,
                  style: GoogleFonts.archivo(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: SauveColors.encre,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Text(
                  date,
                  style: GoogleFonts.inter(
                    fontSize: 12.5,
                    color: SauveColors.gris,
                  ),
                ),
              ],
            ),
          ),
          if (badge != null && badgeCouleur != null) ...[
            const SizedBox(width: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: badgeCouleur.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                badge,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: badgeCouleur,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEtatVide({
    required IconData icon,
    required Color couleur,
    required String titre,
    required String sousTitre,
    required String? boutonLabel,
    required VoidCallback? onBouton,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 56, color: couleur.withValues(alpha: 0.5)),
            const SizedBox(height: 20),
            Text(
              titre,
              textAlign: TextAlign.center,
              style: GoogleFonts.archivo(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: SauveColors.encre,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              sousTitre,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 14,
                color: SauveColors.gris,
                height: 1.5,
              ),
            ),
            if (boutonLabel != null && onBouton != null) ...[
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: onBouton,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(boutonLabel,
                    style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: SauveColors.rouge,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 12),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
