import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/sauve_theme.dart';
import '../services/supabase_service.dart';

// =====================================================================
// ÉCRAN — Modifier le mot de passe / Mot de passe oublié
// D6 — Mission D : Sécurité compte + notification mdp_modifie
// Correction S4 : l'email est passé en paramètre depuis AppState,
// évitant un appel réseau redondant à obtenirEmailCourant().
// =====================================================================
class ChangePasswordScreen extends StatefulWidget {
  /// Email de l'utilisateur connecté, passé depuis AppState.
  /// S'il est fourni, évite un appel réseau supplémentaire dans _ChangerMdpForm.
  final String? email;

  const ChangePasswordScreen({super.key, this.email});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  // 0 = choix (changer / oublié), 1 = changer mdp, 2 = mot de passe oublié
  int _mode = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SauveColors.creme,
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: switch (_mode) {
            1 => _ChangerMdpForm(
                key: const ValueKey('changer'),
                onRetour: () => setState(() => _mode = 0),
                email: widget.email, // transmis depuis AppState
              ),
            2 => _MdpOublieForm(
                key: const ValueKey('oublie'),
                onRetour: () => setState(() => _mode = 0),
              ),
            _ => _ChoixMode(
                key: const ValueKey('choix'),
                onChanger: () => setState(() => _mode = 1),
                onOublie: () => setState(() => _mode = 2),
                onRetour: () => Navigator.of(context).pop(),
              ),
          },
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mode 0 — Écran de choix initial
// ─────────────────────────────────────────────────────────────────────────────
class _ChoixMode extends StatelessWidget {
  final VoidCallback onChanger;
  final VoidCallback onOublie;
  final VoidCallback onRetour;

  const _ChoixMode({
    super.key,
    required this.onChanger,
    required this.onOublie,
    required this.onRetour,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          GestureDetector(
            onTap: onRetour,
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
          const SizedBox(height: 32),
          Text(
            'Sécurité du compte',
            style: GoogleFonts.archivo(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: SauveColors.encre,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Gérez l\'accès à votre compte SONGRE.',
            style: GoogleFonts.inter(
              fontSize: 15,
              color: SauveColors.gris,
            ),
          ),
          const SizedBox(height: 40),
          _buildOption(
            icon: Icons.lock_outline,
            titre: 'Modifier mon mot de passe',
            description: 'Vous connaissez votre mot de passe actuel.',
            onTap: onChanger,
          ),
          const SizedBox(height: 16),
          _buildOption(
            icon: Icons.email_outlined,
            titre: 'Mot de passe oublié',
            description: 'Recevoir un lien de réinitialisation par email.',
            onTap: onOublie,
          ),
        ],
      ),
    );
  }

