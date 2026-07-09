import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/sauve_theme.dart';
import '../services/supabase_service.dart';

// =====================================================================
// ÉCRAN — Paramètres et Liens utiles
// D9 — Mission D : liens_externes depuis Supabase + url_launcher
// =====================================================================
class ParametresScreen extends StatefulWidget {
  const ParametresScreen({super.key});

  @override
  State<ParametresScreen> createState() => _ParametresScreenState();
}

class _ParametresScreenState extends State<ParametresScreen> {
  List<LienExterne> _liens = [];
  bool _chargement = true;
  String? _erreur;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _chargerLiens());
  }

  Future<void> _chargerLiens() async {
    setState(() {
      _chargement = true;
      _erreur = null;
    });
    try {
      final liens = await SupabaseService.lireLiensExternes();
      if (mounted) {
        setState(() {
          _liens = liens;
          _chargement = false;
        });
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[ParametresScreen] erreur chargement: $e');
      if (mounted) {
        setState(() {
          _erreur = 'Impossible de charger les liens.';
          _chargement = false;
        });
      }
    }
  }

  Future<void> _ouvrirUrl(String url) async {
    final uri = Uri.parse(url);
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Impossible d\'ouvrir ce lien.',
                style: GoogleFonts.inter(fontSize: 14),
              ),
              backgroundColor: SauveColors.rouge,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[ParametresScreen] ouvrirUrl error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Lien non valide : $url',
              style: GoogleFonts.inter(fontSize: 13),
            ),
            backgroundColor: SauveColors.gris,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  IconData _iconeDepuisCle(String? icone) {
    switch (icone) {
      case 'privacy_tip_outlined':
        return Icons.privacy_tip_outlined;
      case 'gavel':
        return Icons.gavel;
      case 'language':
        return Icons.language;
      case 'help_outline':
        return Icons.help_outline;
      case 'info_outline':
        return Icons.info_outline;
      case 'shield':
        return Icons.shield_outlined;
      case 'description':
        return Icons.description_outlined;
      case 'policy':
        return Icons.policy_outlined;
      default:
        return Icons.link;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SauveColors.creme,
      body: SafeArea(
        child: Column(
          children: [
            // ── En-tête ─────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
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
                          size: 18, color: SauveColors.encre),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Paramètres',
                    style: GoogleFonts.archivo(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: SauveColors.encre,
                    ),
                  ),
                ],
              ),
            ),

            // ── Corps ────────────────────────────────────────────────
            Expanded(
              child: _chargement
                  ? const Center(
                      child: CircularProgressIndicator(
                          color: SauveColors.rouge),
                    )
                  : _erreur != null
                      ? _buildErreur()
                      : _buildContenu(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContenu() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 40),
      children: [
        // ── Section : À propos de l'application ─────────────────────
        _buildSectionTitre('À propos de l\'application'),
        const SizedBox(height: 10),
        _buildInfoApp(),
        const SizedBox(height: 24),

        // ── Section : Liens utiles (dynamiques depuis DB) ─────────────
        if (_liens.isNotEmpty) ...[
          _buildSectionTitre('Liens utiles'),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: SauveColors.carte,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: SauveColors.grisClair),
            ),
            child: Column(
              children: List.generate(_liens.length, (i) {
                final lien = _liens[i];
                final isLast = i == _liens.length - 1;
                return Column(
                  children: [
                    _buildLienItem(lien),
                    if (!isLast)
                      const Divider(
                        height: 1,
                        indent: 54,
                        endIndent: 0,
                        color: SauveColors.grisClair,
                      ),
                  ],
                );
              }),
            ),
          ),
          const SizedBox(height: 24),
        ],

        // ── Section : Version & crédits ──────────────────────────────
        Center(
          child: Column(
            children: [
              Image.asset(
                'assets/images/logo_songre.png',
                height: 40,
              ),
              const SizedBox(height: 8),
              Text(
                'SONGRE v1.0.0',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: SauveColors.gris,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Don de sang anonyme — Burkina Faso',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: SauveColors.gris,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSectionTitre(String titre) {
    return Text(
      titre,
      style: GoogleFonts.archivo(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: SauveColors.gris,
        letterSpacing: 0.5,
      ),
    );
  }

  Widget _buildInfoApp() {
    final items = [
      (icone: Icons.bloodtype_outlined, label: 'Application', valeur: 'SONGRE'),
      (icone: Icons.tag, label: 'Version', valeur: '1.0.0'),
      (icone: Icons.location_on_outlined, label: 'Pays', valeur: 'Burkina Faso'),
      (
        icone: Icons.security_outlined,
        label: 'Données',
        valeur: 'Anonymisées et sécurisées'
      ),
    ];

    return Container(
      decoration: BoxDecoration(
        color: SauveColors.carte,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: SauveColors.grisClair),
      ),
      child: Column(
        children: List.generate(items.length, (i) {
          final item = items[i];
          final isLast = i == items.length - 1;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 13),
                child: Row(
                  children: [
                    Icon(item.icone,
                        size: 18, color: SauveColors.gris),
                    const SizedBox(width: 12),
                    Text(
                      item.label,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        color: SauveColors.gris,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      item.valeur,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: SauveColors.encre,
                      ),
                    ),
                  ],
                ),
              ),
              if (!isLast)
                const Divider(
                  height: 1,
                  indent: 46,
                  color: SauveColors.grisClair,
                ),
            ],
          );
        }),
      ),
    );
  }

  Widget _buildLienItem(LienExterne lien) {
    return InkWell(
      onTap: () => _ouvrirUrl(lien.url),
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: SauveColors.rouge.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                _iconeDepuisCle(lien.icone),
                size: 18,
                color: SauveColors.rouge,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                lien.libelle,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: SauveColors.encre,
                ),
              ),
            ),
            const Icon(Icons.open_in_new,
                size: 16, color: SauveColors.gris),
          ],
        ),
      ),
    );
  }

  Widget _buildErreur() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off_outlined,
                size: 48, color: SauveColors.grisClair),
            const SizedBox(height: 16),
            Text(
              _erreur!,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 14,
                color: SauveColors.gris,
              ),
            ),
            const SizedBox(height: 20),
            OutlinedButton(
              onPressed: _chargerLiens,
              style: OutlinedButton.styleFrom(
                foregroundColor: SauveColors.rouge,
                side: const BorderSide(color: SauveColors.rouge),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: Text('Réessayer',
                  style: GoogleFonts.archivo(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }
}
