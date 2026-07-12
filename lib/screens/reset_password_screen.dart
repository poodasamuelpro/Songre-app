import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:go_router/go_router.dart';
import '../theme/sauve_theme.dart';
import '../services/supabase_service.dart';

// =====================================================================
// ÉCRAN — Réinitialisation du mot de passe par code OTP
//
// Flux (depuis session 5) :
//   Étape A : saisie email → envoi du code OTP via /auth/v1/recover
//   Étape B : saisie du code à 6 chiffres + nouveau mot de passe
//             → vérification via /auth/v1/verify (type=recovery)
//             → changement via /auth/v1/user (Bearer = token OTP)
//
// L'ancien flux deep link (songre://reset-password?access_token=...) a été
// abandonné : trop dépendant de la configuration Android et peu fiable.
// Ce flux OTP fonctionne entièrement dans l'app, sans navigateur intermédiaire.
// =====================================================================

// Étapes internes de l'écran
enum _EtapeReset { email, code, succes }

class ResetPasswordScreen extends StatefulWidget {
  /// Email pré-rempli, passé depuis _MdpOublieForm pour éviter une ressaisie.
  final String emailInitial;

  const ResetPasswordScreen({
    super.key,
    this.emailInitial = '',
  });

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  _EtapeReset _etape = _EtapeReset.email;

  // Étape A — email
  final _emailFormKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  bool _loadingEmail = false;
  String? _erreurEmail;

  // Étape B — code + nouveau mot de passe
  final _codeFormKey = GlobalKey<FormState>();
  final _codeCtrl = TextEditingController();
  final _mdpCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _loadingCode = false;
  bool _mdpVisible = false;
  bool _confirmVisible = false;
  String? _erreurCode;

  // (token OTP stocké en mémoire temporairement pour usage futur si besoin)

  @override
  void initState() {
    super.initState();
    if (widget.emailInitial.isNotEmpty) {
      _emailCtrl.text = widget.emailInitial;
    }
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _codeCtrl.dispose();
    _mdpCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  // ── Étape A : envoi du code ─────────────────────────────────────────

  Future<void> _envoyerCode() async {
    if (!_emailFormKey.currentState!.validate()) return;
    setState(() {
      _loadingEmail = true;
      _erreurEmail = null;
    });

    final result = await SupabaseService.envoyerEmailReinitialisation(
      _emailCtrl.text.trim(),
    );

    if (!mounted) return;

    if (result.success) {
      setState(() {
        _etape = _EtapeReset.code;
        _loadingEmail = false;
      });
    } else {
      setState(() {
        _erreurEmail = result.error;
        _loadingEmail = false;
      });
    }
  }

  // ── Étape B : vérification OTP + changement de mot de passe ─────────

  Future<void> _verifierEtChanger() async {
    if (!_codeFormKey.currentState!.validate()) return;
    setState(() {
      _loadingCode = true;
      _erreurCode = null;
    });

    final email = _emailCtrl.text.trim();
    final code = _codeCtrl.text.trim();

    // Phase 1 : vérifier le code OTP
    final verif = await SupabaseService.verifierCodeReinitialisation(
      email: email,
      code: code,
    );

    if (!mounted) return;

    if (!verif.success) {
      setState(() {
        _erreurCode = verif.error;
        _loadingCode = false;
      });
      return;
    }

    final token = verif.accessToken;
    if (token == null || token.isEmpty) {
      setState(() {
        _erreurCode = 'Réponse inattendue du serveur. Réessayez.';
        _loadingCode = false;
      });
      return;
    }

    // Phase 2 : changer le mot de passe avec le token obtenu
    final changement = await SupabaseService.changerMotDePasseAvecToken(
      accessToken: token,
      nouveauMotDePasse: _mdpCtrl.text,
    );

    if (!mounted) return;

    if (changement.success) {
      setState(() {
        _etape = _EtapeReset.succes;
        _loadingCode = false;
      });
    } else {
      setState(() {
        _erreurCode = changement.error;
        _loadingCode = false;
      });
    }
  }

  // ── Renvoyer le code ────────────────────────────────────────────────

  Future<void> _renvoyerCode() async {
    setState(() {
      _erreurCode = null;
      _codeCtrl.clear();
    });

    final result = await SupabaseService.envoyerEmailReinitialisation(
      _emailCtrl.text.trim(),
    );

    if (!mounted) return;

    if (result.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Un nouveau code a été envoyé à ${_emailCtrl.text.trim()}',
            style: GoogleFonts.inter(fontSize: 13),
          ),
          backgroundColor: SauveColors.vert,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } else {
      setState(() {
        _erreurCode = result.error ?? 'Impossible de renvoyer le code.';
      });
    }
  }

