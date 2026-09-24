import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'crop_analyzer_page.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  // Helper for faint, consistent background icons
  Widget _bgIcon(IconData icon, double left, double top, {double size = 48}) {
    return Positioned(
      left: left,
      top: top,
      child: Opacity(
        opacity: 0.12, // subtle, more professional
        child: Icon(
          icon,
          color: Colors.green[400],
          size: size,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFE8F5E9), Color(0xFFF1F8E9)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Stack(
          children: [
            // Decorative icons placed around (adjusted + added more)
            _bgIcon(Icons.agriculture, screenWidth * 0.05, screenHeight * 0.15), // moved lower
            _bgIcon(Icons.eco, screenWidth * 0.80, screenHeight * 0.18), // moved lower
            _bgIcon(Icons.water_drop, screenWidth * 0.12, screenHeight * 0.45),
            _bgIcon(Icons.sunny, screenWidth * 0.82, screenHeight * 0.42),
            _bgIcon(Icons.bug_report, screenWidth * 0.20, screenHeight * 0.78),
            _bgIcon(Icons.grass, screenWidth * 0.70, screenHeight * 0.75),
            // extra icons for balance
            _bgIcon(Icons.park, screenWidth * 0.35, screenHeight * 0.25, size: 40),
            _bgIcon(Icons.spa, screenWidth * 0.65, screenHeight * 0.55, size: 44),
            _bgIcon(Icons.cloud, screenWidth * 0.40, screenHeight * 0.70, size: 42),

            // Main content
            Column(
              children: [
                const SizedBox(height: 50),
                // College logo (transparent PNG)
                Image.asset(
                  'assets/images/svce_logo.png',
                  height: 90,
                  fit: BoxFit.contain,
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  child: Column(
                    children: [
                      Text(
                        "Welcome to",
                        style: GoogleFonts.poppins(
                          fontSize: 22,
                          fontWeight: FontWeight.w500,
                          color: Colors.grey[800],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "Crop Analyzer",
                        style: GoogleFonts.poppins(
                          fontSize: 30,
                          fontWeight: FontWeight.bold,
                          color: Colors.green[700],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        "Your smart friend for better farming decisions 🌱",
                        style: GoogleFonts.lato(
                          fontSize: 16,
                          color: Colors.grey[600],
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 50),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 50, vertical: 16),
                    backgroundColor: Colors.green[600],
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                    elevation: 6,
                    shadowColor: Colors.green[700],
                  ),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const CropAnalyzerPage()),
                    );
                  },
                  icon: const Icon(Icons.agriculture, size: 24),
                  label: Text(
                    "Start",
                    style: GoogleFonts.poppins(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Spacer(),
              ],
            ),
          ],
        ),
      ),
    );
  }
}