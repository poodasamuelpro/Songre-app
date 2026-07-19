import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter/foundation.dart';
import '../utils/secure_storage_service.dart';

// =====================================================================
// WIDGET — Bannière d'état sécurité Web
//
// Affichée sur kIsWeb lors de l'authentification.
//
// Comportement selon la configuration :
//   - BFF actif (BFF_URL défini + kIsWeb) : bannière VERTE — sécurisé
//   - kIsWeb sans BFF : bannière ORANGE — mode dégradé (démonstration)
//
// Le mode dégradé ne stocke plus les tokens en localStorage (supprimé
// dans secure_storage_service.dart), mais les requêtes de données
// passent encore directement par Supabase — acceptable uniquement
// pour des démos sans données médicales réelles.
// =====================================================================
class WebSecurityBanner extends StatefulWidget {
  const WebSecurityBanner({super.key});

  @override
  State<WebSecurityBanner> createState() => _WebSecurityBannerState();
}

class _WebSecurityBannerState extends State<WebSecurityBanner> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb || _dismissed) return const SizedBox.shrink();

    if (estBffActif) {
      return _buildSecureBanner();
    }

    return _buildDegradedBanner();
  }

  /// Bannière verte — BFF actif, tokens dans cookies HttpOnly ✅
  Widget _buildSecureBanner() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFD1FAE5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF34D399)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.shield_outlined,
                color: Color(0xFF059669), size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Version Web sécurisée — les identifiants sont protégés '
              'via des cookies HttpOnly (non accessibles par JavaScript). '
              'Données médicales protégées.',
              style: GoogleFonts.inter(
                fontSize: 12,
                color: const Color(0xFF065F46),
                height: 1.4,
              ),
            ),
          ),
          GestureDetector(
            onTap: () => setState(() => _dismissed = true),
            child: const Icon(Icons.close,
                size: 16, color: Color(0xFF059669)),
          ),
        ],
      ),
    );
  }

  /// Bannière orange — Web sans BFF (démo uniquement) ⚠️
  Widget _buildDegradedBanner() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3CD),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFFD966)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.warning_amber_rounded,
                color: Color(0xFFB45309), size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Version Web — démonstration uniquement. '
              'Utilisez l\'application mobile pour des données médicales réelles. '
              'Pour activer la version Web sécurisée, configurez le BFF.',
              style: GoogleFonts.inter(
                fontSize: 12,
                color: const Color(0xFF92400E),
                height: 1.4,
              ),
            ),
          ),
          GestureDetector(
            onTap: () => setState(() => _dismissed = true),
            child: const Icon(Icons.close,
                size: 16, color: Color(0xFFB45309)),
          ),
        ],
      ),
    );
  }
}
