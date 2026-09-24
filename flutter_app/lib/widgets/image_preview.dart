import 'dart:io';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class ImagePreview extends StatelessWidget {
  final File? image;
  final double height;

  const ImagePreview({this.image, this.height = 220, super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: AppColors.cardBackground,
        border: Border.all(color: AppColors.secondary, width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 8,
            offset: Offset(0, 4),
          )
        ],
      ),
      child: image == null
          ? Center(
              child: Text(
                'No image selected',
                style: TextStyle(color: AppColors.secondary, fontSize: 22, fontWeight: FontWeight.bold),
              ),
            )
          : ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.file(image!, fit: BoxFit.cover),
            ),
    );
  }
}
