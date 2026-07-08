import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../theme/sauve_theme.dart';
import '../services/app_state.dart';
import '../models/models.dart';
import 'package:intl/intl.dart';

// =====================================================================
// ÉCRAN 5 — Profil donneur
// §4.2 — Suppression de compte J+5 avec double confirmation + annulation
// §4.3 — Bouton retour ajouté (top-left)
// =====================================================================
class ProfilScreen extends StatelessWidget {
  const ProfilScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final profil = state.profil;

    if (profil == null) {
      return const Scaffold(
        backgroundColor: SauveColors.creme,
        body: Center(
            child: CircularProgressIndicator(color: SauveColors.rouge)),
      );
    }

    return Scaffold(
      backgroundColor: SauveColors.creme,
      body: SafeArea(
        child: Column(
          children: [
            // ── Top bar ────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Row(
                children: [
                  // §4.3 — Bouton retour (pop vers l'onglet précédent si disponible)
                  GestureDetector(
                    onTap: () {
                      if (Navigator.of(context).canPop()) {
                        Navigator.of(context).pop();
                      }
                      // Sur l'onglet principal, le back n'a pas d'effet logique
                      // mais le bouton est présent conformément au §4.3
                    },
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
                  Expanded(
                    child: Center(
                      child: Text(
                        'Mon profil',
                        style: GoogleFonts.archivo(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: SauveColors.encre,
                        ),
                      ),
                    ),
                  ),
                  // Bouton paramètres
                  GestureDetector(
                    onTap: () => _showSettings(context, state),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: SauveColors.carte,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: SauveColors.grisClair),
                      ),
                      child: const Icon(
                        Icons.settings_outlined,
                        size: 18,
                        color: SauveColors.encre,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ── Contenu scrollable ─────────────────────────────────
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    const SizedBox(height: 8),

                    // Bannière suppression programmée (§4.2)
                    if (state.suppressionProgrammee &&
                        state.dateSuppression != null)
                      _buildBannereSuppression(context, state),

                    // Avatar anonyme
                    _buildAvatar(profil),
                    const SizedBox(height: 18),

                    // Toggle disponibilité
                    _buildToggleDisponibilite(context, state, profil),
                    const SizedBox(height: 4),

                    // Avertissement éligibilité
                    if (!profil.estEligible)
                      _buildEligibiliteWarning(profil),
                    const SizedBox(height: 8),

                    // Infos profil
                    _buildInfosSection(profil),
                    const SizedBox(height: 8),

                    // Bouton j'ai fait un don
                    _buildBtnDonDeclare(context, state),
                    const SizedBox(height: 12),

                    // Bouton modifier profil
                    _buildBtnModifier(context, profil),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Bannière suppression programmée ──────────────────────────────

  Widget _buildBannereSuppression(BuildContext context, AppState state) {
    final date = state.dateSuppression!;
    final joursRestants = date.difference(DateTime.now()).inDays.clamp(0, 5);
    final dateStr =
        DateFormat('d MMM yyyy', 'fr_FR').format(date);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF3CD),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFFFD966)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.warning_amber_rounded,
                    color: Color(0xFFB45309), size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Suppression programmée le $dateStr',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFFB45309),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Il vous reste $joursRestants jour${joursRestants > 1 ? 's' : ''} pour annuler. '
              'Votre compte est invisible des demandes pendant ce délai.',
              style: GoogleFonts.inter(
                fontSize: 12,
                color: const Color(0xFF92400E),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _annulerSuppression(context, state),
                icon: const Icon(Icons.undo,
                    size: 16, color: Color(0xFF059669)),
                label: Text(
                  'Annuler la suppression',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF059669),
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFF059669)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Avatar ────────────────────────────────────────────────────────

  Widget _buildAvatar(ProfilDonneur profil) {
    return Column(
      children: [
        Container(
          width: 74,
          height: 74,
          decoration: const BoxDecoration(
            color: SauveColors.rouge,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              profil.groupeSanguin.label,
              style: GoogleFonts.archivo(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Donneur #${profil.anonymeId}',
          style: GoogleFonts.archivo(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: SauveColors.encre,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          [profil.ville, if (profil.quartier != null) profil.quartier!]
              .join(' · '),
          style: GoogleFonts.inter(
            fontSize: 12.5,
            color: SauveColors.gris,
          ),
        ),
      ],
    );
  }

  // ── Toggle disponibilité ──────────────────────────────────────────

  Widget _buildToggleDisponibilite(
      BuildContext context, AppState state, ProfilDonneur profil) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: GestureDetector(
        onTap: () => state.toggleDisponibilite(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: profil.disponible
                ? SauveColors.vertFond
                : SauveColors.grisClair,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profil.disponible ? 'Disponible' : 'Indisponible',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: profil.disponible
                            ? SauveColors.vert
                            : SauveColors.gris,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      profil.disponible
                          ? 'Visible pour les demandes compatibles'
                          : 'Masqué des demandes',
                      style: GoogleFonts.inter(
                        fontSize: 11.5,
                        color: profil.disponible
                            ? const Color(0xFF4d8a72)
                            : SauveColors.gris,
                      ),
                    ),
                  ],
                ),
              ),
              // Switch visuel
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                width: 46,
                height: 26,
                decoration: BoxDecoration(
                  color:
                      profil.disponible ? SauveColors.vert : SauveColors.gris,
                  borderRadius: BorderRadius.circular(20),
                ),
                padding: const EdgeInsets.all(3),
                child: AnimatedAlign(
                  duration: const Duration(milliseconds: 250),
                  alignment: profil.disponible
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Éligibilité ───────────────────────────────────────────────────

  Widget _buildEligibiliteWarning(ProfilDonneur profil) {
    final prochainDon = profil.prochainDonDate;
    final dateStr = prochainDon != null
        ? DateFormat('d MMM yyyy', 'fr_FR').format(prochainDon)
        : '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF3CD),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFFFD966)),
        ),
        child: Row(
          children: [
            const Icon(Icons.hourglass_bottom_outlined,
                color: Color(0xFFB45309), size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Prochain don possible le $dateStr',
                style: GoogleFonts.inter(
                  fontSize: 12.5,
                  color: const Color(0xFFB45309),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Informations profil ───────────────────────────────────────────

  Widget _buildInfosSection(ProfilDonneur profil) {
    final dernierDon = profil.dernierDonDate != null
        ? _formatDate(profil.dernierDonDate!)
        : 'Aucun don enregistré';
    final prochainDon = profil.prochainDonDate != null
        ? _formatDate(profil.prochainDonDate!)
        : 'Dès maintenant';

    return Column(
      children: [
        _buildInfoRow('Groupe sanguin', profil.groupeSanguin.label),
        _buildInfoRow('Poids', '${profil.poids} kg'),
        _buildInfoRow(
            'Genre', profil.genre == Genre.homme ? 'Homme' : 'Femme'),
        _buildInfoRow('Ville', profil.ville),
        if (profil.quartier != null)
          _buildInfoRow('Quartier', profil.quartier!),
        _buildInfoRow('Dernier don', dernierDon),
        _buildInfoRow('Prochain don possible', prochainDon,
            highlight: profil.estEligible),
        if (profil.contreIndications.isNotEmpty)
          _buildInfoRow('Contre-indications',
              '${profil.contreIndications.length} signalée(s)'),
      ],
    );
  }

  Widget _buildInfoRow(String key, String value, {bool highlight = false}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: BoxDecoration(
          color: SauveColors.carte,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: SauveColors.grisClair),
        ),
        child: Row(
          children: [
            Text(
              key,
              style:
                  GoogleFonts.inter(fontSize: 13, color: SauveColors.gris),
            ),
            const Spacer(),
            Text(
              value,
              style: GoogleFonts.inter(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: highlight ? SauveColors.vert : SauveColors.encre,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Bouton don déclaratif ─────────────────────────────────────────

  Widget _buildBtnDonDeclare(BuildContext context, AppState state) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: GestureDetector(
        onTap: () => _showDonDeclaratif(context, state),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 15),
          decoration: BoxDecoration(
            color: SauveColors.carte,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: SauveColors.rouge, width: 1.5),
          ),
          child: Center(
            child: Text(
              "J'ai fait un don",
              style: GoogleFonts.archivo(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: SauveColors.rouge,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBtnModifier(BuildContext context, ProfilDonneur profil) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: GestureDetector(
        onTap: () => _showModifierProfil(context),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 15),
          decoration: BoxDecoration(
            color: SauveColors.carte,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: SauveColors.grisClair),
          ),
          child: Center(
            child: Text(
              'Modifier mon profil',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: SauveColors.gris,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────

  String _formatDate(DateTime date) {
    try {
      return DateFormat('d MMM yyyy', 'fr_FR').format(date);
    } catch (_) {
      return '${date.day}/${date.month}/${date.year}';
    }
  }

  // ── Modals ────────────────────────────────────────────────────────

  void _showDonDeclaratif(BuildContext context, AppState state) {
    DateTime selectedDate = DateTime.now();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: SauveColors.creme,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: SauveColors.grisClair,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              "Déclarer un don",
              style: GoogleFonts.archivo(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: SauveColors.encre,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Pour un don effectué hors de l\'application.',
              style:
                  GoogleFonts.inter(fontSize: 13, color: SauveColors.gris),
            ),
            const SizedBox(height: 20),
            Container(
              decoration: BoxDecoration(
                color: SauveColors.carte,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: SauveColors.grisClair),
              ),
              child: ListTile(
                leading: const Icon(Icons.calendar_today_outlined,
                    color: SauveColors.rouge),
                title: StatefulBuilder(
                  builder: (ctx, setSt) => Text(
                    'Date du don : ${selectedDate.day}/${selectedDate.month}/${selectedDate.year}',
                    style: GoogleFonts.inter(fontSize: 14),
                  ),
                ),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: ctx,
                    initialDate: selectedDate,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                    builder: (ctx, child) => Theme(
                      data: Theme.of(ctx).copyWith(
                        colorScheme: const ColorScheme.light(
                          primary: SauveColors.rouge,
                        ),
                      ),
                      child: child!,
                    ),
                  );
                  if (picked != null) {
                    selectedDate = picked;
                  }
                },
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () async {
                  await state.declarerDon(selectedDate);
                  if (ctx.mounted) Navigator.pop(ctx);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Don enregistré. Merci pour votre générosité !',
                          style: GoogleFonts.inter(fontSize: 13),
                        ),
                        backgroundColor: SauveColors.vert,
                        behavior: SnackBarBehavior.floating,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    );
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: SauveColors.rouge,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(
                  'Enregistrer ce don',
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
    );
  }

  void _showModifierProfil(BuildContext context) {
    final state = context.read<AppState>();
    final profil = state.profil;
    if (profil == null) return;

    // Contrôleurs pré-remplis
    final villeCtrl = TextEditingController(text: profil.ville);
    final quartierCtrl = TextEditingController(text: profil.quartier ?? '');
    final poidsCtrl = TextEditingController(text: profil.poids.toString());
    GroupeSanguin selectedGroupe = profil.groupeSanguin;
    Genre selectedGenre = profil.genre;
    bool saving = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: SauveColors.creme,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          return Padding(
            padding: EdgeInsets.fromLTRB(
              24,
              20,
              24,
              24 + MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Drag handle
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: SauveColors.grisClair,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Titre
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: SauveColors.rouge.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.edit_outlined,
                          color: SauveColors.rouge,
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Modifier mon profil',
                        style: GoogleFonts.archivo(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: SauveColors.encre,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),

                  // ── Groupe sanguin ────────────────────────────────
                  Text(
                    'Groupe sanguin',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: SauveColors.gris,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: GroupeSanguin.values.map((g) {
                      final sel = g == selectedGroupe;
                      return GestureDetector(
                        onTap: () => setSt(() => selectedGroupe = g),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: sel ? SauveColors.rouge : SauveColors.carte,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: sel
                                  ? SauveColors.rouge
                                  : SauveColors.grisClair,
                            ),
                          ),
                          child: Text(
                            g.label,
                            style: GoogleFonts.archivo(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: sel ? Colors.white : SauveColors.encre,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 18),

                  // ── Genre ─────────────────────────────────────────
                  Text(
                    'Genre',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: SauveColors.gris,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: Genre.values.map((g) {
                      final sel = g == selectedGenre;
                      final label = g == Genre.homme ? 'Homme' : 'Femme';
                      return Expanded(
                        child: GestureDetector(
                          onTap: () => setSt(() => selectedGenre = g),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            margin: EdgeInsets.only(
                                right: g == Genre.homme ? 8 : 0),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            decoration: BoxDecoration(
                              color:
                                  sel ? SauveColors.encre : SauveColors.carte,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: sel
                                    ? SauveColors.encre
                                    : SauveColors.grisClair,
                              ),
                            ),
                            child: Center(
                              child: Text(
                                label,
                                style: GoogleFonts.inter(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color:
                                      sel ? Colors.white : SauveColors.encre,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 18),

                  // ── Poids ─────────────────────────────────────────
                  Text(
                    'Poids (kg)',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: SauveColors.gris,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _editField(
                    controller: poidsCtrl,
                    hint: 'Votre poids en kg',
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 18),

                  // ── Ville ─────────────────────────────────────────
                  Text(
                    'Ville',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: SauveColors.gris,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _editField(
                    controller: villeCtrl,
                    hint: 'Ex : Ouagadougou',
                  ),
                  const SizedBox(height: 18),

                  // ── Quartier (optionnel) ──────────────────────────
                  Text(
                    'Quartier (optionnel)',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: SauveColors.gris,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _editField(
                    controller: quartierCtrl,
                    hint: 'Ex : Pissy',
                  ),
                  const SizedBox(height: 26),

                  // ── Bouton Enregistrer ────────────────────────────
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: saving
                          ? null
                          : () async {
                              final poids = int.tryParse(poidsCtrl.text.trim());
                              final ville = villeCtrl.text.trim();

                              if (poids == null || poids < 40 || poids > 200) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Poids invalide (40–200 kg).',
                                      style: GoogleFonts.inter(fontSize: 13),
                                    ),
                                    backgroundColor: SauveColors.rouge,
                                    behavior: SnackBarBehavior.floating,
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(10)),
                                  ),
                                );
                                return;
                              }
                              if (ville.isEmpty) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'La ville est obligatoire.',
                                      style: GoogleFonts.inter(fontSize: 13),
                                    ),
                                    backgroundColor: SauveColors.rouge,
                                    behavior: SnackBarBehavior.floating,
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(10)),
                                  ),
                                );
                                return;
                              }

                              setSt(() => saving = true);

                              final updated = profil.copyWith(
                                groupeSanguin: selectedGroupe,
                                genre: selectedGenre,
                                poids: poids,
                                ville: ville,
                                quartier: quartierCtrl.text.trim().isEmpty
                                    ? null
                                    : quartierCtrl.text.trim(),
                              );
                              await state.sauvegarderProfil(updated);

                              if (ctx.mounted) Navigator.pop(ctx);
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Profil mis à jour avec succès.',
                                      style: GoogleFonts.inter(fontSize: 13),
                                    ),
                                    backgroundColor: SauveColors.vert,
                                    behavior: SnackBarBehavior.floating,
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(10)),
                                  ),
                                );
                              }
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: SauveColors.rouge,
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: saving
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2.5,
                              ),
                            )
                          : Text(
                              'Enregistrer',
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
          );
        },
      ),
    );
  }

  /// Helper — champ de saisie stylisé pour le bottom sheet modifier profil
  Widget _editField({
    required TextEditingController controller,
    required String hint,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: SauveColors.carte,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SauveColors.grisClair),
      ),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        style: GoogleFonts.inter(
          fontSize: 14,
          color: SauveColors.encre,
          fontWeight: FontWeight.w500,
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: GoogleFonts.inter(
            fontSize: 13.5,
            color: SauveColors.gris,
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          border: InputBorder.none,
        ),
      ),
    );
  }

  // ── Settings bottom sheet ─────────────────────────────────────────

  void _showSettings(BuildContext context, AppState state) {
    showModalBottomSheet(
      context: context,
      backgroundColor: SauveColors.creme,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: SauveColors.grisClair,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            _buildSettingsItem(
              icon: Icons.privacy_tip_outlined,
              label: 'Politique de confidentialité',
              onTap: () {},
            ),
            // §4.2 — Bouton suppression de compte avec J+5
            _buildSettingsItem(
              icon: state.suppressionProgrammee
                  ? Icons.schedule
                  : Icons.delete_outline,
              label: state.suppressionProgrammee
                  ? 'Suppression programmée (annuler)'
                  : 'Supprimer mon compte',
              onTap: () {
                Navigator.pop(ctx); // fermer settings d'abord
                if (state.suppressionProgrammee) {
                  _annulerSuppression(context, state);
                } else {
                  _showConfirmationSuppression(context, state);
                }
              },
              color: SauveColors.rouge,
            ),
            _buildSettingsItem(
              icon: Icons.logout,
              label: 'Se déconnecter',
              onTap: () async {
                Navigator.pop(ctx);
                await state.seDeconnecter();
              },
              color: SauveColors.rouge,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? color,
  }) {
    return ListTile(
      leading: Icon(icon, color: color ?? SauveColors.encre, size: 22),
      title: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: color ?? SauveColors.encre,
        ),
      ),
      onTap: onTap,
      contentPadding: EdgeInsets.zero,
    );
  }

  // ── Suppression de compte J+5 (§4.2) ─────────────────────────────

  /// Étape 1 — Premier écran de confirmation
  void _showConfirmationSuppression(BuildContext context, AppState state) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: SauveColors.creme,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: SauveColors.grisClair,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: SauveColors.rouge.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.delete_outline,
                      color: SauveColors.rouge, size: 22),
                ),
                const SizedBox(width: 12),
                Text(
                  'Supprimer mon compte',
                  style: GoogleFonts.archivo(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: SauveColors.encre,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: SauveColors.rouge.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: SauveColors.rouge.withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Ce qui se passera :',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: SauveColors.rouge,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _bulletPoint(
                      'Votre compte sera immédiatement masqué des demandes.'),
                  _bulletPoint(
                      'La suppression définitive interviendra dans 5 jours.'),
                  _bulletPoint(
                      'Vous pouvez annuler pendant ce délai depuis votre profil.'),
                  _bulletPoint(
                      'Toutes vos données seront supprimées de façon irréversible.'),
                ],
              ),
            ),
            const SizedBox(height: 20),
            // Bouton confirmation finale — déclenche étape 2
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _showConfirmationFinale(context, state);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: SauveColors.rouge,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(
                  'Je comprends, continuer',
                  style: GoogleFonts.archivo(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  'Annuler',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    color: SauveColors.gris,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Étape 2 — Double confirmation finale avant programmation J+5
  void _showConfirmationFinale(BuildContext context, AppState state) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: SauveColors.creme,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Confirmation finale',
          style: GoogleFonts.archivo(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: SauveColors.encre,
          ),
        ),
        content: Text(
          'Êtes-vous certain de vouloir programmer la suppression de votre compte dans 5 jours ?\n\n'
          'Cette action peut être annulée depuis votre profil avant l\'expiration du délai.',
          style: GoogleFonts.inter(
            fontSize: 13.5,
            color: SauveColors.gris,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Annuler',
              style: GoogleFonts.inter(
                  fontSize: 14, color: SauveColors.gris),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _programmerSuppression(context, state);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: SauveColors.rouge,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: Text(
              'Oui, supprimer dans 5 jours',
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Effectue l'appel backend pour programmer la suppression J+5
  Future<void> _programmerSuppression(
      BuildContext context, AppState state) async {
    final ok = await state.programmerSuppression();
    if (!context.mounted) return;

    if (ok) {
      final date = state.dateSuppression;
      final dateStr = date != null
          ? DateFormat('d MMM yyyy', 'fr_FR').format(date)
          : 'dans 5 jours';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Suppression programmée le $dateStr. Vous pouvez annuler depuis votre profil.',
            style: GoogleFonts.inter(fontSize: 13),
          ),
          backgroundColor: const Color(0xFFB45309),
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          duration: const Duration(seconds: 5),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Impossible de programmer la suppression. Réessayez.',
            style: GoogleFonts.inter(fontSize: 13),
          ),
          backgroundColor: SauveColors.rouge,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  /// Annule la suppression programmée
  Future<void> _annulerSuppression(
      BuildContext context, AppState state) async {
    final ok = await state.annulerSuppression();
    if (!context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Suppression annulée. Votre compte est de nouveau actif.'
              : 'Impossible d\'annuler. Réessayez ou contactez le support.',
          style: GoogleFonts.inter(fontSize: 13),
        ),
        backgroundColor: ok ? SauveColors.vert : SauveColors.rouge,
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  /// Puce de liste pour le modal de confirmation
  Widget _bulletPoint(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 5),
            child: Icon(Icons.circle, size: 5, color: SauveColors.rouge),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.inter(
                fontSize: 12.5,
                color: SauveColors.encre,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
