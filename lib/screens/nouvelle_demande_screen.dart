import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../theme/sauve_theme.dart';
import '../services/app_state.dart';
import '../models/models.dart';

// =====================================================================
// ÉCRAN 3 — Créer une demande de sang
// §4.1 — Contact principal OBLIGATOIRE + contact secondaire OPTIONNEL
//          Les deux sont transmis chiffrés (AES-256) via AppState
// =====================================================================
class NouvelleDemande extends StatefulWidget {
  const NouvelleDemande({super.key});

  @override
  State<NouvelleDemande> createState() => _NouvelleDemandeState();
}

class _NouvelleDemandeState extends State<NouvelleDemande> {
  final _formKey = GlobalKey<FormState>();
  GroupeSanguin _groupe = GroupeSanguin.oplus;
  String _ville = 'Ouagadougou';
  String? _structure;

  // §4.1 — deux contrôleurs de contact
  final _contactCtrl    = TextEditingController(); // principal — obligatoire
  final _contact2Ctrl   = TextEditingController(); // secondaire — optionnel

  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _structure = villesEtStructures[_ville]?.first;
  }

  @override
  void dispose() {
    _contactCtrl.dispose();
    _contact2Ctrl.dispose();
    super.dispose();
  }

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

                      // ── Ville ────────────────────────────────────
                      _label('Ville'),
                      const SizedBox(height: 8),
                      _buildDropdown(
                        value: _ville,
                        items: villesEtStructures.keys.toList(),
                        onChanged: (v) {
                          setState(() {
                            _ville = v!;
                            _structure = villesEtStructures[_ville]?.first;
                          });
                        },
                      ),
                      const SizedBox(height: 20),

                      // ── Structure sanitaire ──────────────────────
                      _label('Structure sanitaire'),
                      const SizedBox(height: 8),
                      _buildDropdown(
                        value: _structure,
                        items: villesEtStructures[_ville] ?? [],
                        onChanged: (v) => setState(() => _structure = v),
                      ),
                      const SizedBox(height: 20),

                      // ── Contact principal — OBLIGATOIRE (§4.1) ──
                      _label('Numéro de contact *'),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _contactCtrl,
                        keyboardType: TextInputType.phone,
                        decoration: InputDecoration(
                          hintText: 'Ex : +226 70 00 00 00',
                          hintStyle: GoogleFonts.inter(
                              fontSize: 14.5, color: SauveColors.gris),
                          prefixIcon: const Icon(Icons.phone_outlined,
                              color: SauveColors.rouge, size: 20),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                                color: SauveColors.grisClair, width: 1.5),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                                color: SauveColors.grisClair, width: 1.5),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                                color: SauveColors.rouge, width: 1.5),
                          ),
                          errorBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                                color: SauveColors.rouge, width: 1.5),
                          ),
                          filled: true,
                          fillColor: SauveColors.carte,
                          contentPadding: const EdgeInsets.all(14),
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
                      // Note sécurité chiffrement
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
                        decoration: InputDecoration(
                          hintText: 'Second numéro joignable',
                          hintStyle: GoogleFonts.inter(
                              fontSize: 14.5, color: SauveColors.gris),
                          prefixIcon: const Icon(Icons.phone_forwarded_outlined,
                              color: SauveColors.gris, size: 20),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                                color: SauveColors.grisClair, width: 1.5),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                                color: SauveColors.grisClair, width: 1.5),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                                color: SauveColors.rouge, width: 1.5),
                          ),
                          filled: true,
                          fillColor: SauveColors.carte,
                          contentPadding: const EdgeInsets.all(14),
                        ),
                        style: GoogleFonts.inter(fontSize: 14.5),
                        // Validation douce : si rempli, doit être valide
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return null; // optionnel
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
                          'La demande expire automatiquement après 72h',
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

  Widget _buildDropdown({
    required String? value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: SauveColors.carte,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SauveColors.grisClair, width: 1.5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          style:
              GoogleFonts.inter(fontSize: 14.5, color: SauveColors.encre),
          items: items
              .map((v) => DropdownMenuItem(value: v, child: Text(v)))
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  // ── Action publier ────────────────────────────────────────────────

  Future<void> _publier() async {
    // Validation du formulaire (contact principal requis)
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_structure == null) return;

    setState(() => _loading = true);

    final state = context.read<AppState>();

    // §4.1 — contact principal obligatoire, secondaire optionnel
    final contactSecondaire = _contact2Ctrl.text.trim().isNotEmpty
        ? _contact2Ctrl.text.trim()
        : null;

    final result = await state.publierDemande(
      groupeSanguin: _groupe,
      ville: _ville,
      structureSanitaire: _structure!,
      contactPrincipal: _contactCtrl.text.trim(),   // obligatoire
      contactSecondaire: contactSecondaire,          // optionnel
    );

    if (!mounted) return;
    setState(() => _loading = false);

    if (result.success) {
      // Succès
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle_outline,
                  color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Text(
                'Demande publiée avec succès.',
                style: GoogleFonts.inter(
                    fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ],
          ),
          backgroundColor: SauveColors.vert,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          duration: const Duration(seconds: 3),
        ),
      );
      context.pop();
    } else {
      // Échec — afficher le message d'erreur du backend
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
                  style: GoogleFonts.inter(
                      fontSize: 13, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          backgroundColor: SauveColors.rouge,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }
}