  // ── Build principal ─────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SauveColors.creme,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 32),
              _buildEnTete(),
              const SizedBox(height: 32),

              if (_etape == _EtapeReset.email) _buildEtapeEmail(),
              if (_etape == _EtapeReset.code) _buildEtapeCode(),
              if (_etape == _EtapeReset.succes) _buildSucces(context),

              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEnTete() {
    return Row(
      children: [
        Image.asset(
          'assets/images/logo_songre.png',
          height: 40,
          errorBuilder: (_, __, ___) => const Icon(
            Icons.favorite,
            color: SauveColors.rouge,
            size: 40,
          ),
        ),
        const SizedBox(width: 12),
        Text(
          'SONGRE',
          style: GoogleFonts.archivo(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: SauveColors.encre,
          ),
        ),
      ],
    );
  }

  // ── Étape A — saisie email ──────────────────────────────────────────

  Widget _buildEtapeEmail() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Réinitialiser le mot de passe',
          style: GoogleFonts.archivo(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            color: SauveColors.encre,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Saisissez votre adresse email. Nous vous enverrons un code à 6 chiffres pour réinitialiser votre mot de passe.',
          style: GoogleFonts.inter(
            fontSize: 14,
            color: SauveColors.gris,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 32),

        Form(
          key: _emailFormKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _label('Adresse email'),
              const SizedBox(height: 8),
              TextFormField(
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                style: GoogleFonts.inter(fontSize: 14.5),
                decoration: _inputDeco(
                  hint: 'votre@email.com',
                  prefixIcon: const Icon(
                    Icons.email_outlined,
                    size: 20,
                    color: SauveColors.gris,
                  ),
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Email requis.';
                  if (!v.contains('@') || !v.contains('.')) {
                    return 'Email invalide.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),

              if (_erreurEmail != null) ...[
                _buildErreur(_erreurEmail!),
                const SizedBox(height: 16),
              ],

              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _loadingEmail ? null : _envoyerCode,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: SauveColors.rouge,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 17),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: _loadingEmail
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          'Envoyer le code',
                          style: GoogleFonts.archivo(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: GestureDetector(
                  onTap: () => context.go('/'),
                  child: Text(
                    'Retour à la connexion',
                    style: GoogleFonts.inter(
                      fontSize: 13.5,
                      color: SauveColors.gris,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Étape B — saisie code + nouveau mot de passe ────────────────────

  Widget _buildEtapeCode() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Entrez votre code',
          style: GoogleFonts.archivo(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            color: SauveColors.encre,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 10),
        RichText(
          text: TextSpan(
            style: GoogleFonts.inter(
              fontSize: 14,
              color: SauveColors.gris,
              height: 1.5,
            ),
            children: [
              const TextSpan(
                text: 'Un code à 6 chiffres a été envoyé à ',
              ),
              TextSpan(
                text: _emailCtrl.text.trim(),
                style: GoogleFonts.inter(
                  fontSize: 14,
                  color: SauveColors.encre,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const TextSpan(
                text: '. Vérifiez votre boîte mail (et les spams).',
              ),
            ],
          ),
        ),
        const SizedBox(height: 32),

        Form(
          key: _codeFormKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Code OTP ────────────────────────────────────────────
              _label('Code de vérification'),
              const SizedBox(height: 8),
              TextFormField(
                controller: _codeCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                textAlign: TextAlign.center,
                style: GoogleFonts.archivo(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 12,
                  color: SauveColors.encre,
                ),
                decoration: _inputDeco(
                  hint: '------',
                ).copyWith(
                  hintStyle: GoogleFonts.archivo(
                    fontSize: 28,
                    letterSpacing: 12,
                    color: SauveColors.gris.withValues(alpha: 0.4),
                  ),
                ),
                validator: (v) {
                  if (v == null || v.trim().length != 6) {
                    return 'Le code doit contenir exactement 6 chiffres.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 8),
              Center(
                child: GestureDetector(
                  onTap: _renvoyerCode,
                  child: Text(
                    'Renvoyer un code',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      color: SauveColors.rouge,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // ── Nouveau mot de passe ─────────────────────────────────
              _label('Nouveau mot de passe'),
              const SizedBox(height: 8),
              TextFormField(
                controller: _mdpCtrl,
                obscureText: !_mdpVisible,
                style: GoogleFonts.inter(fontSize: 14.5),
                decoration: _inputDeco(
                  hint: 'Au moins 8 caractères',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _mdpVisible
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      color: SauveColors.gris,
                      size: 20,
                    ),
                    onPressed: () =>
                        setState(() => _mdpVisible = !_mdpVisible),
                  ),
                ),
                validator: (v) {
                  if (v == null || v.isEmpty) {
                    return 'Le mot de passe est requis.';
                  }
                  if (v.length < 8) {
                    return 'Minimum 8 caractères.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 18),

              // ── Confirmation ─────────────────────────────────────────
              _label('Confirmer le mot de passe'),
              const SizedBox(height: 8),
              TextFormField(
                controller: _confirmCtrl,
                obscureText: !_confirmVisible,
                style: GoogleFonts.inter(fontSize: 14.5),
                decoration: _inputDeco(
                  hint: 'Répétez le mot de passe',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _confirmVisible
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      color: SauveColors.gris,
                      size: 20,
                    ),
                    onPressed: () =>
                        setState(() => _confirmVisible = !_confirmVisible),
                  ),
                ),
                validator: (v) {
                  if (v != _mdpCtrl.text) {
                    return 'Les mots de passe ne correspondent pas.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 24),

              if (_erreurCode != null) ...[
                _buildErreur(_erreurCode!),
                const SizedBox(height: 16),
              ],

              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _loadingCode ? null : _verifierEtChanger,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: SauveColors.rouge,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 17),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: _loadingCode
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          'Réinitialiser le mot de passe',
                          style: GoogleFonts.archivo(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: GestureDetector(
                  onTap: () => setState(() {
                    _etape = _EtapeReset.email;
                    _erreurCode = null;
                  }),
                  child: Text(
                    'Changer l\'adresse email',
                    style: GoogleFonts.inter(
                      fontSize: 13.5,
                      color: SauveColors.gris,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Succès ─────────────────────────────────────────────────────────

  Widget _buildSucces(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: SauveColors.vertFond,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: SauveColors.vert.withValues(alpha: 0.4)),
          ),
          child: Column(
            children: [
              const Icon(
                Icons.check_circle_outline,
                color: SauveColors.vert,
                size: 56,
              ),
              const SizedBox(height: 16),
              Text(
                'Mot de passe modifié !',
                style: GoogleFonts.archivo(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: SauveColors.vert,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                'Votre mot de passe a été réinitialisé avec succès. '
                'Vous pouvez maintenant vous connecter avec votre nouveau mot de passe.',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  color: SauveColors.vert,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () => context.go('/'),
            style: ElevatedButton.styleFrom(
              backgroundColor: SauveColors.rouge,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 17),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: Text(
              'Se connecter',
              style: GoogleFonts.archivo(
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── Helpers UI ──────────────────────────────────────────────────────

  Widget _buildErreur(String message) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFCA5A5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline,
              color: SauveColors.rouge, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: GoogleFonts.inter(
                fontSize: 13,
                color: SauveColors.rouge,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String text) {
    return Text(
      text,
      style: GoogleFonts.inter(
        fontSize: 13.5,
        fontWeight: FontWeight.w600,
        color: SauveColors.encre,
      ),
    );
  }

  InputDecoration _inputDeco({
    required String hint,
    Widget? prefixIcon,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: GoogleFonts.inter(fontSize: 14, color: SauveColors.gris),
      prefixIcon: prefixIcon,
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: SauveColors.carte,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
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
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide:
            const BorderSide(color: SauveColors.rouge, width: 1.5),
      ),
    );
  }
}
