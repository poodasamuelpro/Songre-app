import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/sauve_theme.dart';
import '../models/models.dart';

// =====================================================================
// WIDGET — Carte de demande de sang (réutilisable)
// =====================================================================
class DemandeCard extends StatefulWidget {
  final DemandeSang demande;
  final ProfilDonneur? profil;
  final VoidCallback? onTap;

  const DemandeCard({
    super.key,
    required this.demande,
    this.profil,
    this.onTap,
  });

  @override
  State<DemandeCard> createState() => _DemandeCardState();
}

class _DemandeCardState extends State<DemandeCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseCtrl;

  // Vérifie si la demande est compatible avec le groupe de l'utilisateur connecté
  bool get _estCompatible =>
      widget.profil != null &&
      widget.demande.estCompatibleAvec(widget.profil!);

  // Demande urgente = publiée il y a moins de 30 minutes
  bool get _estUrgente =>
      DateTime.now().difference(widget.demande.createdAt).inMinutes < 30;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    if (_estUrgente) _pulseCtrl.repeat();
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: SauveColors.carte,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _estCompatible
                ? SauveColors.rouge.withValues(alpha: 0.3)
                : SauveColors.grisClair,
            width: _estCompatible ? 1.5 : 1,
          ),
          boxShadow: _estCompatible
              ? [
                  BoxShadow(
                    color: SauveColors.rouge.withValues(alpha: 0.06),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  )
                ]
              : null,
        ),
        child: Row(
          children: [
            // Badge groupe sanguin
            _buildGroupeBadge(),
            const SizedBox(width: 14),
            // Info demande
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.demande.structureSanitaire,
                    style: GoogleFonts.inter(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: SauveColors.encre,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${widget.demande.tempsEcoule} · ${widget.demande.ville}',
                    style: GoogleFonts.inter(
                      fontSize: 12.5,
                      color: SauveColors.gris,
                    ),
                  ),
                ],
              ),
            ),
            // Badge compatible
            if (_estCompatible) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: SauveColors.encre,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'Compatible',
                  style: GoogleFonts.inter(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildGroupeBadge() {
    return Stack(
      alignment: Alignment.center,
      children: [
        // Anneau de pulse pour les urgentes
        if (_estUrgente)
          AnimatedBuilder(
            animation: _pulseCtrl,
            builder: (_, __) {
              final scale = 0.9 + (_pulseCtrl.value * 0.45);
              final opacity = (1 - _pulseCtrl.value).clamp(0.0, 1.0);
              return Transform.scale(
                scale: scale,
                child: Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(
                      color: SauveColors.rouge.withValues(alpha: opacity),
                      width: 2,
                    ),
                  ),
                ),
              );
            },
          ),
        // Badge central
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: _estUrgente ? const Color(0xFFFCE4E4) : SauveColors.vertFond,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Center(
            child: Text(
              widget.demande.groupeSanguinRecherche.label,
              style: GoogleFonts.archivo(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: _estUrgente ? SauveColors.rouge : SauveColors.vert,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
