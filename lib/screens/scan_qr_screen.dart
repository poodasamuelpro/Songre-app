import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:go_router/go_router.dart';
import '../theme/sauve_theme.dart';
import '../services/supabase_service.dart';

// =====================================================================
// ÉCRAN — Scan QR code donneur (côté demandeur)
// Flux : Scanner → appel validerToken() → confirmation / erreur
// Platform guard : mobile_scanner n'est pas disponible sur Web.
//                  Un fallback de saisie manuelle est affiché sur Web.
// =====================================================================
class ScanQrScreen extends StatefulWidget {
  /// ID du demandeur (userId courant) — requis pour la validation
  final String demandeurId;

  const ScanQrScreen({super.key, required this.demandeurId});

  @override
  State<ScanQrScreen> createState() => _ScanQrScreenState();
}

class _ScanQrScreenState extends State<ScanQrScreen> {
  // Contrôleur du scanner natif
  MobileScannerController? _scannerCtrl;

  // État de la validation
  bool _validating = false;
  bool _done = false;
  String? _resultMessage;
  bool _resultOk = false;

  // Saisie manuelle (fallback web ou si caméra indisponible)
  final TextEditingController _manualCtrl = TextEditingController();
  bool _showManual = kIsWeb; // toujours manuel sur Web

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      _scannerCtrl = MobileScannerController(
        detectionSpeed: DetectionSpeed.noDuplicates,
        facing: CameraFacing.back,
        torchEnabled: false,
      );
    }
  }

  @override
  void dispose() {
    _scannerCtrl?.dispose();
    _manualCtrl.dispose();
    super.dispose();
  }

  // ── Validation ──────────────────────────────────────────────────────

  Future<void> _valider(String token) async {
    if (_validating || _done) return;
    final trimmed = token.trim();
    if (trimmed.isEmpty) return;

    // [Sécurité T9] Le bloc HARD est dans router.dart (redirect sur /scan-qr).
    // Ce garde secondaire est conservé comme filet de sécurité au cas où l'écran
    // serait instancié directement (tests unitaires, deep link, etc.).
    // En production normale, demandeurId est toujours non-vide ici.
    assert(
      widget.demandeurId.isNotEmpty,
      'ScanQrScreen instancié sans demandeurId — le redirect dans router.dart aurait dû bloquer.',
    );
    if (widget.demandeurId.isEmpty) {
      // Ne devrait jamais arriver en production — le router bloque avant.
      if (!mounted) return;
      context.go('/home');
      return;
    }

    setState(() => _validating = true);

    // Stopper le scanner pendant la validation
    await _scannerCtrl?.stop();

    final result = await SupabaseService.validerToken(
      token: trimmed,
      demandeurId: widget.demandeurId,
    );

    if (!mounted) return;

    setState(() {
      _validating = false;
      _done = true;
      _resultOk = result.success;
      _resultMessage = result.success
          ? 'Don validé avec succès ✓'
          : (result.error ?? 'Code invalide ou expiré.');
    });
  }

  // ── UI ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SauveColors.creme,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Row(
                children: [
                  _buildBackBtn(context),
                  Expanded(
                    child: Center(
                      child: Text(
                        'Scanner le code donneur',
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

            Expanded(
              child: _done
                  ? _buildResultView()
                  : _showManual
                      ? _buildManualEntry()
                      : _buildScannerView(),
            ),
          ],
        ),
      ),
    );
  }

  // ── Back button ──────────────────────────────────────────────────────

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
        child: const Icon(Icons.arrow_back, size: 18, color: SauveColors.encre),
      ),
    );
  }

  // ── Scanner natif (mobile uniquement) ───────────────────────────────

  Widget _buildScannerView() {
    return Column(
      children: [
        // Viewfinder
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  MobileScanner(
                    controller: _scannerCtrl!,
                    onDetect: (capture) {
                      final barcode = capture.barcodes.firstOrNull;
                      if (barcode?.rawValue != null) {
                        _valider(barcode!.rawValue!);
                      }
                    },
                  ),
                  // Overlay viseur
                  _buildViewfinderOverlay(),
                  // Loading overlay pendant validation
                  if (_validating)
                    Container(
                      color: Colors.black54,
                      child: const Center(
                        child: CircularProgressIndicator(
                          color: Colors.white,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),

        // Instructions + boutons
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Text(
                'Placez le QR code du donneur\ndans le cadre',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  color: SauveColors.gris,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Torche
                  _buildIconBtn(
                    icon: Icons.flashlight_on_outlined,
                    label: 'Torche',
                    onTap: () => _scannerCtrl?.toggleTorch(),
                  ),
                  const SizedBox(width: 16),
                  // Saisie manuelle
                  _buildIconBtn(
                    icon: Icons.keyboard_outlined,
                    label: 'Manuel',
                    onTap: () => setState(() => _showManual = true),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildViewfinderOverlay() {
    return CustomPaint(
      painter: _ViewfinderPainter(),
      child: const SizedBox.expand(),
    );
  }

  Widget _buildIconBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: SauveColors.carte,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: SauveColors.grisClair),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: SauveColors.encre),
            const SizedBox(width: 8),
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: SauveColors.encre,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Saisie manuelle (Web / fallback) ─────────────────────────────────

  Widget _buildManualEntry() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          // Illustration
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: SauveColors.rouge.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.qr_code_scanner,
              size: 40,
              color: SauveColors.rouge,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            kIsWeb
                ? 'Saisie manuelle du code'
                : 'Entrer le code manuellement',
            style: GoogleFonts.archivo(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: SauveColors.encre,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            kIsWeb
                ? 'Le scan caméra est disponible sur l\'application mobile.'
                : 'Entrez le code affiché sur l\'écran du donneur.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 13,
              color: SauveColors.gris,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 28),
          // Champ saisie
          Container(
            decoration: BoxDecoration(
              color: SauveColors.carte,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: SauveColors.grisClair),
            ),
            child: TextField(
              controller: _manualCtrl,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: SauveColors.encre,
                letterSpacing: 2,
              ),
              decoration: InputDecoration(
                hintText: 'Code QR du donneur',
                hintStyle: GoogleFonts.inter(
                  fontSize: 14,
                  color: SauveColors.gris,
                  letterSpacing: 0,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
                border: InputBorder.none,
                suffixIcon: IconButton(
                  icon: const Icon(Icons.clear, color: SauveColors.gris),
                  onPressed: () => _manualCtrl.clear(),
                ),
              ),
              onSubmitted: (val) => _valider(val),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _validating
                  ? null
                  : () => _valider(_manualCtrl.text),
              style: ElevatedButton.styleFrom(
                backgroundColor: SauveColors.rouge,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: _validating
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    )
                  : Text(
                      'Valider le don',
                      style: GoogleFonts.archivo(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
          ),
          if (!kIsWeb) ...[
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => setState(() => _showManual = false),
              child: Text(
                '← Revenir au scanner',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: SauveColors.rouge,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Résultat ─────────────────────────────────────────────────────────

  Widget _buildResultView() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Icone résultat
          Container(
            width: 90,
            height: 90,
            decoration: BoxDecoration(
              color: (_resultOk ? SauveColors.vert : SauveColors.rouge)
                  .withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              _resultOk
                  ? Icons.check_circle_outline
                  : Icons.error_outline,
              size: 50,
              color: _resultOk ? SauveColors.vert : SauveColors.rouge,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            _resultOk ? 'Don validé !' : 'Validation échouée',
            style: GoogleFonts.archivo(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: _resultOk ? SauveColors.vert : SauveColors.rouge,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _resultMessage ?? '',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 14,
              color: SauveColors.gris,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 36),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => context.pop(),
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    _resultOk ? SauveColors.vert : SauveColors.rouge,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: Text(
                'Retour',
                style: GoogleFonts.archivo(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          if (!_resultOk) ...[
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => setState(() {
                _done = false;
                _resultMessage = null;
                _validating = false;
                _manualCtrl.clear();
                if (!kIsWeb) {
                  _showManual = false;
                  _scannerCtrl?.start();
                }
              }),
              child: Text(
                'Réessayer',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: SauveColors.rouge,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// =====================================================================
// Peintre — Viseur QR (cadre + coins)
// =====================================================================
class _ViewfinderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Fond semi-transparent
    final overlay = Paint()..color = Colors.black.withValues(alpha: 0.5);
    const cornerLen = 28.0;
    const cornerThick = 4.0;
    final squareSize = size.width * 0.64;
    final left = (size.width - squareSize) / 2;
    final top = (size.height - squareSize) / 2;
    final right = left + squareSize;
    final bottom = top + squareSize;

    // Haut
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width, top), overlay);
    // Bas
    canvas.drawRect(
        Rect.fromLTRB(0, bottom, size.width, size.height), overlay);
    // Gauche
    canvas.drawRect(Rect.fromLTRB(0, top, left, bottom), overlay);
    // Droite
    canvas.drawRect(Rect.fromLTRB(right, top, size.width, bottom), overlay);

    // Coins rouges
    final corner = Paint()
      ..color = SauveColors.rouge
      ..strokeWidth = cornerThick
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // Coin haut-gauche
    canvas.drawLine(Offset(left, top + cornerLen), Offset(left, top), corner);
    canvas.drawLine(Offset(left, top), Offset(left + cornerLen, top), corner);
    // Coin haut-droit
    canvas.drawLine(Offset(right, top + cornerLen), Offset(right, top), corner);
    canvas.drawLine(Offset(right, top), Offset(right - cornerLen, top), corner);
    // Coin bas-gauche
    canvas.drawLine(
        Offset(left, bottom - cornerLen), Offset(left, bottom), corner);
    canvas.drawLine(
        Offset(left, bottom), Offset(left + cornerLen, bottom), corner);
    // Coin bas-droit
    canvas.drawLine(
        Offset(right, bottom - cornerLen), Offset(right, bottom), corner);
    canvas.drawLine(
        Offset(right, bottom), Offset(right - cornerLen, bottom), corner);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
