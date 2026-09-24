import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_uvc_camera/flutter_uvc_camera.dart';

import '../services/api_service.dart';
import '../services/blynk_service.dart';
import '../screens/crop_analyzer_page.dart';

/// Live Camera Page
/// ────────────────
/// The OTG UVC camera is the only live input for this page. The PC webcam
/// server is intentionally not used here.
///
/// A frame is captured every [captureIntervalSeconds] seconds, displayed, and
/// sent to the ML server for crop disease inference.
class LiveCameraPage extends StatefulWidget {
  const LiveCameraPage({super.key});

  @override
  State<LiveCameraPage> createState() => _LiveCameraPageState();
}

class _LiveCameraPageState extends State<LiveCameraPage> {
  static const int captureIntervalSeconds = 3;
  static const int uvcTimeoutSeconds = 8;

  // ── UVC ───────────────────────────────────────────────────────────────────
  UVCCameraController? _uvcController;
  bool _uvcReady  = false;
  bool _uvcFailed = false;

  // ── Shared ────────────────────────────────────────────────────────────────
  Timer? _captureTimer;
  Timer? _motorStatusTimer;

  Uint8List? _lastFrameBytes;
  Map<String, dynamic>? _parsedResult;
  bool _isProcessing = false;
  String? _statusMessage;

