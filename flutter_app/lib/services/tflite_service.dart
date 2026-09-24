import 'dart:io';
// ignore: unnecessary_import — Float32List is not re-exported by flutter/foundation.dart
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CONSTANTS — must match the trained model exactly
// ─────────────────────────────────────────────────────────────────────────────
const String _modelAsset = 'assets/models/crop_model_float16.tflite';
const int _inputSize = 224;
const int _numClasses = 7;
const double _confidenceThreshold = 0.60;

const List<String> _classLabels = [
  'Anthracnose',
  'Bacterial_Leaf_Spot',
  'Black_rot',
  'Downy_Mildew',
  'Mosaic_Disease',
  'Powdery_Mildew',
  'Rust',
];

// ─────────────────────────────────────────────────────────────────────────────
// RESULT MODEL
// ─────────────────────────────────────────────────────────────────────────────
class TfliteResult {
  final String disease;
  final double confidence;
  final bool isUncertain;
  final List<double> allProbs;
  final int inferenceMs;

  const TfliteResult({
    required this.disease,
    required this.confidence,
    required this.isUncertain,
    required this.allProbs,
    required this.inferenceMs,
  });

  double get confidencePercent => confidence * 100;

  @override
  String toString() =>
      'TfliteResult(disease: $disease, confidence: ${confidencePercent.toStringAsFixed(1)}%, '
      'uncertain: $isUncertain, inferenceMs: $inferenceMs)';
}

// ─────────────────────────────────────────────────────────────────────────────
// TFLITE SERVICE
// ─────────────────────────────────────────────────────────────────────────────
class TfliteService {
  static Interpreter? _interpreter;
  static bool _isLoaded = false;

  // ── Model loading ──────────────────────────────────────────────────────────

  static Future<void> loadModel() async {
    if (_isLoaded) return;
    try {
      _interpreter = await Interpreter.fromAsset(_modelAsset);

      final outputShape = _interpreter!.getOutputTensor(0).shape;
      debugPrint('✅ TFLite model loaded: $_modelAsset');
      debugPrint('   Input  shape: ${_interpreter!.getInputTensor(0).shape}');
      debugPrint('   Output shape: $outputShape');

      if (outputShape.last != _numClasses) {
        debugPrint('⚠️  WARNING: model output size (${outputShape.last}) '
            'does not match _numClasses ($_numClasses). '
            'Update _classLabels or _numClasses.');
      }

      _isLoaded = true;
    } catch (e) {
      debugPrint('❌ Failed to load TFLite model: $e');
      rethrow;
    }
  }

  static bool get isLoaded => _isLoaded;

  // ── Image → tensor ─────────────────────────────────────────────────────────

  static Float32List imageFileToTensor(File imageFile) {
    final bytes = imageFile.readAsBytesSync();
    return _bytesToTensor(bytes);
  }

  static Float32List imageBytesToTensor(Uint8List imageBytes) {
    return _bytesToTensor(imageBytes);
  }

  static Float32List _bytesToTensor(List<int> bytes) {
    img.Image? decoded = img.decodeImage(Uint8List.fromList(bytes));
    if (decoded == null) {
      throw Exception('Could not decode image bytes');
    }

    final resized = img.copyResize(
      decoded,
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

    return tensor;
  }

  // ── Inference ──────────────────────────────────────────────────────────────

  static Future<TfliteResult> predictFromFile(File imageFile) async {
    final tensor = imageFileToTensor(imageFile);
    return _runInference(tensor);
  }

  static Future<TfliteResult> predictFromBytes(Uint8List imageBytes) async {
    final tensor = imageBytesToTensor(imageBytes);
    return _runInference(tensor);
  }

  static Future<TfliteResult> _runInference(Float32List inputTensor) async {
    if (!_isLoaded || _interpreter == null) {
      throw StateError('Model not loaded. Call TfliteService.loadModel() first.');
    }

    final input = inputTensor.reshape([1, _inputSize, _inputSize, 3]);
    final output = List.generate(1, (_) => List<double>.filled(_numClasses, 0.0));

    final stopwatch = Stopwatch()..start();
    _interpreter!.run(input, output);
    stopwatch.stop();

    final int inferenceMs = stopwatch.elapsedMilliseconds;
    final List<double> probs = output[0];

    int maxIdx = 0;
    double maxProb = probs[0];
    for (int i = 1; i < probs.length; i++) {
      if (probs[i] > maxProb) {
        maxProb = probs[i];
        maxIdx = i;
      }
    }

    final bool uncertain = maxProb < _confidenceThreshold;
    final String label = uncertain ? 'Uncertain' : _classLabels[maxIdx];

    debugPrint('🔍 TFLite inference: $label '
        '(${(maxProb * 100).toStringAsFixed(1)}%) '
        '| ${inferenceMs}ms');

    if (uncertain) {
      debugPrint('   ⚠️  Confidence ${(maxProb * 100).toStringAsFixed(1)}% '
          '< threshold ${(_confidenceThreshold * 100).toStringAsFixed(0)}% → Uncertain');
    }

    return TfliteResult(
      disease: label,
      confidence: maxProb,
      isUncertain: uncertain,
      allProbs: probs,
      inferenceMs: inferenceMs,
    );
  }

  // ── Cleanup ────────────────────────────────────────────────────────────────

  static void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _isLoaded = false;
    debugPrint('🛑 TFLite interpreter closed');
  }
}
