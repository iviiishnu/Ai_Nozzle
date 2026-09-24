import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config.dart';

/// Thrown when the backend can't be reached (not configured, offline,
/// timeout, or the ML service behind it is down). Callers may fall back
/// to on-device inference.
class ServerUnavailableException implements Exception {
  final String message;
  ServerUnavailableException(this.message);
  @override
  String toString() => message;
}

class ApiService {
  static const Duration _timeout = Duration(seconds: 60);

  static Uri _uri(String path) {
    final base = AppConfig.backendUrl;
    if (base.isEmpty) {
      throw ServerUnavailableException('Server URL not set (open Settings).');
    }
    return Uri.parse('$base$path');
  }

  /// Sends an image to the Spring backend.
  /// Returns the result JSON, or `{"error": ...}` for a request the server
  /// rejected (e.g. no leaf detected). Throws [ServerUnavailableException]
  /// when the server can't be reached.
  static Future<Map<String, dynamic>> uploadImage(File imageFile) async {
    final request = http.MultipartRequest('POST', _uri('/api/crop/analyze'))
      ..files.add(await http.MultipartFile.fromPath('file', imageFile.path));

    final http.StreamedResponse streamed;
    final String body;
    try {
      streamed = await request.send().timeout(_timeout);
      body = await streamed.stream.bytesToString();
    } on SocketException catch (e) {
      throw ServerUnavailableException('Cannot reach server: ${e.message}');
    } on TimeoutException {
      throw ServerUnavailableException('Server timed out');
    } on http.ClientException catch (e) {
      throw ServerUnavailableException('Cannot reach server: ${e.message}');
    }

    Map<String, dynamic>? data;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) data = decoded;
    } on FormatException {
      data = null;
    }

    final status = streamed.statusCode;
    if (status == 200 && data != null) {
      data['confidence_percent'] = (data['confidence_percent'] ?? 0).toDouble();
      data['damage_percent'] = (data['damage_percent'] ?? 0).toDouble();
      return data;
    }
    if (status == 502 || status == 503 || status == 504) {
      throw ServerUnavailableException(
          data?['error']?.toString() ?? 'Server unavailable ($status)');
    }
    return {
      'error': data?['error'] ?? 'Server returned $status',
      if (data?['message'] != null) 'message': data!['message'],
    };
  }
}
