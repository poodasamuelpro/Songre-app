import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../theme/sauve_theme.dart';
import '../services/app_state.dart';
import '../models/models.dart';

// =====================================================================
// ÉCRAN 6 — Notifications / Alertes
// =====================================================================
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final notifs = state.notifications;

    return Scaffold(
      backgroundColor: SauveColors.creme,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Alertes',
                    style: GoogleFonts.archivo(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      color: SauveColors.encre,
                    ),
                  ),
                  if (state.notifNonLues > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: SauveColors.rouge,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${state.notifNonLues} nouvelle${state.notifNonLues > 1 ? 's' : ''}',
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // Liste
            Expanded(
              child: notifs.isEmpty
                  ? _buildVide()
                  : ListView.builder(
                      padding: const EdgeInsets.only(top: 8),
                      itemCount: notifs.length,
                      itemBuilder: (ctx, i) => _NotifItem(notif: notifs[i]),
                    ),
            ),
          ],
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
            Icons.notifications_none_outlined,
            size: 52,
            color: SauveColors.gris.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            'Aucune notification pour l\'instant.',
            style: GoogleFonts.inter(fontSize: 15, color: SauveColors.gris),
          ),
          const SizedBox(height: 6),
          Text(
            'Vous serez alerté(e) dès qu\'une demande\ncompatible est publiée près de vous.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(fontSize: 13, color: SauveColors.gris),
          ),
        ],
      ),
    );
  }
}

class _NotifItem extends StatelessWidget {
  final NotificationSauve notif;

  const _NotifItem({required this.notif});

  Color get _dotColor {
    switch (notif.type) {
      // ── Alertes sang / urgences ─────────────────────────────────────
      case TypeNotification.demandeCompatible:
        return SauveColors.rouge;
      // ── Confirmations de don ────────────────────────────────────────
      case TypeNotification.donConfirme:
      case TypeNotification.donConfirmeDemandeur:
      case TypeNotification.donEnregistreManuel:
        return SauveColors.vert;
      // ── Réponses de donneurs ────────────────────────────────────────
      case TypeNotification.reponseRecue:
        return const Color(0xFF1565C0); // bleu marine
      case TypeNotification.reponseEncouragement:
        return const Color(0xFF0288D1); // bleu clair
      // ── Retour éligibilité ──────────────────────────────────────────
      case TypeNotification.retourEligibilite:
        return SauveColors.grisClair;
      // ── Système / compte ────────────────────────────────────────────
      case TypeNotification.suppressionDemandee:
        return const Color(0xFFE65100); // orange foncé
      case TypeNotification.bienvenue:
        return const Color(0xFF388E3C); // vert foncé
      case TypeNotification.mdpModifie:
        return const Color(0xFF6A1B9A); // violet
    }
  }

  IconData get _iconForType {
    switch (notif.type) {
      case TypeNotification.demandeCompatible:
        return Icons.water_drop_outlined;
      case TypeNotification.donConfirme:
      case TypeNotification.donConfirmeDemandeur:
      case TypeNotification.donEnregistreManuel:
        return Icons.check_circle_outline;
      case TypeNotification.reponseRecue:
        return Icons.person_add_alt_1_outlined;
      case TypeNotification.reponseEncouragement:
        return Icons.volunteer_activism_outlined;
      case TypeNotification.retourEligibilite:
        return Icons.calendar_today_outlined;
      case TypeNotification.suppressionDemandee:
        return Icons.delete_outline;
      case TypeNotification.bienvenue:
        return Icons.waving_hand_outlined;
      case TypeNotification.mdpModifie:
        return Icons.lock_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: notif.lue ? SauveColors.carte : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: notif.lue ? SauveColors.grisClair : SauveColors.rouge.withValues(alpha: 0.2),
        ),
        boxShadow: !notif.lue
            ? [
                BoxShadow(
                  color: SauveColors.rouge.withValues(alpha: 0.05),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                )
              ]
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Icône colorée (type-aware — correction R-03)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: _dotColor.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _iconForType,
                size: 17,
                color: _dotColor,
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Contenu
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  notif.message,
                  style: GoogleFonts.inter(
                    fontSize: 13.5,
                    color: SauveColors.encre,
                    height: 1.4,
                    fontWeight: notif.lue ? FontWeight.w400 : FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  notif.tempsEcoule,
                  style: GoogleFonts.inter(
                    fontSize: 11.5,
                    color: SauveColors.gris,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
