import 'package:shared_preferences/shared_preferences.dart';

/// App configuration — nothing environment-specific is hardcoded here.
///
/// Values are resolved in this order:
///   1. Saved on the device from the in-app Settings screen
///   2. Build-time defaults passed with
///        flutter run --dart-define-from-file=config/app_config.json
///      (see config/app_config.example.json)
///   3. Empty / safe defaults below
class AppConfig {
  AppConfig._();

  // ── Build-time defaults (--dart-define) ───────────────────────────────────
  static const String _defaultBackendUrl =
      String.fromEnvironment('BACKEND_URL');
  static const String _defaultBlynkServer =
      String.fromEnvironment('BLYNK_SERVER', defaultValue: 'blynk.cloud');
  static const String _defaultBlynkToken =
      String.fromEnvironment('BLYNK_AUTH_TOKEN');

  // ── Decision thresholds (override with --dart-define) ─────────────────────
  // Keep in sync with ai_service/.env (DAMAGE_MEDIUM / DAMAGE_HIGH /
  // CONFIDENCE_THRESHOLD) and the ESP32 firmware (SPRAY_MIN_DAMAGE).
  static final double confidenceThreshold =
      _doubleDefine(const String.fromEnvironment('CONFIDENCE_THRESHOLD'), 0.50);
  static final double damageMedium = // ≥ → Medium, spray
      _doubleDefine(const String.fromEnvironment('DAMAGE_MEDIUM'), 15);
  static final double damageHigh = // ≥ → High
      _doubleDefine(const String.fromEnvironment('DAMAGE_HIGH'), 35);

  static double _doubleDefine(String value, double fallback) =>
      double.tryParse(value) ?? fallback;

  // ── Blynk virtual pins (must match the ESP32 firmware + Blynk template) ──
  static const int damagePin = 4; // app → ESP32: damage %
  static const int motorStatusPin = 5; // ESP32 → app: 1 = motor running

  // ── Keys for saved settings ───────────────────────────────────────────────
  static const _kBackendUrl = 'backend_url';
  static const _kBlynkServer = 'blynk_server';
  static const _kBlynkToken = 'blynk_token';
  static const _kUseOnDevice = 'use_on_device';
  static const _kLiveInterval = 'live_interval_s';

  static SharedPreferences? _prefs;

  static Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
  }

  static String _get(String key, String fallback) =>
      _prefs?.getString(key) ?? fallback;

  /// Spring backend base URL, e.g. http://192.168.1.20:8000 (no trailing /).
  static String get backendUrl =>
      _get(_kBackendUrl, _defaultBackendUrl).trim().replaceAll(RegExp(r'/+$'), '');

  /// Blynk cloud host for your account region, e.g. blynk.cloud or blr1.blynk.cloud.
  static String get blynkServer => _get(_kBlynkServer, _defaultBlynkServer).trim();

  static String get blynkToken => _get(_kBlynkToken, _defaultBlynkToken).trim();

  static bool get iotConfigured => blynkToken.isNotEmpty && blynkServer.isNotEmpty;

  /// true = run the TFLite model on the tablet; false = send to the backend.
  static bool get useOnDevice => _prefs?.getBool(_kUseOnDevice) ?? true;

  /// Seconds between captures on the Live Camera screen.
  static int get liveIntervalSeconds => _prefs?.getInt(_kLiveInterval) ?? 5;

  static Future<void> save({
    required String backendUrl,
    required String blynkServer,
    required String blynkToken,
    required bool useOnDevice,
    required int liveIntervalSeconds,
  }) async {
    final p = _prefs ??= await SharedPreferences.getInstance();
    await p.setString(_kBackendUrl, backendUrl.trim());
    await p.setString(_kBlynkServer, blynkServer.trim());
    await p.setString(_kBlynkToken, blynkToken.trim());
    await p.setBool(_kUseOnDevice, useOnDevice);
    await p.setInt(_kLiveInterval, liveIntervalSeconds);
  }

  static Future<void> setUseOnDevice(bool value) async {
    final p = _prefs ??= await SharedPreferences.getInstance();
    await p.setBool(_kUseOnDevice, value);
  }

  static String severityFor(double damagePercent) {
    if (damagePercent < damageMedium) return 'Low';
    if (damagePercent < damageHigh) return 'Medium';
    return 'High';
  }
}
