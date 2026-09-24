import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../services/api_service.dart';
import '../services/blynk_service.dart';
import '../screens/crop_analyzer_page.dart';

/// Live Camera Page
/// ────────────────
/// Polls the PC webcam server (webcam.py on port 5011) every [captureIntervalSeconds]
/// seconds to grab a JPEG frame, displays it, and simultaneously sends it to
/// the ML server for crop disease analysis.
///
/// This approach bypasses Android's Camera2 API entirely, so OTG USB webcams
/// that are connected to the PC (not the tablet) work without any Android
/// driver support.
class LiveCameraPage extends StatefulWidget {
  const LiveCameraPage({super.key});

  @override
  State<LiveCameraPage> createState() => _LiveCameraPageState();
}

class _LiveCameraPageState extends State<LiveCameraPage> {
  static const int captureIntervalSeconds = 3;

  Timer? _captureTimer;
  Timer? _motorStatusTimer;

  Uint8List? _lastFrameBytes;
  Map<String, dynamic>? _parsedResult;
  bool _isProcessing = false;
  String? _cameraError;

  final BlynkService blynk = BlynkService("rXMkKMQ5NwBO1pmXM1MD1UPvW1bIL8AM");
  int? _lastSentDamagePercent;
  bool _isMotorRunning = false;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();

    // Start polling webcam + analyzing immediately, then repeat
    _fetchAndAnalyze();
    _captureTimer = Timer.periodic(
      const Duration(seconds: captureIntervalSeconds),
      (_) => _fetchAndAnalyze(),
    );

