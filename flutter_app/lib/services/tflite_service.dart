import 'dart:convert';
import 'dart:io';
// ignore: unnecessary_import — Float32List is not re-exported by flutter/foundation.dart
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../config.dart';
import 'damage_estimator.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CONSTANTS — must match the trained model exactly
// ─────────────────────────────────────────────────────────────────────────────
// Override at build time with --dart-define=MODEL_ASSET=... / CLASS_NAMES_ASSET=...
const String _modelAsset = String.fromEnvironment('MODEL_ASSET',
    defaultValue: 'assets/models/crop_model_float16.tflite');
// Same file as ai_service/models/class_names.json (written by train_model.py)
const String _classNamesAsset = String.fromEnvironment('CLASS_NAMES_ASSET',
    defaultValue: 'assets/models/class_names.json');
const int _inputSize = 224;

// ─────────────────────────────────────────────────────────────────────────────
// RESULT MODEL
// ─────────────────────────────────────────────────────────────────────────────
class TfliteResult {
  final String disease;
  final double confidence;
  final bool isUncertain;
  final bool leafDetected;
  final double damagePercent;
  final List<double> allProbs;
  final int inferenceMs;

  const TfliteResult({
    required this.disease,
    required this.confidence,
    required this.isUncertain,
    required this.leafDetected,
    required this.damagePercent,
    required this.allProbs,
    required this.inferenceMs,
  });

  double get confidencePercent => confidence * 100;

  @override
  String toString() =>
      'TfliteResult(disease: $disease, confidence: ${confidencePercent.toStringAsFixed(1)}%, '
      'damage: $damagePercent%, leaf: $leafDetected, inferenceMs: $inferenceMs)';
}

/// Output of the background preprocessing step.
class _Prepared {
  final Float32List tensor;
  final double leafFraction;
  final double damagePercent;
  const _Prepared(this.tensor, this.leafFraction, this.damagePercent);
}

/// Runs in a background isolate: decode → fix EXIF rotation → model tensor
/// (resize 224×224, /255 — same as training and the server) + damage estimate.
_Prepared _prepare(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw Exception('Could not decode image bytes');
  final image = img.bakeOrientation(decoded);

  final resized = img.copyResize(
    image,
    width: _inputSize,
    height: _inputSize,
    interpolation: img.Interpolation.linear,
  );

  final tensor = Float32List(_inputSize * _inputSize * 3);
  int idx = 0;
  for (int y = 0; y < _inputSize; y++) {
    for (int x = 0; x < _inputSize; x++) {
      final pixel = resized.getPixel(x, y);
      tensor[idx++] = pixel.r / 255.0;
      tensor[idx++] = pixel.g / 255.0;
      tensor[idx++] = pixel.b / 255.0;
    }
  }

  final damage = DamageEstimator.analyze(image);
  return _Prepared(tensor, damage.leafFraction, damage.damagePercent);
}

// ─────────────────────────────────────────────────────────────────────────────
// TFLITE SERVICE
// ─────────────────────────────────────────────────────────────────────────────
class TfliteService {
  static Interpreter? _interpreter;
  static List<String> _classLabels = const [];
  static bool _isLoaded = false;

  static Future<void> loadModel() async {
    if (_isLoaded) return;
    try {
      _classLabels = List<String>.from(
          jsonDecode(await rootBundle.loadString(_classNamesAsset)) as List);
      _interpreter = await Interpreter.fromAsset(_modelAsset);

      final outputShape = _interpreter!.getOutputTensor(0).shape;
      debugPrint('✅ TFLite model loaded: $_modelAsset');
      debugPrint('   Input  shape: ${_interpreter!.getInputTensor(0).shape}');
      debugPrint('   Output shape: $outputShape');

      if (outputShape.last != _classLabels.length) {
        throw StateError('Model outputs ${outputShape.last} classes but '
            '$_classNamesAsset has ${_classLabels.length} labels.');
      }

      _isLoaded = true;
    } catch (e) {
      debugPrint('❌ Failed to load TFLite model: $e');
      rethrow;
    }
  }

  static bool get isLoaded => _isLoaded;

  static Future<TfliteResult> predictFromFile(File imageFile) async {
    return predictFromBytes(await imageFile.readAsBytes());
  }

  static Future<TfliteResult> predictFromBytes(Uint8List imageBytes) async {
    if (!_isLoaded || _interpreter == null) {
      throw StateError('Model not loaded. Call TfliteService.loadModel() first.');
    }

    final prepared = await compute(_prepare, imageBytes);

    final input = prepared.tensor.reshape([1, _inputSize, _inputSize, 3]);
    final output =
        List.generate(1, (_) => List<double>.filled(_classLabels.length, 0.0));

    final stopwatch = Stopwatch()..start();
    _interpreter!.run(input, output);
    stopwatch.stop();

    final List<double> probs = output[0];
    int maxIdx = 0;
    for (int i = 1; i < probs.length; i++) {
      if (probs[i] > probs[maxIdx]) maxIdx = i;
    }
    final double maxProb = probs[maxIdx];

    final leafDetected = prepared.leafFraction >= DamageEstimator.minLeafFraction;
    final uncertain = maxProb < AppConfig.confidenceThreshold;

    final result = TfliteResult(
      disease: uncertain ? 'Uncertain' : _classLabels[maxIdx],
      confidence: maxProb,
      isUncertain: uncertain,
      leafDetected: leafDetected,
      damagePercent: prepared.damagePercent,
      allProbs: probs,
      inferenceMs: stopwatch.elapsedMilliseconds,
    );
    debugPrint('🔍 $result');
    return result;
  }

  static void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _isLoaded = false;
  }
}
