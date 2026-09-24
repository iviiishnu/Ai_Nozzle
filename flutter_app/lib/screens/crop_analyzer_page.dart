import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_app/widgets/live_camera_page.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_service.dart';
import '../services/blynk_service.dart';
import '../services/tflite_service.dart';
import '../widgets/info_card.dart';
import '../theme/app_theme.dart';

class CropAnalyzerPage extends StatefulWidget {
  const CropAnalyzerPage({super.key});

  /// Severity based on damage percentage only.
  /// < 15 → Low, < 35 → Medium, ≥ 35 → High
  static String getSeverity(double damagePercent) {
    if (damagePercent < 15) return 'Low';
    if (damagePercent < 35) return 'Medium';
    return 'High';
  }

  @override
  State<CropAnalyzerPage> createState() => _CropAnalyzerPageState();
}

class _CropAnalyzerPageState extends State<CropAnalyzerPage> {
  File? _image;
  Map<String, dynamic>? _parsedResult;
  bool _isLoading = false;
  final ImagePicker picker = ImagePicker();

  final BlynkService blynk = BlynkService("rXMkKMQ5NwBO1pmXM1MD1UPvW1bIL8AM");

  bool motorRunning = false;
  int runTimeLeft = 0;
  Timer? timer;
  static const int sprayDuration = 5; // match Python spray time seconds

  // V5 motor status (real-time from Blynk)
  bool isMotorRunning = false;
  Timer? _motorStatusTimer;

  @override
  void initState() {
    super.initState();
    startMotorStatusTimer();

    // Poll V5 for real-time motor running status every 2 seconds
    _motorStatusTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      final status = await blynk.getMotorStatus();
      if (mounted) {
        setState(() {
          isMotorRunning = status;
        });
      }
    });
  }

  void startMotorStatusTimer() {
    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 1), (t) async {
      try {
        final int motorState = await blynk.getVirtualPin(4);
        setState(() {
          if (motorRunning && runTimeLeft > 0) {
            runTimeLeft--;
          } else if (motorState == 1 && !motorRunning) {
            motorRunning = true;
            runTimeLeft = sprayDuration;
          } else if (motorState == 0) {
            motorRunning = false;
            runTimeLeft = 0;
          }
        });
      } catch (e) {
        // optionally handle error
      }
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    _motorStatusTimer?.cancel();
    super.dispose();
  }

  // ── Inference mode ──────────────────────────────────────────────────────────
  bool _useOnDeviceInference = TfliteService.isLoaded;

  int? lastSentDamagePercent;

  Future<void> pickImage(ImageSource source) async {
    try {
      final XFile? pickedFile = await picker.pickImage(source: source);
      if (pickedFile == null) {
        setState(() => _parsedResult = null);
        return;
      }

      setState(() {
        _image = File(pickedFile.path);
        _isLoading = true;
        _parsedResult = null;
      });

      Map<String, dynamic> jsonResp;

      if (_useOnDeviceInference && TfliteService.isLoaded) {
        try {
          final result = await TfliteService.predictFromFile(_image!);
          final double damage = result.isUncertain
              ? 0.0
              : ((1.0 - result.confidence) * 80.0).clamp(5.0, 80.0);

          jsonResp = {
            'crop': result.disease,
            'status': result.isUncertain ? 'Uncertain' : 'Diseased',
            'disease': result.disease,
            'confidence_percent': result.confidencePercent,
            'damage_percent': damage,
            'severity': result.isUncertain
                ? 'Unknown'
                : CropAnalyzerPage.getSeverity(damage),
            'inference_ms': result.inferenceMs,
            'source': 'on_device',
            if (result.isUncertain)
              'message':
                  'Confidence too low (${result.confidencePercent.toStringAsFixed(1)}%). Retake with better lighting.',
          };
        } catch (e) {
          debugPrint('⚠️ On-device failed → fallback to server: $e');
          try {
            jsonResp = await ApiService.uploadImage(_image!);
            jsonResp['source'] = 'server_fallback';
          } catch (serverError) {
            debugPrint('❌ Server also failed: $serverError');
            jsonResp = {
              'status': 'Uncertain',
              'message': '⚡ Running on-device AI. Server skipped.',
              'damage_percent': 0.0,
              'confidence_percent': 0.0,
              'source': 'on_device',
            };
          }
        }
      } else {
        try {
          jsonResp = await ApiService.uploadImage(_image!);
          jsonResp['source'] = 'server';
        } catch (e) {
          debugPrint('❌ Server failed: $e');
          jsonResp = {
            'status': 'Uncertain',
            'message': '⚡ Running on-device AI. Server skipped.',
            'damage_percent': 0.0,
            'confidence_percent': 0.0,
            'source': 'on_device',
          };
        }
      }

      setState(() {
        _parsedResult = jsonResp;
        _isLoading = false;
      });

      // ── Blynk: send damage % to V4 ───────────────────────────────────────
      if (_parsedResult != null && _parsedResult!['damage_percent'] != null) {
        final int currentDamage =
            (_parsedResult!['damage_percent'] as num).toInt();
        if (lastSentDamagePercent != currentDamage) {
          await blynk.setVirtualPin(4, currentDamage);
          lastSentDamagePercent = currentDamage;
          debugPrint('Sent damage percent: $currentDamage to Blynk');
        } else {
          debugPrint('Damage unchanged, skipping send');
        }
      }
    } catch (e) {
      setState(() {
        _parsedResult = {
          'status': 'Uncertain',
          'message': '⚡ Something went wrong. Using offline AI.',
          'damage_percent': 0.0,
          'confidence_percent': 0.0,
          'source': 'on_device',
        };
        _isLoading = false;
      });
    }
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

  Widget motorStatusWidget() {
    return Text(
      motorRunning
          ? 'Motor ON - Running for $runTimeLeft seconds'
          : 'Motor OFF',
      style: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: motorRunning ? Colors.green : Colors.red,
      ),
    );
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
              onPressed: () {
                setState(() {
                  _useOnDeviceInference = !_useOnDeviceInference;
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      _useOnDeviceInference
                          ? '📱 On-device TFLite inference'
                          : '☁️ Server inference',
                    ),
                    duration: const Duration(seconds: 2),
                  ),
                );
              },
            ),
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
                                    "${_parsedResult!['error']}\n⚡ Switching to offline AI mode",
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

                        // ── Motor Status Card (V5) ─────────────────────────
                        Card(
                          margin: const EdgeInsets.symmetric(vertical: 8),
                          child: ListTile(
                            leading: Icon(
                              isMotorRunning
                                  ? Icons.flash_on
                                  : Icons.flash_off,
                              color:
                                  isMotorRunning ? Colors.green : Colors.red,
                            ),
                            title: const Text("Motor Status"),
                            subtitle: Text(
                              isMotorRunning ? "Running" : "Stopped",
                              style: TextStyle(
                                color: isMotorRunning
                                    ? Colors.green
                                    : Colors.red,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        motorStatusWidget(),
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
