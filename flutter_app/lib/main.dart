import 'package:flutter/material.dart';
import 'config.dart';
import 'screens/home_screen.dart';
import 'services/tflite_service.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppConfig.load();

  try {
    await TfliteService.loadModel();
  } catch (e) {
    debugPrint('Failed to load TFLite model: $e');
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Crop Analyzer',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      home: const HomeScreen(),
    );
  }
}
