import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uvccamera/uvccamera.dart';

import '../config.dart';
import '../services/analysis_service.dart';
import '../services/blynk_service.dart';
import '../services/usb_webcam.dart';

/// Live Camera Page
/// ────────────────
/// Shows the USB/OTG webcam (never the built-in cameras) and, while scanning
/// is on, captures a frame every [AppConfig.liveIntervalSeconds], analyses it
/// and forwards the damage % to the sprayer.
class LiveCameraPage extends StatefulWidget {
  const LiveCameraPage({super.key});

  @override
  State<LiveCameraPage> createState() => _LiveCameraPageState();
}

class _LiveCameraPageState extends State<LiveCameraPage>
    with WidgetsBindingObserver {
  final UsbWebcam _webcam = UsbWebcam();

  Timer? _scanTimer;
  Timer? _motorStatusTimer;
  bool _scanning = false;
  bool _isProcessing = false;

  Map<String, dynamic>? _result;
  String? _iotStatus;
  bool? _isMotorRunning;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _webcam.addListener(_onWebcamChanged);
    _webcam.start();
    if (AppConfig.iotConfigured) {
      _motorStatusTimer =
          Timer.periodic(const Duration(seconds: 3), (_) => _refreshMotor());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanTimer?.cancel();
    _motorStatusTimer?.cancel();
    _webcam.removeListener(_onWebcamChanged);
    _webcam.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _stopScanning();
      _webcam.stop();
    } else if (state == AppLifecycleState.resumed) {
      _webcam.start();
    }
  }

  // ── Camera ────────────────────────────────────────────────────────────────

  // Stop auto-scan if the webcam goes away; rebuild for status/preview.
  void _onWebcamChanged() {
    if (!_webcam.isReady) _stopScanning();
    if (mounted) setState(() {});
  }

  // ── Scanning loop ─────────────────────────────────────────────────────────

  void _startScanning() {
    _scanTimer?.cancel();
    setState(() => _scanning = true);
    _captureAndAnalyze();
    _scanTimer = Timer.periodic(
      Duration(seconds: AppConfig.liveIntervalSeconds),
      (_) => _captureAndAnalyze(),
    );
  }

  void _stopScanning() {
    _scanTimer?.cancel();
    _scanTimer = null;
    if (mounted && _scanning) setState(() => _scanning = false);
  }

  Future<void> _captureAndAnalyze() async {
    if (_isProcessing || !_webcam.isReady) return;
    setState(() => _isProcessing = true);

    try {
      final file = await _webcam.takePicture();
      final result = await AnalysisService.analyze(file);
      if (!mounted) return;
      setState(() => _result = result);

      final iot = await AnalysisService.sendToSprayer(result);
      if (mounted) setState(() => _iotStatus = iot);
      await file.delete().catchError((_) => file);
    } catch (e) {
      if (mounted) {
        setState(() => _result = {'status': 'Error', 'error': 'Capture failed: $e'});
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _refreshMotor() async {
    final status = await BlynkService.getMotorStatus();
    if (mounted) setState(() => _isMotorRunning = status);
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  Color _severityColor(String? severity) {
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

  @override
  Widget build(BuildContext context) {
    final ready = _webcam.isReady;

    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      appBar: AppBar(
        title: const Text('Live Scan'),
        backgroundColor: const Color(0xFF0D1B2A),
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Expanded(
            flex: 5,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Center(
                  child: ready
                      ? UvcCameraPreview(_webcam.controller!)
                      : Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(_webcam.status,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 16),
                              textAlign: TextAlign.center),
                        ),
                ),
                if (_isProcessing)
                  const Positioned(
                    top: 12,
                    right: 12,
                    child: Chip(
                      avatar: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      label: Text('Analyzing…'),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(flex: 3, child: _buildResultPanel()),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _scanning ? Colors.red : Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: ready
                        ? (_scanning ? _stopScanning : _startScanning)
                        : null,
                    icon: Icon(_scanning ? Icons.stop : Icons.play_arrow),
                    label: Text(_scanning
                        ? 'Stop auto-scan'
                        : 'Auto-scan every ${AppConfig.liveIntervalSeconds}s'),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                  ),
                  onPressed:
                      ready && !_isProcessing ? _captureAndAnalyze : null,
                  icon: const Icon(Icons.camera),
                  label: const Text('Scan now'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultPanel() {
    final r = _result;
    final textStyle = const TextStyle(color: Colors.white70, fontSize: 14);

    Widget content;
    if (r == null) {
      content = Text('Point the camera at a leaf and tap "Scan now".',
          style: textStyle, textAlign: TextAlign.center);
    } else if (r['status'] == 'Error') {
      content = Text('${r['error']}${r['message'] != null ? '\n${r['message']}' : ''}',
          style: const TextStyle(color: Colors.redAccent, fontSize: 15),
          textAlign: TextAlign.center);
    } else if (r['status'] == 'Uncertain') {
      content = Text(r['message'] ?? 'Low confidence — adjust the leaf and retry.',
          style: const TextStyle(color: Colors.orangeAccent, fontSize: 15),
          textAlign: TextAlign.center);
    } else {
      final damage = (r['damage_percent'] as num).toDouble();
      final conf = (r['confidence_percent'] as num).toDouble();
      final severity = r['severity'] as String?;
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${r['disease']}',
              style: const TextStyle(
                  color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(
            'Damage ${damage.toStringAsFixed(1)}%  •  '
            'Confidence ${conf.toStringAsFixed(1)}%',
            style: textStyle,
          ),
          const SizedBox(height: 6),
          Chip(
            backgroundColor: _severityColor(severity),
            label: Text('Severity: $severity',
                style: const TextStyle(color: Colors.white)),
          ),
        ],
      );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SingleChildScrollView(
        child: Column(
          children: [
            content,
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              alignment: WrapAlignment.center,
              children: [
                if (r?['source'] != null)
                  Text('Source: ${r!['source']}', style: textStyle),
                if (_iotStatus != null) Text('• $_iotStatus', style: textStyle),
                Text(
                  _isMotorRunning == null
                      ? '• Motor: n/a'
                      : '• Motor: ${_isMotorRunning! ? 'RUNNING' : 'stopped'}',
                  style: textStyle,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