    // Poll Blynk V5 for real motor status every 2 s
    _motorStatusTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      final status = await blynk.getMotorStatus();
      if (mounted) setState(() => _isMotorRunning = status);
    });
  }

  @override
  void dispose() {
    _captureTimer?.cancel();
    _motorStatusTimer?.cancel();
    super.dispose();
  }

  // ── Core fetch + analyze ──────────────────────────────────────────────────

  Future<void> _fetchAndAnalyze() async {
    if (_isProcessing) return;
    if (mounted) setState(() => _isProcessing = true);

    try {
      // 1. Grab a JPEG frame from the PC webcam server
      final frameBytes = await _fetchFrame();
      if (frameBytes == null) return;

      if (mounted) setState(() => _lastFrameBytes = frameBytes);

      // 2. Send the same bytes to the ML server for inference
      final jsonResp = await ApiService.uploadImageBytes(frameBytes);

      if (!mounted) return;
      setState(() => _parsedResult = jsonResp);

      // 3. Forward damage % to Blynk V4 (only when value changes)
      final rawDamage = jsonResp['damage_percent'];
      if (rawDamage != null) {
        final int damageInt = (rawDamage as num).toInt();
        if (_lastSentDamagePercent != damageInt) {
          await blynk.setVirtualPin(4, damageInt);
          _lastSentDamagePercent = damageInt;
          debugPrint('Sent damage $damageInt% to Blynk V4');
        }
      }
    } catch (e) {
      debugPrint('LiveCamera error: $e');
      if (mounted) {
        setState(() => _parsedResult = {'error': 'Capture/upload failed: $e'});
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  /// Fetches a single JPEG frame from webcam.py (/capture endpoint).
  /// Returns null and sets [_cameraError] on failure.
  Future<Uint8List?> _fetchFrame() async {
    try {
      final uri = Uri.parse('$WEBCAM_SERVER_URL/capture');
      final response = await http.get(uri).timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('Webcam server timed out'),
      );

      if (response.statusCode == 200) {
        if (mounted) setState(() => _cameraError = null);
        return response.bodyBytes;
      } else {
        final msg = 'Webcam server error ${response.statusCode}: ${response.body}';
        if (mounted) setState(() => _cameraError = msg);
        return null;
      }
    } on TimeoutException catch (e) {
      if (mounted) setState(() => _cameraError = 'Timeout: $e');
      return null;
    } catch (e) {
      if (mounted) {
        setState(() => _cameraError =
            'Cannot reach webcam server at $WEBCAM_SERVER_URL.\n'
            'Make sure webcam.py is running on the PC.\nError: $e');
      }
      return null;
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Color _severityColor(String severity) {
    switch (severity) {
      case 'High':
        return Colors.red;
      case 'Medium':
        return Colors.orange;
      case 'Low':
        return Colors.green;
      default:
        return Colors.grey;
    }
  }

  String _resolveSeverity(Map<String, dynamic> result) {
    final damage = (result['damage_percent'] as num?)?.toDouble() ?? 0.0;
    return CropAnalyzerPage.getSeverity(damage);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      body: Column(
        children: [
          // ── Camera frame display ─────────────────────────────────────────
          Expanded(
            flex: 45,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Frame or placeholder
                _lastFrameBytes != null
                    ? Image.memory(
                        _lastFrameBytes!,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                      )
                    : _cameraError != null
                        ? _ErrorPlaceholder(message: _cameraError!)
                        : const Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircularProgressIndicator(color: Colors.white),
                                SizedBox(height: 12),
                                Text(
                                  'Connecting to webcam server...',
                                  style: TextStyle(
                                      color: Colors.white54, fontSize: 13),
                                ),
                              ],
                            ),
                          ),

                // Bottom gradient fade
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  height: 60,
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Color(0xFF0D1B2A)],
                      ),
                    ),
                  ),
                ),

                // LIVE badge
                Positioned(
                  top: 48,
                  left: 16,
                  child: _LiveBadge(isProcessing: _isProcessing),
                ),

                // Interval label
                Positioned(
                  top: 48,
                  right: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'Every ${captureIntervalSeconds}s  •  PC Webcam',
                      style: TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                  ),
                ),

                // Analyzing spinner
                if (_isProcessing)
                  Positioned(
                    bottom: 16,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            ),
                            SizedBox(width: 8),
                            Text(
                              'Analyzing...',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // ── Results panel ────────────────────────────────────────────────
          Expanded(
            flex: 55,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
              child: _buildResultsPanel(),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.redAccent,
        tooltip: 'Stop Live Capture',
        onPressed: () => Navigator.pop(context),
        child: const Icon(Icons.close),
      ),
    );
  }

  // ── Results panel ─────────────────────────────────────────────────────────

  Widget _buildResultsPanel() {
    if (_parsedResult == null) {
      return const Padding(
        padding: EdgeInsets.only(top: 32),
        child: Center(
          child: Text(
            'Waiting for first frame...',
            style: TextStyle(color: Colors.white54, fontSize: 14),
          ),
        ),
      );
    }

    if (_parsedResult!['error'] != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 16),
        child: _DashboardCard(
          icon: Icons.error_outline,
          iconColor: Colors.red,
          title: 'Error',
          value: '${_parsedResult!['error']}',
          valueColor: Colors.red,
        ),
      );
    }

    final disease = (_parsedResult!['disease'] as String?) ?? 'Unknown';
    final status = (_parsedResult!['status'] as String?) ?? 'Unknown';
    final damage = (_parsedResult!['damage_percent'] as num?)?.toDouble() ?? 0.0;
    final conf = (_parsedResult!['confidence_percent'] as num?)?.toDouble() ?? 0.0;
    final severity = _resolveSeverity(_parsedResult!);
    final isUncertain = status == 'Uncertain';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: Text(
            'AI Detection Results',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
        ),

        if (isUncertain)
          _UncertainBanner(
            message: (_parsedResult!['message'] as String?) ??
                'Low confidence — retake the photo.',
          ),

        if (!isUncertain) ...[
          _DashboardCard(
            icon: Icons.coronavirus_outlined,
            iconColor: Colors.redAccent,
            title: 'Disease',
            value: disease,
            valueColor: Colors.redAccent,
          ),
          _DashboardCard(
            icon: Icons.bar_chart,
            iconColor: _severityColor(severity),
            title: 'Severity',
            value: severity,
            valueColor: _severityColor(severity),
          ),
        ],

        _DashboardCard(
          icon: Icons.warning_amber,
          iconColor: Colors.orangeAccent,
          title: 'Damage',
          value: '${damage.toStringAsFixed(2)}%',
          valueColor: Colors.orangeAccent,
          progress: (damage / 100).clamp(0.0, 1.0),
          progressColor: Colors.orangeAccent,
        ),

        _DashboardCard(
          icon: Icons.show_chart,
          iconColor: Colors.lightBlueAccent,
          title: 'Confidence',
          value: '${conf.toStringAsFixed(2)}%',
          valueColor: Colors.lightBlueAccent,
          progress: (conf / 100).clamp(0.0, 1.0),
          progressColor: Colors.lightBlueAccent,
        ),

        _DashboardCard(
          icon: _isMotorRunning ? Icons.flash_on : Icons.flash_off,
          iconColor: _isMotorRunning ? Colors.greenAccent : Colors.redAccent,
          title: 'Motor Status',
          value: _isMotorRunning ? 'Running' : 'Stopped',
          valueColor: _isMotorRunning ? Colors.greenAccent : Colors.redAccent,
        ),

        _DashboardCard(
          icon: Icons.videocam,
          iconColor: Colors.tealAccent,
          title: 'Source',
          value: _isProcessing ? 'Processing...' : 'PC Webcam',
          valueColor: _isProcessing ? Colors.amber : Colors.tealAccent,
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ERROR PLACEHOLDER
// ─────────────────────────────────────────────────────────────────────────────
class _ErrorPlaceholder extends StatelessWidget {
  final String message;
  const _ErrorPlaceholder({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1A2B3C),
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off, color: Colors.red, size: 48),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.red, fontSize: 13),
            ),
            const SizedBox(height: 12),
            const Text(
              'Make sure webcam.py is running on the PC\nand the OTG camera is connected to it.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// LIVE BADGE
// ─────────────────────────────────────────────────────────────────────────────
class _LiveBadge extends StatefulWidget {
  final bool isProcessing;
  const _LiveBadge({required this.isProcessing});

  @override
  State<_LiveBadge> createState() => _LiveBadgeState();
}

class _LiveBadgeState extends State<_LiveBadge>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, __) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white
                    .withValues(alpha: 0.4 + 0.6 * _pulse.value),
              ),
            ),
            const SizedBox(width: 6),
            const Text(
              'AI Detection Running',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DASHBOARD CARD
// ─────────────────────────────────────────────────────────────────────────────
class _DashboardCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String value;
  final Color valueColor;
  final double? progress;
  final Color? progressColor;

  const _DashboardCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.value,
    required this.valueColor,
    this.progress,
    this.progressColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2B3C),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: iconColor.withValues(alpha: 0.25), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: iconColor, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  value,
                  style: TextStyle(
                    color: valueColor,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress!.clamp(0.0, 1.0),
                minHeight: 5,
                backgroundColor: Colors.white12,
                valueColor: AlwaysStoppedAnimation<Color>(
                    progressColor ?? iconColor),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// UNCERTAIN BANNER
// ─────────────────────────────────────────────────────────────────────────────
class _UncertainBanner extends StatelessWidget {
  final String message;
  const _UncertainBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(14),
        border:
            Border.all(color: Colors.orange.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber, color: Colors.orange, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style:
                  const TextStyle(color: Colors.orange, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
