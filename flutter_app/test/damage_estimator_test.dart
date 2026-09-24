import 'package:flutter_app/services/damage_estimator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

img.Image _solid(int w, int h, int r, int g, int b) =>
    img.Image(width: w, height: h)..clear(img.ColorRgb8(r, g, b));

void main() {
  const green = (60, 160, 50);
  const brown = (140, 80, 30);

  test('healthy green leaf → ~0% damage', () {
    final r = DamageEstimator.analyze(_solid(300, 300, green.$1, green.$2, green.$3));
    expect(r.leafFraction, closeTo(1.0, 0.01));
    expect(r.damagePercent, lessThan(1));
  });

  test('half brown leaf → ~50% damage', () {
    final image = _solid(300, 300, green.$1, green.$2, green.$3);
    img.fillRect(image,
        x1: 0, y1: 0, x2: 149, y2: 299, color: img.ColorRgb8(brown.$1, brown.$2, brown.$3));
    final r = DamageEstimator.analyze(image);
    expect(r.damagePercent, closeTo(50, 3));
  });

  test('grey background is not a leaf', () {
    final r = DamageEstimator.analyze(_solid(300, 300, 128, 128, 128));
    expect(r.leafFraction, lessThan(DamageEstimator.minLeafFraction));
    expect(r.damagePercent, 0);
  });

  test('blue object is not a leaf', () {
    final r = DamageEstimator.analyze(_solid(300, 300, 0, 50, 200));
    expect(r.leafFraction, lessThan(DamageEstimator.minLeafFraction));
  });
}
