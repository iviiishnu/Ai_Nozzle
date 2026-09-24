import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../services/blynk_service.dart';
import '../theme/app_theme.dart';

/// Runtime settings — lets you point the app at a different server or Blynk
/// device without rebuilding. Saved on the device.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _backendUrl =
      TextEditingController(text: AppConfig.backendUrl);
  late final TextEditingController _blynkServer =
      TextEditingController(text: AppConfig.blynkServer);
  late final TextEditingController _blynkToken =
      TextEditingController(text: AppConfig.blynkToken);
  late final TextEditingController _interval =
      TextEditingController(text: '${AppConfig.liveIntervalSeconds}');
  late bool _useOnDevice = AppConfig.useOnDevice;
  bool _showToken = false;
  String? _testResult;

  @override
  void dispose() {
    _backendUrl.dispose();
    _blynkServer.dispose();
    _blynkToken.dispose();
    _interval.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    await AppConfig.save(
      backendUrl: _backendUrl.text,
      blynkServer: _blynkServer.text,
      blynkToken: _blynkToken.text,
      useOnDevice: _useOnDevice,
      liveIntervalSeconds: int.parse(_interval.text),
    );
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _testConnections() async {
    await _saveSilently();
    setState(() => _testResult = 'Testing…');
    final lines = <String>[];

    if (AppConfig.backendUrl.isEmpty) {
      lines.add('Server: not set');
    } else {
      try {
        final r = await http
            .get(Uri.parse('${AppConfig.backendUrl}/api/crop/health'))
            .timeout(const Duration(seconds: 8));
        lines.add(r.statusCode == 200
            ? 'Server: OK (model loaded)'
            : 'Server: HTTP ${r.statusCode} ${r.body}');
      } catch (e) {
        lines.add('Server: unreachable ($e)');
      }
    }

    if (!AppConfig.iotConfigured) {
      lines.add('Blynk: not configured');
    } else {
      final motor = await BlynkService.getMotorStatus();
      lines.add(motor == null
          ? 'Blynk: failed (check server region + token)'
          : 'Blynk: OK (motor ${motor ? 'running' : 'stopped'})');
    }
    if (mounted) setState(() => _testResult = lines.join('\n'));
  }

  Future<void> _saveSilently() => AppConfig.save(
        backendUrl: _backendUrl.text,
        blynkServer: _blynkServer.text,
        blynkToken: _blynkToken.text,
        useOnDevice: _useOnDevice,
        liveIntervalSeconds: int.tryParse(_interval.text) ?? 5,
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: AppColors.primary,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SwitchListTile(
              title: const Text('Analyse on tablet (offline)'),
              subtitle: const Text(
                  'Off = send to server; falls back to tablet if server is down'),
              value: _useOnDevice,
              onChanged: (v) => setState(() => _useOnDevice = v),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _backendUrl,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                hintText: 'http://192.168.1.20:8000',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
              validator: (v) {
                final s = (v ?? '').trim();
                if (s.isEmpty) return null; // allowed: on-device only
                final uri = Uri.tryParse(s);
                return (uri == null || !uri.hasScheme || uri.host.isEmpty)
                    ? 'Enter a full URL, e.g. http://192.168.1.20:8000'
                    : null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _blynkServer,
              decoration: const InputDecoration(
                labelText: 'Blynk server',
                hintText: 'blynk.cloud (or your region, e.g. blr1.blynk.cloud)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _blynkToken,
              obscureText: !_showToken,
              decoration: InputDecoration(
                labelText: 'Blynk device auth token',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_showToken ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _showToken = !_showToken),
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _interval,
              decoration: const InputDecoration(
                labelText: 'Live scan interval (seconds)',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              validator: (v) {
                final n = int.tryParse(v ?? '');
                return (n == null || n < 2 || n > 300) ? '2–300' : null;
              },
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _testConnections,
                    icon: const Icon(Icons.network_check),
                    label: const Text('Test connections'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.save),
                    label: const Text('Save'),
                  ),
                ),
              ],
            ),
            if (_testResult != null) ...[
              const SizedBox(height: 16),
              Text(_testResult!),
            ],
          ],
        ),
      ),
    );
  }
}
