import 'package:flutter/material.dart';
import 'package:flutter_app/services/blynk_service.dart';

class BlynkScreen extends StatefulWidget {
  const BlynkScreen({super.key});

  @override
  State<BlynkScreen> createState() => _BlynkScreenState();
}

class _BlynkScreenState extends State<BlynkScreen> {
  late BlynkService blynk;
  int diseasePercent = 0;
  bool sprayerOn = false;

  @override
  void initState() {
    super.initState();
    // initialize service with your token
    blynk = BlynkService("YOUR_BLYNK_AUTH_TOKEN");
    fetchDiseaseData();
  }

  Future<void> fetchDiseaseData() async {
    try {
      final value = await blynk.getVirtualPin(1); // V1 = Disease %
      setState(() {
        diseasePercent = value;
      });

      // Auto spraying logic (like Python)
      if (diseasePercent >= 30) {
        await toggleSprayer(true); // ON
        await Future.delayed(const Duration(seconds: 5));
        await toggleSprayer(false); // OFF after 5s
      }
    } catch (e) {
      debugPrint("Error fetching disease data: $e");
    }
  }

  Future<void> toggleSprayer(bool state) async {
    sprayerOn = state;
    await blynk.setVirtualPin(2, sprayerOn ? 1 : 0); // V2 = Sprayer
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Blynk Control")),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text("Disease %: $diseasePercent",
                style: const TextStyle(fontSize: 22)),
            const SizedBox(height: 20),

            // Manual switch
            SwitchListTile(
              title: const Text("Sprayer"),
              value: sprayerOn,
              onChanged: (val) async {
                await toggleSprayer(val);
              },
            ),

            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: fetchDiseaseData,
              child: const Text("Refresh Data"),
            ),
          ],
        ),
      ),
    );
  }
}
