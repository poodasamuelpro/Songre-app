import 'dart:async'; // unawaited()
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../theme/sauve_theme.dart';
import '../services/app_state.dart';
import '../services/supabase_service.dart';
import '../models/models.dart';
import '../widgets/web_security_banner.dart';

// =====================================================================
// ÉCRAN 1 — Inscription / Connexion SONGRE
// Authentification : Email + Mot de passe via Supabase Auth
// =====================================================================
class LoginScreen extends StatefulWidget {
  /// [2.8] Optionnel : démarrer directement à une étape donnée.
  /// Utilisé par la route /completer-profil pour sauter directement
  /// au formulaire profil (step 3) sans repasser par l'accueil.
  final int initialStep;

  const LoginScreen({super.key, this.initialStep = 0});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  // 0 = accueil, 1 = connexion, 2 = inscription email, 3 = création profil
  late int _step;
  String _emailPourProfil = '';

  @override
  void initState() {
    super.initState();
    _step = widget.initialStep;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SauveColors.creme,
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: _buildStep(),
        ),
      ),
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case 1:
        return _ConnexionForm(
          key: const ValueKey('connexion'),
          onSuccess: () {
            // La navigation est gérée par GoRouter redirect
          },
          onInscription: () => setState(() => _step = 2),
          onMdpOublie: () => setState(() => _step = 4),
          onRetour: () => setState(() => _step = 0),
        );
      case 2:
        return _InscriptionForm(
          key: const ValueKey('inscription'),
          onSuccess: (email) {
            _emailPourProfil = email;
            setState(() => _step = 3);
          },
          onConnexion: () => setState(() => _step = 1),
          onRetour: () => setState(() => _step = 0),
        );
      case 3:
        return _ProfilForm(
          key: const ValueKey('profil'),
          email: _emailPourProfil,
          onRetour: () => setState(() => _step = 0),
        );
      case 4:
        return _MdpOublieForm(
          key: const ValueKey('mdp_oublie'),
          onRetour: () => setState(() => _step = 1),
        );
      default:
        return _buildAccueil();
    }
  }

  Widget _buildAccueil() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 48),
          // Logo SONGRE — D7 Mission D
          Image.asset(
            'assets/images/logo_songre.png',
            height: 72,
            alignment: Alignment.centerLeft,
          ),
          const SizedBox(height: 24),
          Text(
            'Chaque don\npeut sauver\nune vie.',
            style: GoogleFonts.archivo(
              fontSize: 32,
              fontWeight: FontWeight.w800,
              color: SauveColors.encre,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'SONGRE — Mise en relation anonyme entre donneurs et demandeurs de sang au Burkina Faso.',
            style: GoogleFonts.inter(
              fontSize: 15,
              color: SauveColors.gris,
              height: 1.5,
            ),
          ),
          const Spacer(),
          // Bouton principal — Créer un compte
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => setState(() => _step = 2),
              style: ElevatedButton.styleFrom(
                backgroundColor: SauveColors.rouge,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: Text(
                'Créer un compte',
                style: GoogleFonts.archivo(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Bouton secondaire — Se connecter
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => setState(() => _step = 1),
              style: OutlinedButton.styleFrom(
                foregroundColor: SauveColors.encre,
                side: const BorderSide(
                    color: SauveColors.grisClair, width: 1.5),
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: Text(
                'Se connecter',
                style: GoogleFonts.archivo(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: SauveColors.encre,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: SauveColors.vertFond,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(Icons.lock_outline,
                    color: SauveColors.vert, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Aucun nom ni prénom n\'est jamais demandé. Votre anonymat est garanti.',
                    style: GoogleFonts.inter(
                      fontSize: 12.5,
                      color: SauveColors.vert,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

// =====================================================================
// Formulaire de connexion
// =====================================================================
class _ConnexionForm extends StatefulWidget {
  final VoidCallback onSuccess;
  final VoidCallback onInscription;
  final VoidCallback onMdpOublie;
  final VoidCallback onRetour;

  const _ConnexionForm({
    super.key,
    required this.onSuccess,
    required this.onInscription,
    required this.onMdpOublie,
    required this.onRetour,
  });

  @override
  State<_ConnexionForm> createState() => _ConnexionFormState();
}

class _ConnexionFormState extends State<_ConnexionForm> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _mdpCtrl = TextEditingController();
  bool _loading = false;
  bool _showMdp = false;

  // [2.5] Rate limiting applicatif — 5 échecs → blocage 60 secondes
  int _echecsConnexion = 0;
  DateTime? _blocageJusquA;
  static const int _maxEchecs = 5;
  static const Duration _dureeBlocage = Duration(seconds: 60);

  @override
  void dispose() {
    _emailCtrl.dispose();
    _mdpCtrl.dispose();
    super.dispose();
  }

  bool get _estBloque {
    if (_blocageJusquA == null) return false;
    if (DateTime.now().isAfter(_blocageJusquA!)) {
      _echecsConnexion = 0;
      _blocageJusquA = null;
      return false;
    }
    return true;
  }

  int get _secondesRestants {
    if (_blocageJusquA == null) return 0;
    final remaining = _blocageJusquA!.difference(DateTime.now()).inSeconds;
    return remaining < 0 ? 0 : remaining;
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 20),
            _buildHeader('Se connecter', widget.onRetour),
            // Bannière sécurité Web (SEC-02)
            if (kIsWeb) const WebSecurityBanner(),
            const SizedBox(height: 8),
            Text(
              'Connectez-vous à votre compte SONGRE.',
              style:
                  GoogleFonts.inter(fontSize: 13, color: SauveColors.gris),
            ),
            const SizedBox(height: 28),
            _label('Email'),
            const SizedBox(height: 8),
            _buildEmailField(),
            const SizedBox(height: 16),
            _label('Mot de passe'),
            const SizedBox(height: 8),
            _buildMdpField(),
            // Lien mot de passe oublié
            Align(
              alignment: Alignment.centerRight,
              child: GestureDetector(
                onTap: widget.onMdpOublie,
                child: Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 4),
                  child: Text(
                    'Mot de passe oublié ?',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      color: SauveColors.rouge,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Indicateur de blocage [2.5]
            if (_estBloque)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF2F2),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFFCA5A5)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.timer_outlined,
                        size: 16, color: Color(0xFFDC2626)),
                    const SizedBox(width: 8),
                    Text(
                      'Trop de tentatives. Réessayez dans $_secondesRestants s.',
                      style: GoogleFonts.inter(
                          fontSize: 12.5, color: const Color(0xFFDC2626)),
                    ),
                  ],
                ),
              ),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: (_loading || _estBloque) ? null : _connecter,
                style: ElevatedButton.styleFrom(
                  backgroundColor: SauveColors.rouge,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 17),
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
                        'Se connecter',
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
                onTap: widget.onInscription,
                child: Text.rich(
                  TextSpan(
                    text: 'Pas encore de compte ? ',
                    style: GoogleFonts.inter(
                        fontSize: 13.5, color: SauveColors.gris),
                    children: [
                      TextSpan(
                        text: 'Créer un compte',
                        style: GoogleFonts.inter(
                          fontSize: 13.5,
                          color: SauveColors.rouge,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
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

  Future<void> _connecter() async {
    if (!_formKey.currentState!.validate()) return;
    // [2.5] Vérifier le blocage avant même l'appel réseau
    if (_estBloque) {
      setState(() {}); // rafraîchit le compteur affiché
      return;
    }
    setState(() => _loading = true);

    final state = context.read<AppState>();
    final ok = await state.connecter(
      email: _emailCtrl.text.trim(),
      motDePasse: _mdpCtrl.text,
    );

    // Correction S1-B : on utilise `if (mounted)` au lieu de `if (!mounted) return`
    // pour garantir que le spinner local est toujours réinitialisé.
    // L'ancien `if (!mounted) return` laissait le spinner figé si le widget
    // était démonté pendant l'await (navigation rapide, double-tap, pop).
    if (mounted) setState(() => _loading = false);
    if (!mounted) return; // Guard pour les opérations UI suivantes (SnackBar, etc.)

    if (!ok) {
      // [P4] Encapsuler dans setState() pour affichage immédiat du bandeau de blocage.
      // Note : ce rate limiting est une protection UX de confort (anti-spam visuel).
      // La protection anti-bruteforce réelle repose sur Supabase Auth (codes HTTP 429).
      // Ce compteur vit dans l'état local du widget — il est réinitialisé si
      // l'utilisateur quitte et revient sur l'écran (limitation inhérente, acceptable).
      setState(() {
        _echecsConnexion++;
        if (_echecsConnexion >= _maxEchecs) {
          _blocageJusquA = DateTime.now().add(_dureeBlocage);
          _echecsConnexion = 0;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            state.authError ?? 'Connexion impossible. Vérifiez vos identifiants.',
            style: GoogleFonts.inter(fontSize: 13),
          ),
          backgroundColor: SauveColors.rouge,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          duration: const Duration(seconds: 5),
        ),
      );
    } else {
      // [P3] Succès — réinitialiser le compteur et forcer la navigation
      setState(() {
        _echecsConnexion = 0;
        _blocageJusquA = null;
      });
      // Afficher un avertissement si la session est valide mais le profil
      // n'a pas pu être chargé (P2 — cas réseau dégradé, cache vide).
      if (state.authError != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              state.authError!,
              style: GoogleFonts.inter(fontSize: 13),
            ),
            backgroundColor: Colors.orange.shade700,
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            duration: const Duration(seconds: 6),
          ),
        );
      }
      // [P3] Filet de sécurité : si le redirect GoRouter ne se déclenche pas
      // immédiatement (ex. notifyListeners() tardif), forcer la navigation ici.
      if (mounted) context.go('/home');
    }
  }

  Widget _buildEmailField() {
    return TextFormField(
      controller: _emailCtrl,
      keyboardType: TextInputType.emailAddress,
      decoration: _inputDeco(
        hint: 'votre@email.com',
        prefixIcon: Icons.email_outlined,
      ),
      style: GoogleFonts.inter(fontSize: 14.5),
      validator: (v) {
        if (v == null || v.trim().isEmpty) return 'Email requis.';
        if (!v.contains('@')) return 'Email invalide.';
        return null;
      },
    );
  }

  Widget _buildMdpField() {
    return TextFormField(
      controller: _mdpCtrl,
      obscureText: !_showMdp,
      decoration: _inputDeco(
        hint: '••••••••',
        prefixIcon: Icons.lock_outline,
        suffix: IconButton(
          icon: Icon(
            _showMdp ? Icons.visibility_off_outlined : Icons.visibility_outlined,
            size: 20,
            color: SauveColors.gris,
          ),
          onPressed: () => setState(() => _showMdp = !_showMdp),
        ),
      ),
      style: GoogleFonts.inter(fontSize: 14.5),
      validator: (v) {
        if (v == null || v.isEmpty) return 'Mot de passe requis.';
        return null;
      },
    );
  }
}

// =====================================================================
// Formulaire d'inscription
// =====================================================================
class _InscriptionForm extends StatefulWidget {
  final void Function(String email) onSuccess;
  final VoidCallback onConnexion;
  final VoidCallback onRetour;

  const _InscriptionForm({
    super.key,
    required this.onSuccess,
    required this.onConnexion,
    required this.onRetour,
  });

  @override
  State<_InscriptionForm> createState() => _InscriptionFormState();
}

class _InscriptionFormState extends State<_InscriptionForm> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _mdpCtrl = TextEditingController();
  final _mdpConfirmCtrl = TextEditingController();
  bool _loading = false;
  bool _showMdp = false;
  bool _showMdpConfirm = false;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _mdpCtrl.dispose();
    _mdpConfirmCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 20),
            _buildHeader('Créer un compte', widget.onRetour),
            const SizedBox(height: 8),
            Text(
              'Créez votre compte SONGRE pour accéder à la plateforme.',
              style:
                  GoogleFonts.inter(fontSize: 13, color: SauveColors.gris),
            ),
            const SizedBox(height: 28),
            _label('Email'),
            const SizedBox(height: 8),
            TextFormField(
              controller: _emailCtrl,
              keyboardType: TextInputType.emailAddress,
              decoration: _inputDeco(
                hint: 'votre@email.com',
                prefixIcon: Icons.email_outlined,
              ),
              style: GoogleFonts.inter(fontSize: 14.5),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return 'Email requis.';
                if (!v.contains('@') || !v.contains('.')) {
                  return 'Email invalide.';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            _label('Mot de passe'),
            const SizedBox(height: 8),
            TextFormField(
              controller: _mdpCtrl,
              obscureText: !_showMdp,
              decoration: _inputDeco(
                hint: 'Minimum 8 caractères',
                prefixIcon: Icons.lock_outline,
                suffix: IconButton(
                  icon: Icon(
                    _showMdp
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 20,
                    color: SauveColors.gris,
                  ),
                  onPressed: () =>
                      setState(() => _showMdp = !_showMdp),
                ),
              ),
              style: GoogleFonts.inter(fontSize: 14.5),
              validator: (v) {
                if (v == null || v.length < 8) {
                  return 'Minimum 8 caractères.';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            _label('Confirmer le mot de passe'),
            const SizedBox(height: 8),
            TextFormField(
              controller: _mdpConfirmCtrl,
              obscureText: !_showMdpConfirm,
              decoration: _inputDeco(
                hint: 'Répétez votre mot de passe',
                prefixIcon: Icons.lock_outline,
                suffix: IconButton(
                  icon: Icon(
                    _showMdpConfirm
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 20,
                    color: SauveColors.gris,
                  ),
                  onPressed: () =>
                      setState(() => _showMdpConfirm = !_showMdpConfirm),
                ),
              ),
              style: GoogleFonts.inter(fontSize: 14.5),
              validator: (v) {
                if (v != _mdpCtrl.text) {
                  return 'Les mots de passe ne correspondent pas.';
                }
                return null;
              },
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _loading ? null : _inscrire,
                style: ElevatedButton.styleFrom(
                  backgroundColor: SauveColors.rouge,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 17),
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
                        'Créer mon compte',
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
                onTap: widget.onConnexion,
                child: Text.rich(
                  TextSpan(
                    text: 'Déjà un compte ? ',
                    style: GoogleFonts.inter(
                        fontSize: 13.5, color: SauveColors.gris),
                    children: [
                      TextSpan(
                        text: 'Se connecter',
                        style: GoogleFonts.inter(
                          fontSize: 13.5,
                          color: SauveColors.rouge,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
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

  Future<void> _inscrire() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);

    final state = context.read<AppState>();
    final ok = await state.inscrire(
      email: _emailCtrl.text.trim(),
      motDePasse: _mdpCtrl.text,
    );

    if (!mounted) return;
    setState(() => _loading = false);

    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            state.authError ?? 'Inscription impossible. Réessayez.',
            style: GoogleFonts.inter(fontSize: 13),
          ),
          backgroundColor: SauveColors.rouge,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          duration: const Duration(seconds: 5),
        ),
      );
      return;
    }

    // Succès → étape profil donneur
    widget.onSuccess(_emailCtrl.text.trim());
  }
}

// =====================================================================
// Formulaire de création de profil donneur (après inscription)
// =====================================================================
class _ProfilForm extends StatefulWidget {
  final String email;
  final VoidCallback onRetour;

  const _ProfilForm({super.key, required this.email, required this.onRetour});

  @override
  State<_ProfilForm> createState() => _ProfilFormState();
}

class _ProfilFormState extends State<_ProfilForm> {
  final _formKey = GlobalKey<FormState>();
  GroupeSanguin _groupe = GroupeSanguin.oplus;
  Genre _genre = Genre.homme;
  int _poids = 70;
  // Ville : chargée depuis la DB (int ID + nom pour affichage)
  Ville? _villeSelectionnee;
  List<Ville> _villes = [];
  bool _villesLoading = true;
  String _quartier = '';
  final List<String> _contreIndications = [];
  bool _consentement = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _chargerVilles());
  }

  Future<void> _chargerVilles() async {
    // Priorité : cache AppState
    final appState = context.read<AppState>();
    List<Ville> villes = appState.villes;
    if (villes.isEmpty) {
      try {
        villes = await SupabaseService.lireVilles();
      } catch (_) {
        // Si la DB est inaccessible, on laisse _villes vide — la
        // validation de _valider() renverra une erreur explicite.
        if (mounted) setState(() => _villesLoading = false);
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      _villes = villes;
      _villesLoading = false;
      if (_villes.isNotEmpty) _villeSelectionnee = _villes.first;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 20),
            _buildHeader('Mon profil donneur', widget.onRetour),
            const SizedBox(height: 8),
            Text(
              'Ces informations restent strictement confidentielles et ne seront jamais partagées.',
              style:
                  GoogleFonts.inter(fontSize: 13, color: SauveColors.gris),
            ),
            const SizedBox(height: 24),
            _label('Groupe sanguin'),
            const SizedBox(height: 8),
            _buildGroupeSelector(),
            const SizedBox(height: 20),
            _label('Genre (calcul espacement entre dons)'),
            const SizedBox(height: 8),
            _buildGenreSelector(),
            const SizedBox(height: 20),
            _label('Poids (kg)'),
            const SizedBox(height: 8),
            _buildPoidsField(),
            const SizedBox(height: 20),
            _label('Ville'),
            const SizedBox(height: 8),
            _buildVilleSelector(),
            const SizedBox(height: 20),
            _label('Quartier (optionnel)'),
            const SizedBox(height: 8),
            TextFormField(
              decoration: _inputDeco(hint: 'Ex : Secteur 15, Pissy...'),
              style: GoogleFonts.inter(fontSize: 14.5),
              onChanged: (v) => _quartier = v,
            ),
            const SizedBox(height: 20),
            _label('Contre-indications (cochez si applicable)'),
            const SizedBox(height: 8),
            _buildContreIndications(),
            const SizedBox(height: 20),
            _buildConsentement(),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _loading ? null : _valider,
                style: ElevatedButton.styleFrom(
                  backgroundColor: SauveColors.rouge,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 17),
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
                        'Créer mon profil',
                        style: GoogleFonts.archivo(
                          fontSize: 15,
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

  Widget _buildGroupeSelector() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: GroupeSanguin.values.map((g) {
        final selected = _groupe == g;
        return GestureDetector(
          onTap: () => setState(() => _groupe = g),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: selected ? SauveColors.rouge : SauveColors.carte,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected
                    ? SauveColors.rouge
                    : SauveColors.grisClair,
                width: 1.5,
              ),
            ),
            child: Text(
              g.label,
              style: GoogleFonts.archivo(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: selected ? Colors.white : SauveColors.encre,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildGenreSelector() {
    return Row(
      children: Genre.values.map((g) {
        final selected = _genre == g;
        return Expanded(
          child: GestureDetector(
            onTap: () => setState(() => _genre = g),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin:
                  EdgeInsets.only(right: g == Genre.homme ? 8 : 0),
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: selected
                    ? SauveColors.rouge
                    : SauveColors.carte,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected
                      ? SauveColors.rouge
                      : SauveColors.grisClair,
                  width: 1.5,
                ),
              ),
              child: Text(
                g == Genre.homme ? 'Homme' : 'Femme',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : SauveColors.encre,
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildPoidsField() {
    return Row(
      children: [
        Expanded(
          child: TextFormField(
            initialValue: _poids.toString(),
            keyboardType: TextInputType.number,
            decoration: _inputDeco(hint: '70', suffix: const Text('kg')),
            style: GoogleFonts.inter(fontSize: 14.5),
            validator: (v) {
              final val = int.tryParse(v ?? '');
              if (val == null || val < 50 || val > 150) {
                return 'Poids valide requis (50-150 kg)';
              }
              return null;
            },
            onChanged: (v) => _poids = int.tryParse(v) ?? _poids,
          ),
        ),
        const SizedBox(width: 12),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: SauveColors.vertFond,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '≥ 50 kg requis',
            style: GoogleFonts.inter(
              fontSize: 12,
              color: SauveColors.vert,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildVilleSelector() {
    if (_villesLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: CircularProgressIndicator(
              strokeWidth: 2, color: SauveColors.rouge),
        ),
      );
    }
    if (_villes.isEmpty) {
      return Text(
        'Impossible de charger les villes. Vérifiez votre connexion.',
        style: GoogleFonts.inter(fontSize: 12, color: SauveColors.rouge),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: SauveColors.carte,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SauveColors.grisClair, width: 1.5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<Ville>(
          value: _villeSelectionnee,
          isExpanded: true,
          style: GoogleFonts.inter(fontSize: 14.5, color: SauveColors.encre),
          items: _villes
              .map((v) => DropdownMenuItem<Ville>(
                    value: v,
                    child: Text(v.nom),
                  ))
              .toList(),
          onChanged: (v) => setState(() => _villeSelectionnee = v),
        ),
      ),
    );
  }

  Widget _buildContreIndications() {
    return Container(
      decoration: BoxDecoration(
        color: SauveColors.carte,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SauveColors.grisClair),
      ),
      child: Column(
        children: contreIndicationsDisponibles.map((ci) {
          final checked = _contreIndications.contains(ci);
          return CheckboxListTile(
            value: checked,
            onChanged: (v) {
              setState(() {
                if (v == true) {
                  _contreIndications.add(ci);
                } else {
                  _contreIndications.remove(ci);
                }
              });
            },
            title: Text(
              ci,
              style: GoogleFonts.inter(
                  fontSize: 13, color: SauveColors.encre),
            ),
            activeColor: SauveColors.rouge,
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 8),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildConsentement() {
    return GestureDetector(
      onTap: () => setState(() => _consentement = !_consentement),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(
            value: _consentement,
            onChanged: (v) =>
                setState(() => _consentement = v ?? false),
            activeColor: SauveColors.rouge,
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'J\'accepte que mes données de santé soient utilisées uniquement pour faciliter le don de sang, en conformité avec la loi burkinabè n°010-2004/AN sur la protection des données personnelles.',
                style: GoogleFonts.inter(
                  fontSize: 12.5,
                  color: SauveColors.gris,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _valider() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_consentement) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Veuillez accepter les conditions d\'utilisation.',
            style: GoogleFonts.inter(fontSize: 13),
          ),
          backgroundColor: SauveColors.rouge,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }

    setState(() => _loading = true);
    final state = context.read<AppState>();

    // Résoudre l'userId : AppState est prioritaire, fallback SupabaseService
    // Cas typique : inscription sans confirmation email → session immédiate
    // Cas rare    : inscription avec confirmation email → userId peut être null
    final userId = state.userId ?? SupabaseService.currentUserId;
    if (userId == null) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Session expirée. Veuillez vous reconnecter ou recommencer l\'inscription.',
              style: GoogleFonts.inter(fontSize: 13),
            ),
            backgroundColor: SauveColors.rouge,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            duration: const Duration(seconds: 6),
          ),
        );
      }
      return;
    }

    // Vérifier qu'une ville a été sélectionnée
    if (_villeSelectionnee == null) {
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Veuillez sélectionner votre ville.',
            style: GoogleFonts.inter(fontSize: 13),
          ),
          backgroundColor: SauveColors.rouge,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }

    final profil = ProfilDonneur(
      userId: userId,
      groupeSanguin: _groupe,
      poids: _poids,
      genre: _genre,
      villeId: _villeSelectionnee!.id,
      villeNom: _villeSelectionnee!.nom,
      quartier: _quartier.isNotEmpty ? _quartier : null,
      contreIndications: _contreIndications,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    await state.sauvegarderProfil(profil);

    // [P7] Enregistrer le consentement dans public.consentements.
    // Appel fire-and-forget : une erreur réseau ici ne bloque pas la création
    // du profil (le consentement sera tenté à nouveau à la prochaine occasion).
    // La version '1.0' correspond à la politique de confidentialité initiale.
    unawaited(SupabaseService.enregistrerConsentement(
      userId: userId,
      consentementSante: _consentement,
      consentementGeoloc: false, // Géolocalisation non implémentée pour l'instant
      versionPolitique: '1.0',
    ));

    // GoRouter redirect voit isAuthenticated=true + profil!=null → navigue vers /home
    // L'appel explicite à context.go('/home') est maintenu comme fallback de sécurité
    // au cas où le redirect GoRouter ne se déclencherait pas immédiatement.
    if (mounted) {
      setState(() => _loading = false);
      context.go('/home');
    }
  }
}

// =====================================================================
// Formulaire mot de passe oublié — Réinitialisation par email
// =====================================================================
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

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 20),
            _buildHeader('Mot de passe oublié', widget.onRetour),
            const SizedBox(height: 8),

            ...[
              // ── Formulaire saisie email ──────────────────────────
              Text(
                'Saisissez votre adresse email. Nous vous enverrons un code à 6 chiffres pour réinitialiser votre mot de passe.',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: SauveColors.gris,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 28),
              Text(
                'Email',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: SauveColors.encre,
                ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: _inputDeco(
                  hint: 'votre@email.com',
                  prefixIcon: Icons.email_outlined,
                ),
                style: GoogleFonts.inter(fontSize: 14.5),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Email requis.';
                  if (!v.contains('@') || !v.contains('.')) {
                    return 'Email invalide.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _loading ? null : _envoyerEmail,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: SauveColors.rouge,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 17),
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
                  onTap: widget.onRetour,
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
              const SizedBox(height: 40),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _envoyerEmail() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);

    final email = _emailCtrl.text.trim();
    final result = await SupabaseService.envoyerEmailReinitialisation(email);

    if (!mounted) return;
    setState(() => _loading = false);

    if (result.success) {
      // Supabase retourne 200 même si l'email n'existe pas (sécurité anti-enum).
      // On redirige toujours vers l'écran de saisie du code OTP.
      context.push('/reset-password', extra: email);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.error ?? 'Impossible d\'envoyer l\'email. Réessayez.',
            style: GoogleFonts.inter(fontSize: 13),
          ),
          backgroundColor: SauveColors.rouge,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }
}

// =====================================================================
// Helpers partagés
// =====================================================================
Widget _buildHeader(String title, VoidCallback onRetour) {
  return Builder(builder: (context) {
    return Row(
      children: [
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
        const SizedBox(width: 12),
        Text(
          title,
          style: GoogleFonts.archivo(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: SauveColors.encre,
          ),
        ),
      ],
    );
  });
}

Widget _label(String text) => Text(
      text.toUpperCase(),
      style: GoogleFonts.inter(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        color: SauveColors.gris,
        letterSpacing: 0.05,
      ),
    );

InputDecoration _inputDeco({
  required String hint,
  IconData? prefixIcon,
  Widget? suffix,
}) {
  return InputDecoration(
    hintText: hint,
    hintStyle: GoogleFonts.inter(fontSize: 14.5, color: SauveColors.gris),
    prefixIcon:
        prefixIcon != null ? Icon(prefixIcon, size: 20, color: SauveColors.gris) : null,
    suffixIcon: suffix,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide:
          const BorderSide(color: SauveColors.grisClair, width: 1.5),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide:
          const BorderSide(color: SauveColors.grisClair, width: 1.5),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: SauveColors.rouge, width: 1.5),
    ),
    errorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: SauveColors.rouge, width: 1.5),
    ),
    filled: true,
    fillColor: SauveColors.carte,
    contentPadding: const EdgeInsets.all(14),
  );
}
