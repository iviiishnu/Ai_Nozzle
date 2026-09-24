import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_app/widgets/in_app_camera_page.dart';
import 'package:flutter_app/widgets/live_camera_page.dart';
import 'package:image_picker/image_picker.dart';

import '../config.dart';
import '../services/analysis_service.dart';
import '../services/blynk_service.dart';
import '../services/tflite_service.dart';
import 'settings_page.dart';
import '../widgets/info_card.dart';
import '../theme/app_theme.dart';

class CropAnalyzerPage extends StatefulWidget {
  const CropAnalyzerPage({super.key});

  /// Severity based on damage percentage (thresholds in AppConfig).
  static String getSeverity(double damagePercent) =>
      AppConfig.severityFor(damagePercent);

  @override
  State<CropAnalyzerPage> createState() => _CropAnalyzerPageState();
}

class _CropAnalyzerPageState extends State<CropAnalyzerPage> {
  File? _image;
  Map<String, dynamic>? _parsedResult;
  bool _isLoading = false;
  final ImagePicker picker = ImagePicker();

  // Sprayer status (Blynk V5, written by the ESP32). null = unknown / not configured.
  bool? _isMotorRunning;
  String? _iotStatus;
  Timer? _motorStatusTimer;

  bool get _useOnDeviceInference => AppConfig.useOnDevice && TfliteService.isLoaded;

  @override
  void initState() {
    super.initState();
    _startMotorPolling();
  }

