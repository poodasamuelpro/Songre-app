import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../theme/sauve_theme.dart';
import '../services/app_state.dart';
import '../services/supabase_service.dart';
import '../models/models.dart';

// =====================================================================
// ÉCRAN 3 — Créer une demande de sang
// §4.1 — Contact principal OBLIGATOIRE + contact secondaire OPTIONNEL
//          Les deux sont transmis chiffrés (AES-256) via AppState
//
// T10 — Correction production :
//   - Charge les villes depuis la DB (SupabaseService.lireVilles)
//   - Charge les structures dynamiquement (SupabaseService.lireStructures)
//   - Soumet villeId (int) + structureId (int) — plus de chaînes hardcodées
//   - Supporte villeLibre / structureLibre comme fallback si hors liste
//   - Appel publierDemande() avec la nouvelle signature (int IDs)
//   - Affiche la durée de validité depuis kDureeValiditeDemandeLabel
// =====================================================================

class NouvelleDemande extends StatefulWidget {
  const NouvelleDemande({super.key});

  @override
  State<NouvelleDemande> createState() => _NouvelleDemandeState();
}

class _NouvelleDemandeState extends State<NouvelleDemande> {
  final _formKey = GlobalKey<FormState>();
  GroupeSanguin _groupe = GroupeSanguin.oplus;

  // ── Sélection de ville (depuis DB) ───────────────────────────────────
  Ville? _villeSelectionnee;
  List<Ville> _villes = [];
  bool _villesLoading = true;
  String? _villesErreur;

  // ── Sélection de structure (depuis DB, dépendante de la ville) ───────
  StructureSanitaire? _structureSelectionnee;
  List<StructureSanitaire> _structures = [];
  bool _structuresLoading = false;

  // ── Champs "libre" (hors liste officielle) ───────────────────────────
  // Activés si l'utilisateur choisit "Autre ville" ou "Autre structure"
  final TextEditingController _villeLibreCtrl = TextEditingController();
  final TextEditingController _structureLibreCtrl = TextEditingController();
  bool _villeEstLibre = false;     // true → villeLibre active, villeId = null
  bool _structureEstLibre = false; // true → structureLibre active, structureId = null

  // ── Contacts (§4.1) ──────────────────────────────────────────────────
  final _contactCtrl  = TextEditingController(); // principal — obligatoire
  final _contact2Ctrl = TextEditingController(); // secondaire — optionnel

  bool _loading = false;

  @override
  void initState() {
    super.initState();
    // Charger les villes au démarrage (depuis AppState si déjà en cache,
    // sinon depuis la DB via SupabaseService directement)
    WidgetsBinding.instance.addPostFrameCallback((_) => _chargerVilles());
  }

  @override
  void dispose() {
    _contactCtrl.dispose();
    _contact2Ctrl.dispose();
    _villeLibreCtrl.dispose();
    _structureLibreCtrl.dispose();
    super.dispose();
  }

  // ── Chargement des villes ────────────────────────────────────────────

  Future<void> _chargerVilles() async {
    // Priorité : cache AppState (déjà chargé au démarrage de l'app)
    final appState = context.read<AppState>();
    List<Ville> villes = appState.villes;

    if (villes.isEmpty) {
      // Fallback : charger depuis la DB directement
      try {
        villes = await SupabaseService.lireVilles();
      } catch (e) {
        if (mounted) {
          setState(() {
            _villesLoading = false;
            _villesErreur = 'Impossible de charger les villes.';
          });
        }
        return;
      }
    }

    if (!mounted) return;
    setState(() {
      _villes = villes;
      _villesLoading = false;
      _villesErreur = null;
      // Pré-sélectionner la première ville disponible
      if (_villes.isNotEmpty && _villeSelectionnee == null) {
        _villeSelectionnee = _villes.first;
        _chargerStructures(_villes.first.id);
      }
    });
  }

  // ── Chargement des structures pour une ville donnée ──────────────────

