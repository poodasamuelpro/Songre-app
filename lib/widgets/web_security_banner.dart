import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter/foundation.dart';

// =====================================================================
// WIDGET — Bannière d'avertissement sécurité Web
//
// Affichée sur kIsWeb quand l'utilisateur tente de s'authentifier.
// Rappelle que les tokens JWT sont stockés dans localStorage sur Web
// (limitation sécurité identifiée — SEC-02 — à ne pas déployer en prod).
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
              'L\'authentification sur navigateur utilise un stockage non sécurisé. '
              'Utilisez l\'application mobile pour des données médicales réelles.',
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