  void _startMotorPolling() {
    _motorStatusTimer?.cancel();
    _motorStatusTimer = null;
    if (!AppConfig.iotConfigured) return;
    _motorStatusTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      final status = await BlynkService.getMotorStatus();
      if (mounted) setState(() => _isMotorRunning = status);
    });
  }

  @override
  void dispose() {
    _motorStatusTimer?.cancel();
    super.dispose();
  }

  Future<void> _openSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsPage()),
    );
    if (!mounted) return;
    setState(() {});
    _startMotorPolling();
  }

  Future<void> pickImage(ImageSource source) async {
    File? imageFile;
    if (source == ImageSource.camera) {
      // In-app camera: uses the OTG USB webcam, unlike the system camera
      // app that image_picker hands off to.
      imageFile = await Navigator.push<File>(
        context,
        MaterialPageRoute(builder: (_) => const InAppCameraPage()),
      );
    } else {
      final XFile? pickedFile = await picker.pickImage(
        source: source,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 85,
      );
      if (pickedFile != null) imageFile = File(pickedFile.path);
    }

    if (!mounted) return;
    if (imageFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No image captured')),
      );
      return;
    }
    await _analyzeImage(imageFile);
  }

  Future<void> _analyzeImage(File imageFile) async {
    setState(() {
      _image = imageFile;
      _isLoading = true;
      _parsedResult = null;
      _iotStatus = null;
    });

    final result = await AnalysisService.analyze(imageFile);
    if (!mounted) return;
    setState(() {
      _parsedResult = result;
      _isLoading = false;
    });

    final iot = await AnalysisService.sendToSprayer(result);
    if (mounted) setState(() => _iotStatus = iot);
  }

  /// Maps severity string to a display color.
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

  Widget _bgIcon(IconData icon, double left, double top, {double size = 48}) {
    return Positioned(
      left: left,
      top: top,
      child: Opacity(
        opacity: 0.12,
        child: Icon(icon, color: Colors.green[400], size: size),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Crop Analyzer'),
        backgroundColor: AppColors.primary,
        centerTitle: true,
        actions: [
          Tooltip(
            message: _useOnDeviceInference
                ? 'On-device (TFLite)'
                : 'Server inference',
            child: IconButton(
              icon: Icon(
                _useOnDeviceInference ? Icons.phone_android : Icons.cloud,
                color: Colors.white,
              ),
              onPressed: () async {
                await AppConfig.setUseOnDevice(!AppConfig.useOnDevice);
                if (!context.mounted) return;
                setState(() {});
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      _useOnDeviceInference
                          ? '📱 On-device TFLite inference'
                          : '☁️ Server inference (tablet fallback)',
                    ),
                    duration: const Duration(seconds: 2),
                  ),
                );
              },
            ),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings, color: Colors.white),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFE8F5E9), Color(0xFFF1F8E9)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Stack(
          children: [
            _bgIcon(Icons.eco, screenWidth * 0.1, screenHeight * 0.15),
            _bgIcon(Icons.water_drop, screenWidth * 0.8, screenHeight * 0.25),
            _bgIcon(Icons.sunny, screenWidth * 0.2, screenHeight * 0.55),
            _bgIcon(Icons.grass, screenWidth * 0.7, screenHeight * 0.65),
            SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Image.asset(
                      'assets/images/svce_logo.png',
                      height: 80,
                      fit: BoxFit.contain,
                    ),
                    const SizedBox(height: 20),
                    Container(
                      height: 220,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        color: Colors.white,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.08),
                            blurRadius: 8,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: _image == null
                          ? const Center(
                              child: Text(
                                'No image selected',
                                style: TextStyle(color: Colors.grey),
                              ),
                            )
                          : ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: Image.file(_image!, fit: BoxFit.cover),
                            ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.amber[600],
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 24, vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            elevation: 4,
                          ),
                          onPressed: _isLoading
                              ? null
                              : () => pickImage(ImageSource.gallery),
                          icon: const Icon(Icons.photo),
                          label: const Text('Gallery'),
                        ),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.amber[600],
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 24, vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            elevation: 4,
                          ),
                          onPressed: _isLoading
                              ? null
                              : () => pickImage(ImageSource.camera),
                          icon: const Icon(Icons.camera_alt),
                          label: const Text('Camera'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    if (_parsedResult != null) ...[
                      if (_parsedResult!['error'] != null)
                        Card(
                          color: Colors.red[50],
                          margin: const EdgeInsets.symmetric(vertical: 8),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                const Icon(Icons.error_outline,
                                    color: Colors.red),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    [
                                      _parsedResult!['error'],
                                      if (_parsedResult!['message'] != null)
                                        _parsedResult!['message'],
                                    ].join('\n'),
                                    style:
                                        const TextStyle(color: Colors.red),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      else ...[
                        // ── Inference source badge ─────────────────────────
                        if (_parsedResult!['source'] != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  _parsedResult!['source'] == 'on_device'
                                      ? Icons.phone_android
                                      : Icons.cloud,
                                  size: 14,
                                  color: Colors.grey[600],
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _parsedResult!['source'] == 'on_device'
                                      ? 'On-device TFLite'
                                      : _parsedResult!['source'] ==
                                              'server_fallback'
                                          ? 'Server (fallback)'
                                          : 'Server',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey[600],
                                  ),
                                ),
                                if (_parsedResult!['inference_ms'] !=
                                    null) ...[
                                  const SizedBox(width: 8),
                                  Text(
                                    '${_parsedResult!['inference_ms']}ms',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey[500],
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),

                        // ── Uncertain warning ──────────────────────────────
                        if (_parsedResult!['status'] == 'Uncertain')
                          Card(
                            color: Colors.orange[50],
                            margin: const EdgeInsets.symmetric(vertical: 8),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Row(
                                children: [
                                  const Icon(Icons.warning_amber,
                                      color: Colors.orange),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      _parsedResult!['message'] ??
                                          'Low confidence — retake the photo.',
                                      style: const TextStyle(
                                          color: Colors.orange),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        else ...[
                          // ── Disease ──────────────────────────────────────
                          InfoCard(
                            title: 'Disease',
                            value: _parsedResult!['disease'] ?? 'Unknown',
                            icon: Icons.coronavirus_outlined,
                            valueColor: Colors.red[700],
                          ),

                          // ── Severity (always from damage_percent) ────────
                          InfoCard(
                            title: 'Severity',
                            value: CropAnalyzerPage.getSeverity(
                              (_parsedResult!['damage_percent'] as num?)
                                      ?.toDouble() ??
                                  0.0,
                            ),
                            icon: Icons.bar_chart,
                            valueColor: _severityColor(
                              CropAnalyzerPage.getSeverity(
                                (_parsedResult!['damage_percent'] as num?)
                                        ?.toDouble() ??
                                    0.0,
                              ),
                            ),
                          ),
                        ],

                        InfoCard(
                          title: "Damage",
                          value: _parsedResult!['damage_percent'] != null
                              ? "${(_parsedResult!['damage_percent'] as num).toStringAsFixed(2)}%"
                              : "N/A",
                          icon: Icons.warning_amber,
                        ),
                        InfoCard(
                          title: "Confidence",
                          value: _parsedResult!['confidence_percent'] != null
                              ? "${(_parsedResult!['confidence_percent'] as num).toStringAsFixed(2)}%"
                              : "N/A",
                          progress: ((_parsedResult!['confidence_percent']
                                          as num?)
                                      ?.toDouble() ??
                                  0) /
                              100,
                          icon: Icons.show_chart,
                        ),

                        // ── Sprayer (Blynk) ────────────────────────────────
                        Card(
                          margin: const EdgeInsets.symmetric(vertical: 8),
                          child: ListTile(
                            leading: Icon(
                              _isMotorRunning == true
                                  ? Icons.flash_on
                                  : Icons.flash_off,
                              color: _isMotorRunning == true
                                  ? Colors.green
                                  : Colors.grey,
                            ),
                            title: const Text("Sprayer"),
                            subtitle: Text(
                              [
                                _isMotorRunning == null
                                    ? 'Motor status unavailable'
                                    : (_isMotorRunning! ? 'Motor running' : 'Motor stopped'),
                                if (_iotStatus != null) _iotStatus!,
                              ].join(' • '),
                            ),
                          ),
                        ),
                      ],
                    ],
                    if (_isLoading)
                      Container(
                        color: Colors.black38,
                        child:
                            const Center(child: CircularProgressIndicator()),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.videocam),
        label: const Text('Live Camera'),
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.black,
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const LiveCameraPage()),
          );
        },
      ),
    );
  }
}
