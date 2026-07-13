import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../theme/sauve_theme.dart';
import '../services/app_state.dart';
import '../services/supabase_service.dart';
import '../models/models.dart';
import '../utils/crypto_service.dart';

// =====================================================================
// ÉCRAN 4 — Détail d'une demande + QR code
// =====================================================================
class DetailDemandeScreen extends StatefulWidget {
  final DemandeSang demande;

  const DetailDemandeScreen({super.key, required this.demande});

  @override
  State<DetailDemandeScreen> createState() => _DetailDemandeScreenState();
}

class _DetailDemandeScreenState extends State<DetailDemandeScreen> {
  bool _showQr = false;
  String? _qrData;
  // [1.5] _repondu est chargé depuis la vue demandes_sang_avec_contact
  // (champ a_repondu) à l'ouverture de l'écran. Jamais déduit côté client seul.
  bool _repondu = false;
  bool _contactLoading = true;

  // [P2] Contacts téléphone des donneurs ayant répondu — visible uniquement
  // par l'auteur de la demande, après réponse confirmée (chargé en asynchrone).
  List<Map<String, String?>> _contactsDonneurs = [];
  bool _contactsDonneursLoading = false;

  @override
  void initState() {
    super.initState();
    // Charger l'état "a_repondu" depuis la vue serveur
    WidgetsBinding.instance.addPostFrameCallback((_) => _chargerEtatRepondu());
  }

  /// [1.5] Interroge la vue demandes_sang_avec_contact pour savoir si
  /// l'utilisateur courant a déjà répondu. Seul le serveur fait foi.
  Future<void> _chargerEtatRepondu() async {
    final state = context.read<AppState>();
    final aRepondu = await SupabaseService.verifierReponduDemande(
      widget.demande.id,
    );
    if (!mounted) return;
    setState(() {
      _repondu = aRepondu;
      _contactLoading = false;
    });

    // [P2] Si l'utilisateur est l'auteur de la demande, charger les contacts donneurs.
    if (state.userId == widget.demande.auteurId) {
      _chargerContactsDonneurs();
    }
  }

