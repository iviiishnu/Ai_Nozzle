import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';

/// Blynk Cloud HTTP API client. Server and token come from [AppConfig].
/// https://docs.blynk.io/en/blynk.cloud/device-https-api
class BlynkService {
  static const Duration _timeout = Duration(seconds: 10);

  static Uri _uri(String action, String query) => Uri.parse(
      'https://${AppConfig.blynkServer}/external/api/$action'
      '?token=${Uri.encodeQueryComponent(AppConfig.blynkToken)}&$query');

  /// Writes a value to a virtual pin (the ESP32 receives it in BLYNK_WRITE).
  static Future<void> setVirtualPin(int pin, Object value) async {
    if (!AppConfig.iotConfigured) {
      throw StateError('Blynk not configured (open Settings).');
    }
    final response = await http
        .get(_uri('update', 'V$pin=${Uri.encodeQueryComponent('$value')}'))
        .timeout(_timeout);
    if (response.statusCode != 200) {
      throw Exception('Blynk update V$pin failed '
          '(${response.statusCode}): ${response.body}');
    }
  }

  /// Reads the motor status pin written by the ESP32 (1 = running).
  /// Returns null if Blynk is not configured or unreachable.
  static Future<bool?> getMotorStatus() async {
    if (!AppConfig.iotConfigured) return null;
    try {
      final response = await http
          .get(_uri('get', 'V${AppConfig.motorStatusPin}'))
          .timeout(_timeout);
      if (response.statusCode == 200) return response.body.trim() == '1';
      debugPrint('Blynk motor status ${response.statusCode}: ${response.body}');
    } catch (e) {
      debugPrint('Blynk motor status error: $e');
    }
    return null;
  }
}
