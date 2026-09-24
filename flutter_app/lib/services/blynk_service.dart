import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class BlynkService {
  final String authToken;
  final String baseUrl = 'https://blynk.cloud/external/api';

  BlynkService(this.authToken);

  // 🔥 SET VIRTUAL PIN
  Future<void> setVirtualPin(int pin, dynamic value) async {
    final url = Uri.parse('$baseUrl/update?token=$authToken&V$pin=$value');

    try {
      final response = await http.get(url);

      debugPrint("Blynk UPDATE URL: $url");
      debugPrint("Status Code: ${response.statusCode}");
      debugPrint("Response Body: ${response.body}");

      if (response.statusCode != 200) {
        throw Exception(
            'Failed to set virtual pin $pin. Status: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint("Error sending to Blynk: $e");
      rethrow;
    }
  }

  // 🔥 GET VIRTUAL PIN
  Future<int> getVirtualPin(int pin) async {
    final url = Uri.parse('$baseUrl/get?token=$authToken&V$pin');

    try {
      final response = await http.get(url);

      debugPrint("Blynk GET URL: $url");
      debugPrint("Status Code: ${response.statusCode}");
      debugPrint("Response Body: ${response.body}");

      if (response.statusCode == 200) {
        return int.tryParse(response.body.trim()) ?? 0;
      } else {
        throw Exception(
            'Failed to get virtual pin $pin. Status: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint("Error getting from Blynk: $e");
      rethrow;
    }
  }

  // 🔥 GET MOTOR STATUS (V5)
  Future<bool> getMotorStatus() async {
    final url = Uri.parse('$baseUrl/get?token=$authToken&V5');
    try {
      final response = await http.get(url);
      debugPrint("Motor status URL: $url");
      debugPrint("Motor status response: ${response.body}");
      if (response.statusCode == 200) {
        return response.body.trim() == "1";
      }
    } catch (e) {
      debugPrint("Motor status error: $e");
    }
    return false;
  }
}
