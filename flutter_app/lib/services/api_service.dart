import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../config.dart';

class ApiService {
  // Uploads an image file to backend
  static Future<Map<String, dynamic>> uploadImage(File imageFile) async {
    final uri = Uri.parse('${BASE_URL}api/crop/analyze');
    try {
      final request = http.MultipartRequest('POST', uri)
        ..files.add(await http.MultipartFile.fromPath('file', imageFile.path));
      final streamedResponse = await request.send();
      final respStr = await streamedResponse.stream.bytesToString();

      if (streamedResponse.statusCode == 200) {
        try {
          final Map<String, dynamic> data = jsonDecode(respStr);
          data['confidence_percent'] =
              (data['confidence_percent'] ?? 0).toDouble();
          data['damage_percent'] =
              (data['damage_percent'] ?? 0).toDouble();
          return data;
        } catch (e) {
          return {"error": "Invalid JSON from server: $e", "raw": respStr};
        }
      } else {
        return {
          "error": "Server returned ${streamedResponse.statusCode}",
          "raw": respStr
        };
      }
    } on SocketException {
      return {"error": "No internet connection"};
    } on HttpException {
      return {"error": "HTTP error occurred"};
    } on FormatException {
      return {"error": "Bad response format"};
    } catch (e) {
      return {"error": "Unexpected exception: $e"};
    }
  }

  // Uploads in-memory image bytes (e.g. camera snapshot)
  static Future<Map<String, dynamic>> uploadImageBytes(Uint8List imageBytes) async {
    final uri = Uri.parse('${BASE_URL}api/crop/analyze');
    try {
      var request = http.MultipartRequest('POST', uri)
        ..files.add(http.MultipartFile.fromBytes('file', imageBytes, filename: 'frame.jpg'));
      final streamedResponse = await request.send();
      final respStr = await streamedResponse.stream.bytesToString();

      if (streamedResponse.statusCode == 200) {
        try {
          final Map<String, dynamic> data = jsonDecode(respStr);
          data['confidence_percent'] =
              (data['confidence_percent'] ?? 0).toDouble();
          data['damage_percent'] =
              (data['damage_percent'] ?? 0).toDouble();
          return data;
        } catch (e) {
          return {"error": "Invalid JSON from server: $e", "raw": respStr};
        }
      } else {
        return {
          "error": "Server returned ${streamedResponse.statusCode}",
          "raw": respStr
        };
      }
    } on SocketException {
      return {"error": "No internet connection"};
    } on HttpException {
      return {"error": "HTTP error occurred"};
    } on FormatException {
      return {"error": "Bad response format"};
    } catch (e) {
      return {"error": "Unexpected exception: $e"};
    }
  }
}
