import 'package:flutter/material.dart';

class InfoCard extends StatelessWidget {
  final String title;
  final String value;
  final double? progress; // Optional progress, range 0.0 to 1.0
  final Color? valueColor;
  final IconData icon;

  const InfoCard({
    super.key,
    required this.title,
    required this.value,
    this.progress,
    this.valueColor,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 4,
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, size: 40, color: valueColor ?? Colors.green),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey[700], // Good for subtitle on light background
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: valueColor ?? Colors.black, // main color for value text
                    ),
                  ),
                  if (progress != null) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: progress!.clamp(0.0, 1.0),
                      color: valueColor ?? Colors.green,
                      backgroundColor: Colors.grey[300],
                      minHeight: 8,
                    ),
                  ]
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
