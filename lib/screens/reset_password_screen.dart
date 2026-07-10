import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import '../theme/sauve_theme.dart';
import '../services/supabase_service.dart';

// =====================================================================
// ÉCRAN — Réinitialisation du mot de passe
// Accessible via deep link : songre://reset-password?access_token=xxx&type=recovery
// Ou via HTTPS : https://songre.vercel.app/reset-password?access_token=xxx
//
// Flow Supabase :
//   1. L'utilisateur clique le lien email → Supabase redirige vers ce schéma
//   2. Android intercepte le deep link → GoRouter route /reset-password
//   3. access_token extrait du query param → utilisé pour PATCH /auth/v1/user
// =====================================================================

class ResetPasswordScreen extends StatefulWidget {
  /// Token d'accès extrait du deep link (query param access_token).
  final String accessToken;

  /// Type du lien (ex: "recovery") — présent dans certains liens Supabase.
  final String type;

  const ResetPasswordScreen({
    super.key,
    required this.accessToken,
    this.type = '',
  });

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _mdpCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _loading = false;
  bool _mdpVisible = false;
  bool _confirmVisible = false;
  bool _succes = false;
  String? _erreur;

  @override
  void dispose() {
    _mdpCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  bool get _tokenValide => widget.accessToken.isNotEmpty;

  Future<void> _reinitialiser() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _erreur = null;
    });

    try {
      // PATCH /auth/v1/user avec le Bearer = access_token de récupération
      final resp = await http.put(
        Uri.parse('${SupabaseService.supabaseUrl}/auth/v1/user'),
        headers: {
          'Content-Type': 'application/json',
          'apikey': SupabaseService.anonKey,
          'Authorization': 'Bearer ${widget.accessToken}',
        },
        body: jsonEncode({'password': _mdpCtrl.text}),
      ).timeout(const Duration(seconds: 15));

      if (!mounted) return;

      if (resp.statusCode == 200) {
        setState(() {
          _succes = true;
          _loading = false;
        });
      } else {
        final data = jsonDecode(resp.body) as Map<String, dynamic>?;
        final msg = data?['message'] as String? ??
            data?['error_description'] as String? ??
            data?['msg'] as String? ??
            'Erreur lors de la réinitialisation (${resp.statusCode}).';
        setState(() {
          _erreur = msg;
          _loading = false;
        });
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[ResetPasswordScreen] error: $e');
      if (!mounted) return;
      setState(() {
        _erreur = 'Connexion impossible. Vérifiez votre réseau.';
        _loading = false;
      });
    }
  }

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

              // ── En-tête ────────────────────────────────────────────────
              Row(
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
              ),
              const SizedBox(height: 32),

              if (_succes) ...[
                // ── Succès ───────────────────────────────────────────────
                _buildSuccesCard(context),
              ] else if (!_tokenValide) ...[
                // ── Token manquant / expiré ──────────────────────────────
                _buildTokenInvalide(context),
              ] else ...[
                // ── Formulaire ───────────────────────────────────────────
                Text(
                  'Nouveau mot de passe',
                  style: GoogleFonts.archivo(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: SauveColors.encre,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Choisissez un mot de passe sécurisé pour votre compte SONGRE.',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    color: SauveColors.gris,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 32),

                Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Nouveau mot de passe
                      _label('Nouveau mot de passe'),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _mdpCtrl,
                        obscureText: !_mdpVisible,
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

                      // Confirmation
                      _label('Confirmer le mot de passe'),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _confirmCtrl,
                        obscureText: !_confirmVisible,
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
                            onPressed: () => setState(
                                () => _confirmVisible = !_confirmVisible),
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

                      // Message d'erreur
                      if (_erreur != null) ...[
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEF2F2),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: const Color(0xFFFCA5A5)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.error_outline,
                                  color: SauveColors.rouge, size: 18),
                              const SizedBox(width: 10),
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
                        const SizedBox(height: 16),
                      ],

                      // Bouton
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _loading ? null : _reinitialiser,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: SauveColors.rouge,
                            foregroundColor: Colors.white,
                            padding:
                                const EdgeInsets.symmetric(vertical: 17),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: _loading
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
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSuccesCard(BuildContext context) {
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

  Widget _buildTokenInvalide(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFFFEF2F2),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFFCA5A5)),
          ),
          child: Column(
            children: [
              const Icon(
                Icons.link_off_outlined,
                color: SauveColors.rouge,
                size: 48,
              ),
              const SizedBox(height: 16),
              Text(
                'Lien invalide ou expiré',
                style: GoogleFonts.archivo(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: SauveColors.rouge,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                'Ce lien de réinitialisation est invalide ou a expiré (valide 1 heure). '
                'Retournez sur l\'application et demandez un nouveau lien.',
                style: GoogleFonts.inter(
                  fontSize: 13.5,
                  color: SauveColors.rouge,
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
              'Retourner à l\'accueil',
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
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: GoogleFonts.inter(fontSize: 14, color: SauveColors.gris),
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
