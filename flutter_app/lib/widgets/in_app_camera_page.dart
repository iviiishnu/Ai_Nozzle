import 'package:flutter/material.dart';
import 'package:uvccamera/uvccamera.dart';

import '../services/usb_webcam.dart';

/// In-app camera screen.
/// ─────────────────────
/// Shows the USB/OTG webcam (never the tablet's built-in cameras) and captures
/// a still from it.
///
/// Pops with the captured [File], or null if the user backs out.
class InAppCameraPage extends StatefulWidget {
  const InAppCameraPage({super.key});

  @override
  State<InAppCameraPage> createState() => _InAppCameraPageState();
}

class _InAppCameraPageState extends State<InAppCameraPage>
    with WidgetsBindingObserver {
  final UsbWebcam _webcam = UsbWebcam();
  bool _isCapturing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _webcam.start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _webcam.dispose();
    super.dispose();
  }

  // Release the webcam when the app goes to background, reopen on resume.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _webcam.stop();
    } else if (state == AppLifecycleState.resumed) {
      _webcam.start();
    }
  }

  Future<void> _capture() async {
    if (!_webcam.isReady || _isCapturing) return;
    setState(() => _isCapturing = true);
    try {
      final file = await _webcam.takePicture();
      if (mounted) Navigator.pop(context, file);
    } catch (e) {
      if (mounted) {
        setState(() => _isCapturing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Capture failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Capture Leaf (USB webcam)'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: ListenableBuilder(
        listenable: _webcam,
        builder: (context, _) {
          final controller = _webcam.controller;
          final ready = _webcam.isReady;
          return Column(
            children: [
              Expanded(
                child: Center(
                  child: ready
                      ? UvcCameraPreview(controller!)
                      : Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.usb,
                                  color: Colors.white54, size: 48),
                              const SizedBox(height: 16),
                              Text(
                                _webcam.status,
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 16),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: FloatingActionButton.large(
                  onPressed: ready && !_isCapturing ? _capture : null,
                  backgroundColor: ready ? Colors.white : Colors.grey,
                  child: _isCapturing
                      ? const CircularProgressIndicator()
                      : const Icon(Icons.camera, color: Colors.black, size: 48),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
