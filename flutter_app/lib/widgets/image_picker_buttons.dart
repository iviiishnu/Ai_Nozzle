import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class ImagePickerButtons extends StatelessWidget {
  final bool isLoading;
  final VoidCallback onGallery;
  final VoidCallback onCamera;

  const ImagePickerButtons({
    required this.isLoading,
    required this.onGallery,
    required this.onCamera,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            padding: EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            backgroundColor: AppColors.primary,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: isLoading ? null : onGallery,
          icon: Icon(Icons.photo),
          label: Text('Gallery'),
        ),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            padding: EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            backgroundColor: AppColors.secondary,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: isLoading ? null : onCamera,
          icon: Icon(Icons.camera_alt),
          label: Text('Camera'),
        ),
      ],
    );
  }
}