  final BlynkService _blynk =
      BlynkService("rXMkKMQ5NwBO1pmXM1MD1UPvW1bIL8AM");
  int?  _lastSentDamagePercent;
  bool  _isMotorRunning = false;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _initUvc();
    _motorStatusTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      final status = await _blynk.getMotorStatus();
      if (mounted) setState(() => _isMotorRunning = status);
    });
  }

  @override
  void dispose() {
    _captureTimer?.cancel();
    _motorStatusTimer?.cancel();
    _uvcController?.closeCamera();
    _uvcController?.dispose();
    super.dispose();
  }

  // ── UVC initialisation ────────────────────────────────────────────────────

  Future<void> _initUvc() async {
    if (mounted) setState(() => _statusMessage = 'Looking for USB camera...');

    try {
      final controller = UVCCameraController();

      controller.cameraStateCallback = (UVCCameraState state) {
        debugPrint('UVC state → $state');
        if (!mounted) return;
        if (state == UVCCameraState.opened) {
          setState(() { _uvcReady = true; _statusMessage = null; });
          _startCaptureTimer();
        } else if (state == UVCCameraState.error) {
          final error = controller.getCameraErrorMsg;
            _markUvcUnavailable(
              error.isEmpty ? 'UVC camera failed to open' : 'UVC: $error');
        } else if (state == UVCCameraState.closed) {
          if (_uvcReady) {
            setState(() {
              _uvcReady = false;
              _statusMessage = 'USB camera disconnected';
            });
          }
          _captureTimer?.cancel();
        }
      };

      controller.msgCallback = (String msg) {
        debugPrint('UVC msg → $msg');
        if (!mounted) return;
        final lower = msg.toLowerCase();
        if (lower.contains('permission') ||
            lower.contains('denied')     ||
            lower.contains('no device')  ||
            lower.contains('not found')) {
          _markUvcUnavailable('UVC: $msg');
        }
      };

      if (mounted) setState(() => _uvcController = controller);

      // The UVC platform view must be mounted before the plugin can initialize
      // its native camera and request USB permission.
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await Future.delayed(const Duration(milliseconds: 400));
        if (!mounted || _uvcController != controller || _uvcFailed) return;
        try {
          await controller.openUVCCamera();
        } catch (e) {
          debugPrint('UVC open exception: $e');
          _markUvcUnavailable('UVC open error: $e');
        }
      });

      // Wait up to uvcTimeoutSeconds before giving up
      await Future.delayed(const Duration(seconds: uvcTimeoutSeconds));
      if (mounted && !_uvcReady && !_uvcFailed) {
        _markUvcUnavailable(
          'No OTG camera responded within ${uvcTimeoutSeconds}s');
      }
    } catch (e) {
      debugPrint('UVC init exception: $e');
      _markUvcUnavailable('UVC init error: $e');
    }
  }

  void _markUvcUnavailable(String reason) {
    if (_uvcFailed) return;
    debugPrint('OTG UVC camera unavailable. Reason: $reason');
    if (!mounted) return;
    setState(() {
      _uvcFailed = true;
      _uvcReady  = false;
      _statusMessage = reason;
    });
  }

  void _startCaptureTimer() {
    _captureTimer?.cancel();
    _captureAndAnalyze(); // fire immediately
    _captureTimer = Timer.periodic(
      const Duration(seconds: captureIntervalSeconds),
      (_) => _captureAndAnalyze(),
    );
  }

  // ── Capture + analyse ─────────────────────────────────────────────────────

  Future<void> _captureAndAnalyze() async {
    if (_isProcessing) return;
    if (mounted) setState(() => _isProcessing = true);

    try {
        if (!_uvcReady || _uvcController == null) return;
        final Uint8List? frameBytes = await _captureUvc();

      if (frameBytes == null) return;
      if (mounted) setState(() => _lastFrameBytes = frameBytes);

      final jsonResp = await ApiService.uploadImageBytes(frameBytes);
      if (!mounted) return;
      setState(() => _parsedResult = jsonResp);

      final rawDamage = jsonResp['damage_percent'];
      if (rawDamage != null) {
        final int d = (rawDamage as num).toInt();
        if (_lastSentDamagePercent != d) {
          await _blynk.setVirtualPin(4, d);
          _lastSentDamagePercent = d;
          debugPrint('Sent damage $d% to Blynk V4');
        }
      }
    } catch (e) {
      debugPrint('Capture/analyse error: $e');
      if (mounted) {
        setState(() => _parsedResult = {'error': 'Capture failed: $e'});
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  /// Grab a frame from the UVC camera using takePicture().
  Future<Uint8List?> _captureUvc() async {
    try {
      final String? path = await _uvcController!.takePicture();
      if (path == null || path.isEmpty) return null;
      return await File(path).readAsBytes();
    } catch (e) {
      debugPrint('UVC capture error: $e');
      _markUvcUnavailable('OTG capture failed: $e');
      return null;
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String get _sourceLabel {
    if (_uvcReady)  return 'OTG Webcam (UVC)';
    if (_uvcFailed) return 'OTG Webcam unavailable';
    return 'Initialising...';
  }

  Color _severityColor(String s) {
    switch (s) {
      case 'High':   return Colors.red;
      case 'Medium': return Colors.orange;
      case 'Low':    return Colors.green;
      default:       return Colors.grey;
    }
  }

  String _resolveSeverity(Map<String, dynamic> r) =>
      CropAnalyzerPage.getSeverity(
          (r['damage_percent'] as num?)?.toDouble() ?? 0.0);

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      body: Column(
        children: [
          // ── Camera preview ───────────────────────────────────────────────
          Expanded(
            flex: 45,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // UVC live preview (active when OTG camera is open)
                if (_uvcController != null && !_uvcFailed)
                  UVCCameraView(
                    cameraController: _uvcController!,
                    width: double.infinity,
                    height: double.infinity,
                  )
                // Last captured UVC frame while the next capture is pending.
                else if (_lastFrameBytes != null)
                  Image.memory(
                    _lastFrameBytes!,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  )
                // Placeholder while initialising
                else
                  _Placeholder(message: _statusMessage),

                // Bottom gradient
                Positioned(
                  bottom: 0, left: 0, right: 0, height: 60,
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
                  top: 48, left: 16,
                  child: _LiveBadge(isProcessing: _isProcessing),
                ),

                // Source label
                Positioned(
                  top: 48, right: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'Every ${captureIntervalSeconds}s  •  $_sourceLabel',
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 11),
                    ),
                  ),
                ),

                // Analysing spinner
                if (_isProcessing)
                  Positioned(
                    bottom: 16, left: 0, right: 0,
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
                              width: 14, height: 14,
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2),
                            ),
                            SizedBox(width: 8),
                            Text('Analyzing...',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600)),
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
      return Padding(
        padding: const EdgeInsets.only(top: 32),
        child: Center(
          child: Text(
            _statusMessage ?? 'Waiting for first frame...',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 14),
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

    final disease    = (_parsedResult!['disease']             as String?) ?? 'Unknown';
    final status     = (_parsedResult!['status']              as String?) ?? 'Unknown';
    final damage     = (_parsedResult!['damage_percent']      as num?)?.toDouble() ?? 0.0;
    final conf       = (_parsedResult!['confidence_percent']  as num?)?.toDouble() ?? 0.0;
    final severity   = _resolveSeverity(_parsedResult!);
    final isUncertain = status == 'Uncertain';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: Text('AI Detection Results',
              style: TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8)),
        ),

        if (isUncertain)
          _UncertainBanner(
              message: (_parsedResult!['message'] as String?) ??
                  'Low confidence — retake the photo.'),

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
          value: _sourceLabel,
          valueColor: Colors.tealAccent,
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PLACEHOLDER
// ─────────────────────────────────────────────────────────────────────────────
class _Placeholder extends StatelessWidget {
  final String? message;
  const _Placeholder({this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1A2B3C),
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message != null &&
                (message!.contains('error') ||
                    message!.contains('unavailable') ||
                    message!.contains('Cannot')))
              const Icon(Icons.videocam_off, color: Colors.red, size: 48)
            else
              const CircularProgressIndicator(color: Colors.white),
            const SizedBox(height: 16),
            Text(
              message ?? 'Connecting...',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: (message != null &&
                        (message!.contains('error') ||
                            message!.contains('Cannot')))
                    ? Colors.red
                    : Colors.white54,
                fontSize: 13,
              ),
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
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
  }

  @override
  void dispose() { _pulse.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, __) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8, height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white
                    .withValues(alpha: 0.4 + 0.6 * _pulse.value),
              ),
            ),
            const SizedBox(width: 6),
            const Text('AI Detection Running',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5)),
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
                child: Text(title,
                    style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 13,
                        fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(value,
                    style: TextStyle(
                        color: valueColor,
                        fontSize: 15,
                        fontWeight: FontWeight.bold),
                    textAlign: TextAlign.end,
                    overflow: TextOverflow.ellipsis),
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
        border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber, color: Colors.orange, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message,
                style: const TextStyle(color: Colors.orange, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