  Future<void> _chargerStructures(int villeId) async {
    setState(() {
      _structuresLoading = true;
      _structureSelectionnee = null;
      _structures = [];
      _structureEstLibre = false;
    });

    try {
      final structures = await SupabaseService.lireStructures(villeId);
      if (!mounted) return;
      setState(() {
        _structures = structures;
        _structuresLoading = false;
        if (structures.isNotEmpty) {
          // Pré-sélectionner la première structure disponible
          _structureSelectionnee = structures.first;
          _structureEstLibre = false;
        } else {
          // [Fix #2] Aucune structure dans la DB pour cette ville →
          // activer le mode saisie libre pour ne pas bloquer l'utilisateur
          _structureSelectionnee = null;
          _structureEstLibre = true;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _structuresLoading = false;
        // Forcer le mode "libre" si aucune structure n'a pu être chargée
        _structureEstLibre = true;
      });
    }
  }

  // ── Action publier ───────────────────────────────────────────────────

  Future<void> _publier() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    // Vérifier qu'une ville est spécifiée (id OU libre)
    final bool villeOk = _villeEstLibre
        ? _villeLibreCtrl.text.trim().isNotEmpty
        : _villeSelectionnee != null;

    // Vérifier qu'une structure est spécifiée (id OU libre)
    final bool structureOk = _structureEstLibre
        ? _structureLibreCtrl.text.trim().isNotEmpty
        : _structureSelectionnee != null;

    if (!villeOk) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Veuillez sélectionner ou saisir une ville.',
              style: GoogleFonts.inter(fontSize: 13)),
          backgroundColor: SauveColors.rouge,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }

    if (!structureOk) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Veuillez sélectionner ou saisir une structure sanitaire.',
              style: GoogleFonts.inter(fontSize: 13)),
          backgroundColor: SauveColors.rouge,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }

    setState(() => _loading = true);

    final state = context.read<AppState>();

    final contactSecondaire = _contact2Ctrl.text.trim().isNotEmpty
        ? _contact2Ctrl.text.trim()
        : null;

    // ── Appel publierDemande avec la nouvelle signature (int IDs) ─────
    final result = await state.publierDemande(
      groupeSanguin: _groupe,
      villeId: _villeEstLibre ? null : _villeSelectionnee?.id,
      structureId: _structureEstLibre ? null : _structureSelectionnee?.id,
      villeLibre: _villeEstLibre ? _villeLibreCtrl.text.trim() : null,
      structureLibre: _structureEstLibre ? _structureLibreCtrl.text.trim() : null,
      contactPrincipal: _contactCtrl.text.trim(),
      contactSecondaire: contactSecondaire,
    );

    if (!mounted) return;
    setState(() => _loading = false);

    if (result.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle_outline, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Text(
                'Demande publiée avec succès.',
                style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ],
          ),
          backgroundColor: SauveColors.vert,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          duration: const Duration(seconds: 3),
        ),
      );
      context.pop();
    } else {
      final errMsg = result.error ?? 'Impossible de publier la demande.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  errMsg,
                  style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          backgroundColor: SauveColors.rouge,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  // ── Build principal ──────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SauveColors.creme,
      body: SafeArea(
        child: Column(
          children: [
            // ── Top bar ──────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Row(
                children: [
                  _buildBackBtn(context),
                  Expanded(
                    child: Center(
                      child: Text(
                        'Nouvelle demande',
                        style: GoogleFonts.archivo(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: SauveColors.encre,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 36),
                ],
              ),
            ),

            // ── Formulaire ───────────────────────────────────────────
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 8),

                      // Info anonymat
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: SauveColors.vertFond,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.info_outline,
                                color: SauveColors.vert, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Votre identité reste anonyme. Seul le groupe sanguin, '
                                'la ville et la structure sont visibles publiquement.',
                                style: GoogleFonts.inter(
                                    fontSize: 12, color: SauveColors.vert),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 22),

                      // ── Groupe sanguin ───────────────────────────
                      _label('Groupe sanguin recherché'),
                      const SizedBox(height: 10),
                      _buildGroupeSelector(),
                      const SizedBox(height: 22),

                      // ── Ville (depuis DB) ─────────────────────────
                      _label('Ville'),
                      const SizedBox(height: 8),
                      _buildVilleSelector(),
                      const SizedBox(height: 20),

                      // ── Structure sanitaire (depuis DB) ───────────
                      _label('Structure sanitaire'),
                      const SizedBox(height: 8),
                      _buildStructureSelector(),
                      const SizedBox(height: 20),

                      // ── Contact principal — OBLIGATOIRE (§4.1) ──
                      _label('Numéro de contact *'),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _contactCtrl,
                        keyboardType: TextInputType.phone,
                        decoration: _inputDeco(
                          hint: 'Ex : +226 70 00 00 00',
                          prefixIcon: const Icon(Icons.phone_outlined,
                              color: SauveColors.rouge, size: 20),
                        ),
                        style: GoogleFonts.inter(fontSize: 14.5),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) {
                            return 'Le numéro de contact est obligatoire.';
                          }
                          final digits = v.replaceAll(RegExp(r'[^0-9]'), '');
                          if (digits.length < 8) {
                            return 'Numéro invalide (minimum 8 chiffres).';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Icon(Icons.lock_outline,
                              size: 12, color: SauveColors.vert),
                          const SizedBox(width: 4),
                          Text(
                            'Chiffré AES-256 — visible uniquement par les donneurs qui répondent.',
                            style: GoogleFonts.inter(
                                fontSize: 11.5, color: SauveColors.vert),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),

                      // ── Contact secondaire — OPTIONNEL (§4.1) ───
                      _label('Numéro de secours (optionnel)'),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _contact2Ctrl,
                        keyboardType: TextInputType.phone,
                        decoration: _inputDeco(
                          hint: 'Second numéro joignable',
                          prefixIcon: const Icon(Icons.phone_forwarded_outlined,
                              color: SauveColors.gris, size: 20),
                        ),
                        style: GoogleFonts.inter(fontSize: 14.5),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return null;
                          final digits = v.replaceAll(RegExp(r'[^0-9]'), '');
                          if (digits.length < 8) {
                            return 'Numéro invalide (minimum 8 chiffres).';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Laissez vide si vous n\'avez qu\'un seul numéro.',
                        style: GoogleFonts.inter(
                            fontSize: 12, color: SauveColors.gris),
                      ),
                      const SizedBox(height: 28),

                      // ── Bouton publier ───────────────────────────
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _loading ? null : _publier,
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
                                  'Publier la demande',
                                  style: GoogleFonts.archivo(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Center(
                        child: Text(
                          'La demande expire automatiquement après $kDureeValiditeDemandeLabel',
                          style: GoogleFonts.inter(
                              fontSize: 12, color: SauveColors.gris),
                        ),
                      ),
                      const SizedBox(height: 40),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Widget : sélecteur de ville ──────────────────────────────────────

  Widget _buildVilleSelector() {
    if (_villesLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: SauveColors.rouge,
          ),
        ),
      );
    }

    if (_villesErreur != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _villesErreur!,
            style: GoogleFonts.inter(fontSize: 12, color: SauveColors.rouge),
          ),
          const SizedBox(height: 8),
          _buildChampsLibre(
            controller: _villeLibreCtrl,
            hint: 'Saisir le nom de votre ville',
            label: 'Ville',
          ),
        ],
      );
    }

    // Mode "ville libre" activé
    if (_villeEstLibre) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildChampsLibre(
            controller: _villeLibreCtrl,
            hint: 'Saisir le nom de votre ville',
            label: 'Ville non répertoriée',
          ),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () {
              setState(() {
                _villeEstLibre = false;
                _villeLibreCtrl.clear();
                if (_villes.isNotEmpty) {
                  _villeSelectionnee = _villes.first;
                  _chargerStructures(_villes.first.id);
                }
              });
            },
            child: Text(
              '← Choisir dans la liste',
              style: GoogleFonts.inter(
                fontSize: 12,
                color: SauveColors.rouge,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ],
      );
    }

    // Mode normal : dropdown des villes DB
    final items = [
      ..._villes.map((v) => DropdownMenuItem<Ville>(
            value: v,
            child: Text(v.nom, style: GoogleFonts.inter(fontSize: 14.5)),
          )),
      DropdownMenuItem<Ville>(
        value: null,
        child: Text(
          'Autre ville...',
          style: GoogleFonts.inter(
              fontSize: 14.5,
              color: SauveColors.rouge,
              fontStyle: FontStyle.italic),
        ),
      ),
    ];

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
          items: items,
          onChanged: (v) {
            if (v == null) {
              // "Autre ville..." → mode libre
              setState(() {
                _villeEstLibre = true;
                _villeSelectionnee = null;
                _structures = [];
                _structureSelectionnee = null;
              });
            } else {
              setState(() {
                _villeSelectionnee = v;
                _villeEstLibre = false;
              });
              _chargerStructures(v.id);
            }
          },
        ),
      ),
    );
  }

  // ── Widget : sélecteur de structure ─────────────────────────────────

  Widget _buildStructureSelector() {
    // En mode "ville libre", on force aussi la structure libre
    if (_villeEstLibre) {
      return _buildChampsLibre(
        controller: _structureLibreCtrl,
        hint: 'Nom de la structure sanitaire',
        label: 'Structure',
      );
    }

    if (_structuresLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: SauveColors.rouge,
          ),
        ),
      );
    }

    // Mode "structure libre" activé
    if (_structureEstLibre) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildChampsLibre(
            controller: _structureLibreCtrl,
            hint: 'Nom de la structure sanitaire',
            label: 'Structure non répertoriée',
          ),
          const SizedBox(height: 8),
          if (_structures.isNotEmpty)
            GestureDetector(
              onTap: () {
                setState(() {
                  _structureEstLibre = false;
                  _structureLibreCtrl.clear();
                  _structureSelectionnee =
                      _structures.isNotEmpty ? _structures.first : null;
                });
              },
              child: Text(
                '← Choisir dans la liste',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: SauveColors.rouge,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
        ],
      );
    }

    if (_structures.isEmpty) {
      // Aucune structure connue pour cette ville → forcer le mode libre
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Aucune structure répertoriée pour cette ville.',
            style: GoogleFonts.inter(fontSize: 12, color: SauveColors.gris),
          ),
          const SizedBox(height: 8),
          _buildChampsLibre(
            controller: _structureLibreCtrl,
            hint: 'Nom de la structure sanitaire',
            label: 'Structure',
          ),
        ],
      );
    }

    // Mode normal : dropdown des structures DB
    final items = [
      ..._structures.map((s) => DropdownMenuItem<StructureSanitaire>(
            value: s,
            child: Text(s.nom,
                style: GoogleFonts.inter(fontSize: 14.5),
                overflow: TextOverflow.ellipsis),
          )),
      DropdownMenuItem<StructureSanitaire>(
        value: null,
        child: Text(
          'Autre structure...',
          style: GoogleFonts.inter(
              fontSize: 14.5,
              color: SauveColors.rouge,
              fontStyle: FontStyle.italic),
        ),
      ),
    ];

    return Container(
      decoration: BoxDecoration(
        color: SauveColors.carte,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SauveColors.grisClair, width: 1.5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<StructureSanitaire>(
          value: _structureSelectionnee,
          isExpanded: true,
          style: GoogleFonts.inter(fontSize: 14.5, color: SauveColors.encre),
          items: items,
          onChanged: (s) {
            if (s == null) {
              setState(() {
                _structureEstLibre = true;
                _structureSelectionnee = null;
              });
            } else {
              setState(() {
                _structureSelectionnee = s;
                _structureEstLibre = false;
              });
            }
          },
        ),
      ),
    );
  }

  // ── Champ texte libre (ville/structure hors liste) ───────────────────

  Widget _buildChampsLibre({
    required TextEditingController controller,
    required String hint,
    required String label,
  }) {
    return TextFormField(
      controller: controller,
      decoration: _inputDeco(hint: hint),
      style: GoogleFonts.inter(fontSize: 14.5),
      validator: (v) {
        if (v == null || v.trim().isEmpty) {
          return '$label est obligatoire.';
        }
        return null;
      },
    );
  }

  // ── Helpers UI ────────────────────────────────────────────────────

  Widget _label(String text) => Text(
        text.toUpperCase(),
        style: GoogleFonts.inter(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: SauveColors.gris,
          letterSpacing: 0.04,
        ),
      );

  InputDecoration _inputDeco({required String hint, Widget? prefixIcon}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: GoogleFonts.inter(fontSize: 14.5, color: SauveColors.gris),
      prefixIcon: prefixIcon,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: SauveColors.grisClair, width: 1.5),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: SauveColors.grisClair, width: 1.5),
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

  Widget _buildBackBtn(BuildContext context) {
    return GestureDetector(
      onTap: () => context.pop(),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: SauveColors.carte,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: SauveColors.grisClair),
        ),
        child:
            const Icon(Icons.arrow_back, size: 18, color: SauveColors.encre),
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
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: selected ? SauveColors.rouge : SauveColors.carte,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected ? SauveColors.rouge : SauveColors.grisClair,
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
}
