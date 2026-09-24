import 'package:image/image.dart' as img;

/// Pixel-based leaf detection and damage estimate.
///
/// Dart port of ai_service/preprocessing.py (`_leaf_masks`,
/// `estimate_damage_percent`) — same HSV thresholds on the same OpenCV scale
/// (H 0–180, S/V 0–255). Keep both in sync.
///
///   leaf    = saturated, not too dark, hue red-brown … green
///   healthy = leaf with green hue
///   damage% = (leaf − healthy) / leaf × 100
class DamageEstimator {
  DamageEstimator._();

  static const int workSize = 224;
  static const int leafMinSat = 40;
  static const int leafMinVal = 40;
  static const int leafHueMin = 5, leafHueMax = 90;
  static const int healthyHueMin = 35, healthyHueMax = 85;
  static const double minLeafFraction = 0.04;

  /// Returns (leafFraction 0–1, damagePercent 0–100).
  static ({double leafFraction, double damagePercent}) analyze(img.Image image) {
    final small = (image.width == workSize && image.height == workSize)
        ? image
        : img.copyResize(image,
            width: workSize,
            height: workSize,
            interpolation: img.Interpolation.average);

    int leaf = 0, healthy = 0;
    for (final pixel in small) {
      final hsv = _toHsv(pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt());
      final h = hsv.$1, s = hsv.$2, v = hsv.$3;
      if (s >= leafMinSat && v >= leafMinVal && h >= leafHueMin && h <= leafHueMax) {
        leaf++;
        if (h >= healthyHueMin && h <= healthyHueMax) healthy++;
      }
    }

    final total = small.width * small.height;
    final damage = leaf == 0 ? 0.0 : (1.0 - healthy / leaf) * 100.0;
    return (
      leafFraction: leaf / total,
      damagePercent: double.parse(damage.toStringAsFixed(2)),
    );
  }

  /// RGB (0–255) → HSV on OpenCV's 8-bit scale: H 0–180, S 0–255, V 0–255.
  static (int, int, int) _toHsv(int r, int g, int b) {
    final maxC = r > g ? (r > b ? r : b) : (g > b ? g : b);
    final minC = r < g ? (r < b ? r : b) : (g < b ? g : b);
    final delta = maxC - minC;

    final v = maxC;
    final s = maxC == 0 ? 0 : (255 * delta / maxC).round();

    double hDeg;
    if (delta == 0) {
      hDeg = 0;
    } else if (maxC == r) {
      hDeg = 60 * (g - b) / delta;
    } else if (maxC == g) {
      hDeg = 120 + 60 * (b - r) / delta;
    } else {
      hDeg = 240 + 60 * (r - g) / delta;
    }
    if (hDeg < 0) hDeg += 360;
    return ((hDeg / 2).round() % 180, s, v);
  }
}