  Widget _buildOption({
    required IconData icon,
    required String titre,
    required String description,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(18),
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
                color: SauveColors.rouge.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: SauveColors.rouge, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    titre,
                    style: GoogleFonts.archivo(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: SauveColors.encre,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      color: SauveColors.gris,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: SauveColors.gris, size: 20),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mode 1 — Formulaire "Modifier mon mot de passe"
// Appelle PUT /auth/v1/user avec { password: newPassword }
// puis déclenche la notification mdp_modifie via mdp-modifie-auth EF
// ─────────────────────────────────────────────────────────────────────────────
class _ChangerMdpForm extends StatefulWidget {
  final VoidCallback onRetour;
  /// Email passé depuis AppState (correction S4). Si null, fallback sur
  /// obtenirEmailCourant() — compatibilité ascendante conservée.
  final String? email;

  const _ChangerMdpForm({super.key, required this.onRetour, this.email});

  @override
  State<_ChangerMdpForm> createState() => _ChangerMdpFormState();
}

class _ChangerMdpFormState extends State<_ChangerMdpForm> {
  final _formKey = GlobalKey<FormState>();
  final _ancienCtrl = TextEditingController();
  final _nouveauCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  bool _showAncien = false;
  bool _showNouveau = false;
  bool _showConfirm = false;
  bool _loading = false;
  String? _erreur;

  @override
  void dispose() {
    _ancienCtrl.dispose();
    _nouveauCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  // Validation robustesse du mot de passe
  String? _validerRobustesse(String? value) {
    if (value == null || value.isEmpty) return 'Champ requis';
    if (value.length < 8) return 'Minimum 8 caractères';
    if (!RegExp(r'[A-Z]').hasMatch(value)) {
      return 'Au moins une majuscule requise';
    }
    if (!RegExp(r'[0-9]').hasMatch(value)) return 'Au moins un chiffre requis';
    return null;
  }

  Future<void> _soumettre() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _loading = true;
      _erreur = null;
    });

    try {
      // Étape 1 : Vérifier l'ancien mot de passe via re-authentification.
      // Correction S4 : utiliser l'email passé en paramètre (déjà connu de AppState)
      // plutôt que d'effectuer un appel réseau supplémentaire à obtenirEmailCourant().
      // Fallback sur l'appel réseau uniquement si le paramètre est absent (compatibilité).
      final emailResult = widget.email ?? await SupabaseService.obtenirEmailCourant();
      if (emailResult == null) {
        setState(() {
          _erreur = 'Session invalide. Veuillez vous reconnecter.';
          _loading = false;
        });
        return;
      }

      final verifResult = await SupabaseService.verifierMotDePasse(
        email: emailResult,
        motDePasse: _ancienCtrl.text.trim(),
      );

      if (!verifResult) {
        setState(() {
          _erreur = 'Mot de passe actuel incorrect.';
          _loading = false;
        });
        return;
      }

      // Étape 2 : Changer le mot de passe via /auth/v1/user
      final result = await SupabaseService.changerMotDePasse(
        nouveauMotDePasse: _nouveauCtrl.text.trim(),
      );

      if (!result.success) {
        setState(() {
          _erreur = result.error ?? 'Erreur lors du changement de mot de passe.';
          _loading = false;
        });
        return;
      }

      // Étape 3 : Notifier via mdp-modifie-auth EF (fire-and-forget, pas bloquant)
      unawaited(SupabaseService.declencherNotificationMdpModifie());

      if (!mounted) return;
      _afficherSucces();
    } catch (e) {
      if (kDebugMode) debugPrint('[ChangePasswordScreen] erreur: $e');
      setState(() {
        _erreur = 'Erreur inattendue. Veuillez réessayer.';
        _loading = false;
      });
    }
  }

  void _afficherSucces() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: SauveColors.creme,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle_outline,
                  color: Colors.green, size: 32),
            ),
            const SizedBox(height: 16),
            Text(
              'Mot de passe modifié',
              style: GoogleFonts.archivo(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: SauveColors.encre,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Votre mot de passe a été mis à jour. Un email de confirmation vous a été envoyé.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 14,
                color: SauveColors.gris,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  Navigator.of(context).pop();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: SauveColors.rouge,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text('Fermer',
                    style: GoogleFonts.archivo(fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 20),
            GestureDetector(
              onTap: widget.onRetour,
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
            const SizedBox(height: 28),
            Text(
              'Modifier mon\nmot de passe',
              style: GoogleFonts.archivo(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                color: SauveColors.encre,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 28),

            // Champ : ancien mot de passe
            _buildChampMdp(
              controller: _ancienCtrl,
              label: 'Mot de passe actuel',
              show: _showAncien,
              onToggle: () => setState(() => _showAncien = !_showAncien),
              validator: (v) =>
                  (v == null || v.isEmpty) ? 'Champ requis' : null,
            ),
            const SizedBox(height: 16),

            // Champ : nouveau mot de passe
            _buildChampMdp(
              controller: _nouveauCtrl,
              label: 'Nouveau mot de passe',
              show: _showNouveau,
              onToggle: () => setState(() => _showNouveau = !_showNouveau),
              validator: _validerRobustesse,
            ),
            const SizedBox(height: 8),

            // Indicateurs de robustesse
            _buildIndicateursRobustesse(_nouveauCtrl.text),
            const SizedBox(height: 16),

            // Champ : confirmation
            _buildChampMdp(
              controller: _confirmCtrl,
              label: 'Confirmer le nouveau mot de passe',
              show: _showConfirm,
              onToggle: () => setState(() => _showConfirm = !_showConfirm),
              validator: (v) {
                if (v == null || v.isEmpty) return 'Champ requis';
                if (v != _nouveauCtrl.text) {
                  return 'Les mots de passe ne correspondent pas';
                }
                return null;
              },
            ),
            const SizedBox(height: 8),

            // Message d'erreur global
            if (_erreur != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: SauveColors.rouge.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline,
                        color: SauveColors.rouge, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _erreur!,
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          color: SauveColors.rouge,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 32),

            // Bouton soumettre
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _loading ? null : _soumettre,
                style: ElevatedButton.styleFrom(
                  backgroundColor: SauveColors.rouge,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  disabledBackgroundColor:
                      SauveColors.rouge.withValues(alpha: 0.5),
                ),
                child: _loading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : Text(
                        'Changer le mot de passe',
                        style: GoogleFonts.archivo(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildChampMdp({
    required TextEditingController controller,
    required String label,
    required bool show,
    required VoidCallback onToggle,
    required String? Function(String?) validator,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: !show,
      onChanged: (_) => setState(() {}), // refresh indicateurs
      decoration: InputDecoration(
        labelText: label,
        labelStyle: GoogleFonts.inter(fontSize: 14, color: SauveColors.gris),
        suffixIcon: IconButton(
          icon: Icon(
            show ? Icons.visibility_off_outlined : Icons.visibility_outlined,
            color: SauveColors.gris,
            size: 20,
          ),
          onPressed: onToggle,
        ),
        filled: true,
        fillColor: SauveColors.carte,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: SauveColors.grisClair),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: SauveColors.grisClair),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:
              const BorderSide(color: SauveColors.rouge, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: SauveColors.rouge),
        ),
      ),
      validator: validator,
    );
  }

  Widget _buildIndicateursRobustesse(String mdp) {
    final hasLength = mdp.length >= 8;
    final hasMaj = RegExp(r'[A-Z]').hasMatch(mdp);
    final hasChiffre = RegExp(r'[0-9]').hasMatch(mdp);

    return Row(
      children: [
        _indicateur('8 car. min.', hasLength),
        const SizedBox(width: 8),
        _indicateur('Majuscule', hasMaj),
        const SizedBox(width: 8),
        _indicateur('Chiffre', hasChiffre),
      ],
    );
  }

  Widget _indicateur(String label, bool ok) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          ok ? Icons.check_circle : Icons.radio_button_unchecked,
          size: 14,
          color: ok ? Colors.green : SauveColors.grisClair,
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 12,
            color: ok ? Colors.green : SauveColors.gris,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mode 2 — Formulaire "Mot de passe oublié"
// Envoie un email de réinitialisation via /auth/v1/recover
// ─────────────────────────────────────────────────────────────────────────────
class _MdpOublieForm extends StatefulWidget {
  final VoidCallback onRetour;

  const _MdpOublieForm({super.key, required this.onRetour});

  @override
  State<_MdpOublieForm> createState() => _MdpOublieFormState();
}

class _MdpOublieFormState extends State<_MdpOublieForm> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  bool _loading = false;
  bool _envoye = false;
  String? _erreur;

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _soumettre() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _loading = true;
      _erreur = null;
    });

    final result = await SupabaseService.reinitialiserMotDePasse(
      email: _emailCtrl.text.trim().toLowerCase(),
    );

    if (!mounted) return;

    if (result) {
      setState(() {
        _envoye = true;
        _loading = false;
      });
    } else {
      setState(() {
        _erreur = 'Impossible d\'envoyer l\'email. Vérifiez l\'adresse saisie.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: _envoye ? _buildSuccess() : _buildForm(),
    );
  }

  Widget _buildForm() {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          GestureDetector(
            onTap: widget.onRetour,
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
          const SizedBox(height: 28),
          Text(
            'Mot de passe\noublié',
            style: GoogleFonts.archivo(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: SauveColors.encre,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Saisissez votre adresse email. Vous recevrez un lien pour réinitialiser votre mot de passe.',
            style: GoogleFonts.inter(
              fontSize: 14,
              color: SauveColors.gris,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 32),
          TextFormField(
            controller: _emailCtrl,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _soumettre(),
            decoration: InputDecoration(
              labelText: 'Adresse email',
              prefixIcon: const Icon(Icons.email_outlined,
                  color: SauveColors.gris, size: 20),
              labelStyle: GoogleFonts.inter(
                  fontSize: 14, color: SauveColors.gris),
              filled: true,
              fillColor: SauveColors.carte,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: SauveColors.grisClair),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: SauveColors.grisClair),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(
                    color: SauveColors.rouge, width: 1.5),
              ),
            ),
            validator: (v) {
              if (v == null || v.isEmpty) return 'Champ requis';
              if (!v.contains('@') || !v.contains('.')) {
                return 'Adresse email invalide';
              }
              return null;
            },
          ),
          if (_erreur != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: SauveColors.rouge.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline,
                      color: SauveColors.rouge, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _erreur!,
                      style: GoogleFonts.inter(
                          fontSize: 13, color: SauveColors.rouge),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _loading ? null : _soumettre,
              style: ElevatedButton.styleFrom(
                backgroundColor: SauveColors.rouge,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                disabledBackgroundColor:
                    SauveColors.rouge.withValues(alpha: 0.5),
              ),
              child: _loading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2),
                    )
                  : Text(
                      'Envoyer le lien',
                      style: GoogleFonts.archivo(
                          fontSize: 16, fontWeight: FontWeight.w700),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuccess() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const SizedBox(height: 80),
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: Colors.green.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.mark_email_read_outlined,
              color: Colors.green, size: 40),
        ),
        const SizedBox(height: 24),
        Text(
          'Email envoyé !',
          style: GoogleFonts.archivo(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: SauveColors.encre,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Un lien de réinitialisation a été envoyé à\n${_emailCtrl.text.trim()}.\n\nVérifiez vos spams si vous ne le recevez pas sous 5 minutes.',
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            fontSize: 14,
            color: SauveColors.gris,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 40),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: () => Navigator.of(context).pop(),
            style: OutlinedButton.styleFrom(
              foregroundColor: SauveColors.encre,
              side: const BorderSide(color: SauveColors.grisClair),
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            child: Text(
              'Retour à la connexion',
              style: GoogleFonts.archivo(
                  fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }
}

/// Utility to fire-and-forget an async operation without awaiting it.
void unawaited(Future<void> future) {
  future.catchError((e) {
    if (kDebugMode) debugPrint('[unawaited] error: $e');
  });
}
