import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uvccamera/uvccamera.dart';

/// Drives the USB/OTG webcam directly over UVC.
///
/// The tablet's camera service doesn't list USB webcams (no external-camera
/// HAL), so the regular `camera` plugin only ever sees the built-in cameras.
/// This talks to the webcam through Android's USB host API instead.
///
/// Flow: find a UVC device → camera permission → USB permission → the plugin
/// reports "connected" → open the preview. Unplug/replug is handled.
class UsbWebcam extends ChangeNotifier {
  UvcCameraDevice? _device;
  UvcCameraController? _controller;
  StreamSubscription<UvcCameraDeviceEvent>? _deviceEvents;
  StreamSubscription<UvcCameraErrorEvent>? _errorEvents;
  bool _started = false;
  bool _disposed = false;

  /// Human-readable state for the UI while the preview isn't ready.
  String status = 'Looking for USB webcam…';

  UvcCameraController? get controller => _controller;
  bool get isReady => _controller?.value.isInitialized ?? false;
  String? get deviceName => _device?.name;

  Future<void> start() async {
    if (_started) return;
    _started = true;

    if (!await UvcCamera.isSupported()) {
      _setStatus('This device does not support USB cameras.');
      return;
    }

    _deviceEvents = UvcCamera.deviceEventStream.listen(_onDeviceEvent);

    final devices = await UvcCamera.getDevices();
    debugPrint('📷 USB webcams found: ${devices.keys.join(', ')}');
    if (devices.isEmpty) {
      _setStatus('USB webcam not connected.\nPlug it in through the OTG cable.');
      return;
    }
    await _requestAccess(devices.values.first);
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    await _deviceEvents?.cancel();
    _deviceEvents = null;
    await _closeController();
    _device = null;
    _setStatus('Looking for USB webcam…');
  }

  /// Captures a JPEG from the webcam.
  Future<File> takePicture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      throw StateError('USB webcam is not ready');
    }
    final shot = await controller.takePicture();
    return File(shot.path);
  }

  Future<void> _requestAccess(UvcCameraDevice device) async {
    _device = device;
    _setStatus('Requesting camera permission…');

    // USB video devices also need the CAMERA runtime permission.
    final camera = await Permission.camera.request();
    if (!camera.isGranted) {
      _setStatus('Camera permission denied.\nAllow it in Android settings.');
      return;
    }

    _setStatus('Allow access to "${device.name}" in the popup…');
    // Granting USB permission makes the plugin connect and emit `connected`.
    final granted = await UvcCamera.requestDevicePermission(device);
    if (!granted) {
      _setStatus('USB permission denied.\nUnplug and replug the webcam to retry.');
    }
  }

  Future<void> _onDeviceEvent(UvcCameraDeviceEvent event) async {
    debugPrint('📷 USB webcam ${event.type.name}: ${event.device.name}');
    switch (event.type) {
      case UvcCameraDeviceEventType.attached:
        if (_device == null) await _requestAccess(event.device);
      case UvcCameraDeviceEventType.connected:
        if (_device?.name == event.device.name || _device == null) {
          _device = event.device;
          await _openController();
        }
      case UvcCameraDeviceEventType.disconnected:
        if (_device?.name == event.device.name) await _closeController();
      case UvcCameraDeviceEventType.detached:
        if (_device?.name == event.device.name) {
          await _closeController();
          _device = null;
          _setStatus('USB webcam unplugged.\nPlug it back in to continue.');
        }
    }
  }

  Future<void> _openController() async {
    final device = _device;
    if (device == null || _controller != null) return;
    _setStatus('Opening "${device.name}"…');

    // ~720p: plenty for the 224×224 model and keeps uploads small.
    final controller = UvcCameraController(
      device: device,
      resolutionPreset: UvcCameraResolutionPreset.medium,
    );
    _controller = controller;
    try {
      await controller.initialize();
      _errorEvents = controller.cameraErrorEvents.listen((e) async {
        debugPrint('📷 USB webcam error: ${e.error}');
        if (e.error.type == UvcCameraErrorType.previewInterrupted) {
          await _closeController();
          await _openController();
        }
      });
      _setStatus('USB webcam ready');
    } catch (e) {
      debugPrint('📷 USB webcam open failed: $e');
      _controller = null;
      await controller.dispose();
      _setStatus('Could not open the USB webcam:\n$e');
    }
  }

  Future<void> _closeController() async {
    await _errorEvents?.cancel();
    _errorEvents = null;
    final controller = _controller;
    _controller = null;
    if (controller != null) await controller.dispose();
    _setStatus('USB webcam disconnected.');
  }

  void _setStatus(String value) {
    status = value;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
