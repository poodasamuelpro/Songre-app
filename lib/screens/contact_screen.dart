import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/sauve_theme.dart';
import '../services/supabase_service.dart';

// =====================================================================
// ÉCRAN — Aide et Contact
// D8 — Mission D : FAQ + formulaire → EF contacter-support
// =====================================================================
class ContactScreen extends StatefulWidget {
  const ContactScreen({super.key});

  @override
  State<ContactScreen> createState() => _ContactScreenState();
}

class _ContactScreenState extends State<ContactScreen> {
  // 0 = accueil FAQ+bouton, 1 = formulaire de contact
  int _mode = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SauveColors.creme,
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: _mode == 1
              ? _FormulaireContact(
                  key: const ValueKey('form'),
                  onRetour: () => setState(() => _mode = 0),
                )
              : _FaqAccueil(
                  key: const ValueKey('faq'),
                  onOuvrirFormulaire: () => setState(() => _mode = 1),
                  onRetour: () => Navigator.of(context).pop(),
                ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Section FAQ + bouton "Contacter le support"
// ─────────────────────────────────────────────────────────────────────────────
class _FaqAccueil extends StatefulWidget {
  final VoidCallback onOuvrirFormulaire;
  final VoidCallback onRetour;

  const _FaqAccueil({
    super.key,
    required this.onOuvrirFormulaire,
    required this.onRetour,
  });

  @override
  State<_FaqAccueil> createState() => _FaqAccueilState();
}

class _FaqAccueilState extends State<_FaqAccueil> {
  int? _ouvert;

  static const _faq = [
    (
      q: 'Qui peut donner du sang avec SONGRE ?',
      r: 'Tout donneur éligible peut s\'inscrire. L\'éligibilité dépend du délai depuis le dernier don : 60 jours pour les hommes, 90 jours pour les femmes. L\'application vérifie automatiquement votre éligibilité.',
    ),
    (
      q: 'Comment fonctionne la mise en relation ?',
      r: 'Lorsqu\'une demande de sang compatible avec votre groupe est publiée dans votre ville, vous recevez une notification. Vous pouvez alors répondre positivement si vous êtes disponible. Toutes les mises en relation sont anonymes.',
    ),
    (
      q: 'Comment confirmer un don effectué ?',
      r: 'Le demandeur génère un QR code dans l\'application. Après votre don à la structure sanitaire, le personnel ou le demandeur scanne le QR code pour valider le don dans l\'application.',
    ),
    (
      q: 'Comment déclarer un don fait en dehors de l\'application ?',
      r: 'Allez dans votre profil > "Déclarer un don". Entrez la date du don. Cela mettra à jour votre historique et recalculera votre éligibilité automatiquement.',
    ),
    (
      q: 'Mes données personnelles sont-elles protégées ?',
      r: 'Oui. Votre identité n\'est jamais révélée aux demandeurs. Seules les données de compatibilité et de localisation sont utilisées pour les mises en relation. Vous pouvez supprimer votre compte à tout moment depuis les paramètres.',
    ),
    (
      q: 'Que se passe-t-il si je supprime mon compte ?',
      r: 'La suppression est programmée sous 5 jours. Pendant ce délai, vous pouvez annuler la demande. Après 5 jours, toutes vos données sont définitivement supprimées de nos serveurs.',
    ),
    (
      q: 'L\'application fonctionne-t-elle hors ligne ?',
      r: 'Partiellement. Vos données de profil sont accessibles hors ligne. Cependant, les notifications, les nouvelles demandes et les validations de don nécessitent une connexion internet.',
    ),
    (
      q: 'Comment activer les notifications ?',
      r: 'Autorisez les notifications lors de l\'installation de l\'application. Si vous les avez refusées, rendez-vous dans les paramètres de votre téléphone > Applications > SONGRE > Notifications.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ── En-tête ─────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: Row(
            children: [
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
              const SizedBox(width: 12),
              Text(
                'Aide et Contact',
                style: GoogleFonts.archivo(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: SauveColors.encre,
                ),
              ),
            ],
          ),
        ),

        // ── Corps scrollable ─────────────────────────────────────────
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
            children: [
              Text(
                'Questions fréquentes',
                style: GoogleFonts.archivo(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: SauveColors.encre,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Trouvez rapidement une réponse à votre question.',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  color: SauveColors.gris,
                ),
              ),
              const SizedBox(height: 20),

              // FAQ accordion
              ...List.generate(_faq.length, (i) {
                final item = _faq[i];
                final isOpen = _ouvert == i;
                return _buildFaqItem(
                  question: item.q,
                  reponse: item.r,
                  isOpen: isOpen,
                  onToggle: () =>
                      setState(() => _ouvert = isOpen ? null : i),
                );
              }),

              const SizedBox(height: 32),

              // Séparateur
              Container(
                height: 1,
                color: SauveColors.grisClair,
              ),
              const SizedBox(height: 28),

              // Bloc contact
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: SauveColors.rouge.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: SauveColors.rouge.withValues(alpha: 0.15)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: SauveColors.rouge.withValues(alpha: 0.1),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.support_agent_outlined,
                              color: SauveColors.rouge, size: 22),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Vous n\'avez pas trouvé votre réponse ?',
                            style: GoogleFonts.archivo(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: SauveColors.encre,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Notre équipe répond sous 24 à 48h.',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        color: SauveColors.gris,
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: widget.onOuvrirFormulaire,
                        icon: const Icon(Icons.send_outlined, size: 18),
                        label: Text(
                          'Envoyer un message',
                          style: GoogleFonts.archivo(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: SauveColors.rouge,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFaqItem({
    required String question,
    required String reponse,
    required bool isOpen,
    required VoidCallback onToggle,
  }) {
    return GestureDetector(
      onTap: onToggle,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: SauveColors.carte,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isOpen
                ? SauveColors.rouge.withValues(alpha: 0.3)
                : SauveColors.grisClair,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      question,
                      style: GoogleFonts.archivo(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: SauveColors.encre,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: isOpen ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(
                      Icons.keyboard_arrow_down,
                      color: SauveColors.gris,
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),
            if (isOpen)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                child: Text(
                  reponse,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: SauveColors.gris,
                    height: 1.55,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Formulaire de contact → appelle EF contacter-support
// ─────────────────────────────────────────────────────────────────────────────
class _FormulaireContact extends StatefulWidget {
  final VoidCallback onRetour;

  const _FormulaireContact({super.key, required this.onRetour});

  @override
  State<_FormulaireContact> createState() => _FormulaireContactState();
}

class _FormulaireContactState extends State<_FormulaireContact> {
  final _formKey = GlobalKey<FormState>();
  final _objetCtrl = TextEditingController();
  final _messageCtrl = TextEditingController();
  bool _loading = false;
  bool _envoye = false;
  String? _erreur;

  static const _objetsPredefinis = [
    'Problème technique',
    'Question sur le don',
    'Signalement d\'abus',
    'Suggestion d\'amélioration',
    'Autre',
  ];

  @override
  void dispose() {
    _objetCtrl.dispose();
    _messageCtrl.dispose();
    super.dispose();
  }

  Future<void> _soumettre() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _loading = true;
      _erreur = null;
    });

    final result = await SupabaseService.envoyerMessageSupport(
      objet: _objetCtrl.text.trim(),
      message: _messageCtrl.text.trim(),
    );

    if (!mounted) return;

    if (result.success) {
      setState(() {
        _envoye = true;
        _loading = false;
      });
    } else {
      setState(() {
        _erreur = result.error ??
            'Erreur lors de l\'envoi. Veuillez réessayer.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_envoye) return _buildSucces();

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
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
            const SizedBox(height: 24),
            Text(
              'Envoyer un\nmessage',
              style: GoogleFonts.archivo(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                color: SauveColors.encre,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Notre équipe vous répond sous 24 à 48h.',
              style: GoogleFonts.inter(
                  fontSize: 14, color: SauveColors.gris),
            ),
            const SizedBox(height: 28),

            // Objet — chips de sélection rapide
            Text(
              'Objet',
              style: GoogleFonts.archivo(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: SauveColors.encre,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _objetsPredefinis.map((obj) {
                final selected = _objetCtrl.text == obj;
                return GestureDetector(
                  onTap: () => setState(() => _objetCtrl.text = obj),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: selected
                          ? SauveColors.rouge
                          : SauveColors.carte,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: selected
                            ? SauveColors.rouge
                            : SauveColors.grisClair,
                      ),
                    ),
                    child: Text(
                      obj,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: selected
                            ? Colors.white
                            : SauveColors.encre,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),

            // Champ objet libre (optionnel si pas de chip sélectionné)
            TextFormField(
              controller: _objetCtrl,
              maxLength: 100,
              decoration: InputDecoration(
                labelText: 'Ou saisir un objet libre',
                labelStyle: GoogleFonts.inter(
                    fontSize: 13, color: SauveColors.gris),
                counterText: '${_objetCtrl.text.length}/100',
                filled: true,
                fillColor: SauveColors.carte,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide:
                      const BorderSide(color: SauveColors.grisClair),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide:
                      const BorderSide(color: SauveColors.grisClair),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(
                      color: SauveColors.rouge, width: 1.5),
                ),
              ),
              onChanged: (_) => setState(() {}),
              validator: (v) {
                if (v == null || v.trim().isEmpty) {
                  return 'Veuillez renseigner un objet';
                }
                if (v.trim().length > 100) {
                  return 'L\'objet ne peut pas dépasser 100 caractères';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // Champ message
            Text(
              'Message',
              style: GoogleFonts.archivo(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: SauveColors.encre,
              ),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _messageCtrl,
              maxLines: 6,
              maxLength: 2000,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText:
                    'Décrivez votre problème ou question en détail...',
                hintStyle: GoogleFonts.inter(
                    fontSize: 13, color: SauveColors.gris),
                counterText:
                    '${_messageCtrl.text.length}/2000',
                filled: true,
                fillColor: SauveColors.carte,
                contentPadding: const EdgeInsets.all(14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide:
                      const BorderSide(color: SauveColors.grisClair),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide:
                      const BorderSide(color: SauveColors.grisClair),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(
                      color: SauveColors.rouge, width: 1.5),
                ),
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) {
                  return 'Veuillez écrire votre message';
                }
                if (v.trim().length < 20) {
                  return 'Message trop court (minimum 20 caractères)';
                }
                if (v.trim().length > 2000) {
                  return 'Message trop long (maximum 2 000 caractères)';
                }
                return null;
              },
            ),

            // Erreur globale
            if (_erreur != null) ...[
              const SizedBox(height: 10),
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

            const SizedBox(height: 28),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _loading ? null : _soumettre,
                icon: _loading
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2),
                      )
                    : const Icon(Icons.send_outlined, size: 18),
                label: Text(
                  _loading ? 'Envoi en cours…' : 'Envoyer',
                  style: GoogleFonts.archivo(
                      fontSize: 16, fontWeight: FontWeight.w700),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: SauveColors.rouge,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  disabledBackgroundColor:
                      SauveColors.rouge.withValues(alpha: 0.5),
                ),
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildSucces() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle_outline,
                  color: Colors.green, size: 40),
            ),
            const SizedBox(height: 24),
            Text(
              'Message envoyé !',
              style: GoogleFonts.archivo(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: SauveColors.encre,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Votre message a bien été reçu. Notre équipe vous répondra dans les 24 à 48h à votre adresse email.',
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
                  side:
                      const BorderSide(color: SauveColors.grisClair),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: Text(
                  'Retour',
                  style: GoogleFonts.archivo(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
