import 'package:flutter/material.dart';

Color getHealthColor(String health) {
  return health.toLowerCase() == 'healthy'
      ? Colors.green
      : Colors.redAccent;
}