  /// [P2] Charge les téléphones chiffrés des donneurs ayant répondu,
  /// puis les déchiffre. Accessible uniquement à l'auteur de la demande.
  Future<void> _chargerContactsDonneurs() async {
    setState(() => _contactsDonneursLoading = true);
    final contacts = await SupabaseService.lireContactsDonneurs(
      widget.demande.id,
    );
    if (!mounted) return;
    setState(() {
      _contactsDonneurs = contacts;
      _contactsDonneursLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final demande = widget.demande;

    return Scaffold(
      backgroundColor: SauveColors.creme,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Row(
                children: [
                  _buildBackBtn(context),
                  Expanded(
                    child: Center(
                      child: Text(
                        'Demande',
                        style: GoogleFonts.archivo(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: SauveColors.encre,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 36),
                ],
              ),
            ),
            // Contenu scrollable
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    // Hero avec groupe sanguin
                    _buildHero(demande),
                    const SizedBox(height: 18),

                    // Infos supplémentaires
                    _buildInfos(demande),
                    const SizedBox(height: 18),

                    // Boutons d'action
                    _buildActionRow(demande),
                    const SizedBox(height: 20),

                    // Zone QR
                    _buildQrBox(demande),
                    const SizedBox(height: 30),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBackBtn(BuildContext context) {
    return GestureDetector(
      onTap: () => context.pop(),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: SauveColors.carte,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: SauveColors.grisClair),
        ),
        child: const Icon(Icons.arrow_back, size: 18, color: SauveColors.encre),
      ),
    );
  }

  Widget _buildHero(DemandeSang demande) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: SauveColors.encre,
          borderRadius: BorderRadius.circular(18),
        ),
        padding: const EdgeInsets.all(22),
        child: Column(
          children: [
            // Badge groupe sanguin grand format
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: SauveColors.rouge.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  demande.groupeSanguinRecherche.label,
                  style: GoogleFonts.archivo(
                    fontSize: 32,
                    fontWeight: FontWeight.w900,
                    color: const Color(0xFFFF6B7F),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              demande.structureNom,
              style: GoogleFonts.archivo(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              demande.villeNom,
              style: GoogleFonts.inter(
                fontSize: 12.5,
                color: const Color(0xFFc9bdba),
              ),
            ),
            const SizedBox(height: 8),
            // Chip statut
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: Color(0xFF4ade80),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Demande active · ${demande.tempsEcoule}',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: Colors.white.withValues(alpha: 0.8),
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

  Widget _buildInfos(DemandeSang demande) {
    final state = context.watch<AppState>();
    final estAuteur = state.userId == demande.auteurId;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          _buildInfoRow(
            icon: Icons.access_time_outlined,
            label: 'Publiée',
            value: demande.tempsEcoule,
          ),
          const SizedBox(height: 8),
          _buildInfoRow(
            icon: Icons.hourglass_bottom_outlined,
            label: 'Expire dans',
            value: _expirationLabel(demande.expiresAt),
          ),
          const SizedBox(height: 8),
          // [1.5] Contact DEMANDEUR masqué tant que _repondu == false (vue donneur)
          if (!estAuteur) ...[
            if (_contactLoading)
              _buildContactLoadingRow()
            else if (_repondu && demande.contactChiffre != null) ...[
              _buildInfoRow(
                icon: Icons.phone_outlined,
                label: 'Contact principal',
                value: CryptoService.dechiffrer(demande.contactChiffre) ??
                    'Contact indisponible',
              ),
              if (demande.contactSecondaireChiffre != null) ...[
                const SizedBox(height: 8),
                _buildInfoRow(
                  icon: Icons.phone_callback_outlined,
                  label: 'Contact secondaire',
                  value: CryptoService.dechiffrer(
                          demande.contactSecondaireChiffre) ??
                      'Contact indisponible',
                ),
              ],
            ] else
              _buildContactVerrouille(),
          ],
          // [P2] Contacts DONNEURS — visibles uniquement par l'auteur de la demande
          if (estAuteur) ...[
            if (_contactsDonneursLoading)
              _buildContactLoadingRow()
            else if (_contactsDonneurs.isEmpty)
              _buildAucunDonneurRow()
            else
              ..._buildContactsDonneursRows(),
          ],
        ],
      ),
    );
  }

  /// [P2] Ligne affichée quand aucun donneur n'a encore répondu
  Widget _buildAucunDonneurRow() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: SauveColors.carte,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SauveColors.grisClair),
      ),
      child: Row(
        children: [
          const Icon(Icons.people_outline, size: 18, color: SauveColors.gris),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Aucun donneur n\'a encore répondu à cette demande.',
              style: GoogleFonts.inter(fontSize: 13, color: SauveColors.gris),
            ),
          ),
        ],
      ),
    );
  }

  /// [P2] Génère les lignes d'affichage des contacts donneurs
  List<Widget> _buildContactsDonneursRows() {
    final widgets = <Widget>[];
    for (int i = 0; i < _contactsDonneurs.length; i++) {
      if (i > 0) widgets.add(const SizedBox(height: 8));
      final contact = _contactsDonneurs[i];
      final tel = contact['telephone'];
      widgets.add(
        _buildInfoRow(
          icon: Icons.volunteer_activism_outlined,
          label: 'Donneur ${i + 1}',
          value: tel != null && tel.isNotEmpty ? tel : 'Contact non renseigné',
        ),
      );
    }
    return widgets;
  }

  /// Placeholder pendant le chargement de l'état répondu
  Widget _buildContactLoadingRow() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: SauveColors.carte,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SauveColors.grisClair),
      ),
      child: Row(
        children: [
          const Icon(Icons.lock_outline, size: 18, color: SauveColors.gris),
          const SizedBox(width: 10),
          Text(
            'Contact',
            style: GoogleFonts.inter(fontSize: 13, color: SauveColors.gris),
          ),
          const Spacer(),
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: SauveColors.gris,
            ),
          ),
        ],
      ),
    );
  }

  /// [1.5] Affiché quand _repondu == false : invite le donneur à répondre
  /// avant de voir le contact. Aucune information de contact n'est exposée.
  Widget _buildContactVerrouille() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: SauveColors.rouge.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: SauveColors.rouge.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.lock_outline,
            size: 18,
            color: SauveColors.rouge.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Appuyez sur « Je réponds » pour accéder au contact',
              style: GoogleFonts.inter(
                fontSize: 12.5,
                color: SauveColors.rouge.withValues(alpha: 0.8),
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: SauveColors.carte,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SauveColors.grisClair),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: SauveColors.gris),
          const SizedBox(width: 10),
          Text(
            label,
            style: GoogleFonts.inter(fontSize: 13, color: SauveColors.gris),
          ),
          const Spacer(),
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: SauveColors.encre,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionRow(DemandeSang demande) {
    final state = context.watch<AppState>();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          Row(
            children: [
              // Bouton "Je réponds" (donneur)
              Expanded(
                child: OutlinedButton(
                  onPressed: _repondu ? null : () { _repondre(); },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _repondu ? SauveColors.vert : SauveColors.rouge,
                    side: BorderSide(
                      color: _repondu ? SauveColors.vert : SauveColors.rouge,
                      width: 1.5,
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    _repondu ? 'Répondu ✓' : 'Je réponds',
                    style: GoogleFonts.archivo(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // Bouton "Générer mon code" (donneur)
              Expanded(
                child: ElevatedButton(
                  onPressed: () => _genererQr(demande),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: SauveColors.rouge,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    'Générer mon code',
                    style: GoogleFonts.archivo(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Bouton "Scanner un code" (demandeur)
          if (state.userId != null)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () =>
                    context.push('/scan-qr', extra: state.userId),
                icon: const Icon(Icons.qr_code_scanner, size: 18),
                label: Text(
                  'Scanner le code du donneur',
                  style: GoogleFonts.archivo(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: SauveColors.encre,
                  side: const BorderSide(color: SauveColors.grisClair, width: 1.5),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildQrBox(DemandeSang demande) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: SauveColors.carte,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: SauveColors.grisClair,
            width: 1.5,
            style: BorderStyle.solid,
          ),
        ),
        padding: const EdgeInsets.all(26),
        child: Column(
          children: [
            // QR code ou placeholder
            if (_showQr && _qrData != null)
              _buildQrCode()
            else
              _buildQrPlaceholder(),
            const SizedBox(height: 14),
            Text(
              _showQr
                  ? 'Montrez ce code au demandeur'
                  : 'Générez votre code de validation',
              style: GoogleFonts.inter(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: SauveColors.encre,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _showQr
                  ? 'Valide 24h · Usage unique · Non reproductible'
                  : 'Valide 24h · Généré une fois sur place',
              style: GoogleFonts.inter(
                fontSize: 12,
                color: SauveColors.gris,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQrCode() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SauveColors.grisClair),
      ),
      padding: const EdgeInsets.all(12),
      child: QrImageView(
        data: _qrData!,
        version: QrVersions.auto,
        size: 160,
        backgroundColor: Colors.white,
        errorStateBuilder: (ctx, err) => const Icon(
          Icons.error_outline,
          color: SauveColors.rouge,
          size: 40,
        ),
      ),
    );
  }

  Widget _buildQrPlaceholder() {
    return Container(
      width: 160,
      height: 160,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SauveColors.grisClair),
      ),
      child: CustomPaint(painter: _QrPatternPainter()),
    );
  }

  Future<void> _repondre() async {
    final demande = widget.demande;
    final state = context.read<AppState>();

    // [1.5] Mise à jour optimiste — confirmée par _chargerEtatRepondu() en cas de succès
    setState(() => _repondu = true);

    final ok = await state.enregistrerReponseDonneur(demande.id);

    if (!mounted) return;

    if (ok) {
      // Recharger depuis la vue serveur pour avoir l'état canonique
      await _chargerEtatRepondu();
    } else {
      // Rollback optim si l'enregistrement a échoué
      setState(() => _repondu = false);
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Réponse enregistrée. Le contact est maintenant disponible.'
              : 'Erreur lors de l\'enregistrement. Réessayez.',
          style: GoogleFonts.inter(fontSize: 13),
        ),
        backgroundColor: ok ? SauveColors.vert : const Color(0xFFB45309),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Future<void> _genererQr(DemandeSang demande) async {
    final state = context.read<AppState>();
    final token = await state.genererQrToken(demande.id);
    if (token != null && token.isNotEmpty) {
      setState(() {
        _qrData = token;
        _showQr = true;
      });
    }
  }

  String _expirationLabel(DateTime expiresAt) {
    final diff = expiresAt.difference(DateTime.now());
    if (diff.inHours > 24) return '${diff.inDays}j ${diff.inHours % 24}h';
    if (diff.inHours > 0) return '${diff.inHours}h ${diff.inMinutes % 60}min';
    return 'Expire bientôt';
  }
}

// Peintre pour le placeholder QR (motif en damier)
class _QrPatternPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = SauveColors.encre;
    const cellSize = 16.0;
    for (var row = 0; row < (size.height / cellSize).ceil(); row++) {
      for (var col = 0; col < (size.width / cellSize).ceil(); col++) {
        if ((row + col) % 2 == 0) {
          canvas.drawRect(
            Rect.fromLTWH(
              col * cellSize,
              row * cellSize,
              cellSize,
              cellSize,
            ),
            paint,
          );
        }
      }
    }
    // Fond blanc par-dessus
    canvas.drawRect(
      Rect.fromLTWH(
        size.width * 0.2,
        size.height * 0.2,
        size.width * 0.6,
        size.height * 0.6,
      ),
      Paint()..color = Colors.white,
    );
    // Icone point d'interrogation
    final textPainter = TextPainter(
      text: TextSpan(
        text: '?',
        style: TextStyle(
          color: SauveColors.gris.withValues(alpha: 0.5),
          fontSize: 32,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(
      canvas,
      Offset(
        (size.width - textPainter.width) / 2,
        (size.height - textPainter.height) / 2,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
