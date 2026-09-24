import 'dart:io';

import 'package:flutter/foundation.dart';

import '../config.dart';
import 'api_service.dart';
import 'blynk_service.dart';
import 'tflite_service.dart';

/// Single place that turns an image into a result and forwards it to the
/// sprayer. Used by both the photo screen and the live camera screen.
///
/// Result map keys (same as the server JSON):
///   status: 'Diseased' | 'Uncertain' | 'Error'
///   disease, confidence_percent, damage_percent, severity,
///   spray_recommended, message, source, inference_ms, error
class AnalysisService {
  AnalysisService._();

  static Future<Map<String, dynamic>> analyze(File image) async {
    final onDevice = AppConfig.useOnDevice && TfliteService.isLoaded;

    if (!onDevice) {
      try {
        final result = await ApiService.uploadImage(image);
        result['source'] = 'server';
        return _normalize(result);
      } on ServerUnavailableException catch (e) {
        if (!TfliteService.isLoaded) return _error(e.message);
        debugPrint('Server unavailable ($e) → on-device fallback');
        final result = await _onDevice(image);
        result['source'] = 'on_device_fallback';
        result['note'] = 'Server unavailable: ${e.message}';
        return result;
      }
    }

    try {
      return await _onDevice(image);
    } catch (e) {
      return _error('On-device analysis failed: $e');
    }
  }

  static Future<Map<String, dynamic>> _onDevice(File image) async {
    final r = await TfliteService.predictFromFile(image);

    if (!r.leafDetected) {
      return _error('No leaf detected.',
          message: 'Please capture a clear photo of a crop leaf.',
          source: 'on_device');
    }
    if (r.isUncertain) {
      return {
        'status': 'Uncertain',
        'disease': 'Uncertain',
        'confidence_percent': r.confidencePercent,
        'damage_percent': 0.0,
        'severity': 'Unknown',
        'spray_recommended': false,
        'message': 'Model confidence too low '
            '(${r.confidencePercent.toStringAsFixed(1)}%). '
            'Please retake the photo with better lighting and a clear leaf.',
        'inference_ms': r.inferenceMs,
        'source': 'on_device',
      };
    }
    return {
      'status': 'Diseased',
      'disease': r.disease,
      'confidence_percent': r.confidencePercent,
      'damage_percent': r.damagePercent,
      'severity': AppConfig.severityFor(r.damagePercent),
      'spray_recommended': r.damagePercent >= AppConfig.damageMedium,
      'inference_ms': r.inferenceMs,
      'source': 'on_device',
    };
  }

  static Map<String, dynamic> _normalize(Map<String, dynamic> r) {
    if (r['error'] != null) {
      r['status'] = 'Error';
      return r;
    }
    final damage = (r['damage_percent'] as num?)?.toDouble() ?? 0.0;
    r['damage_percent'] = damage;
    r['severity'] ??= AppConfig.severityFor(damage);
    r['spray_recommended'] ??= damage >= AppConfig.damageMedium;
    return r;
  }

  static Map<String, dynamic> _error(String error,
          {String? message, String source = 'on_device'}) =>
      {
        'status': 'Error',
        'error': error,
        if (message != null) 'message': message,
        'source': source,
      };

  /// Sends the damage % to the ESP32 via Blynk (the firmware decides whether
  /// and how long to spray). Only diseased results are sent.
  /// Returns a short status line for the UI.
  static Future<String> sendToSprayer(Map<String, dynamic> result) async {
    if (result['status'] != 'Diseased') return 'Not sent (no confirmed disease)';
    if (!AppConfig.iotConfigured) return 'IoT not configured';

    final damage = (result['damage_percent'] as num).round();
    try {
      await BlynkService.setVirtualPin(AppConfig.damagePin, damage);
      return 'Sent $damage% to sprayer';
    } catch (e) {
      debugPrint('Blynk send failed: $e');
      return 'Sprayer unreachable';
    }
  }
}
