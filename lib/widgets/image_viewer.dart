import 'dart:io';

import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';

class ImageViewerScreen extends StatelessWidget {
  final String imagePath;

  const ImageViewerScreen({super.key, required this.imagePath});

  @override
  Widget build(BuildContext context) {
    final bgColor = Theme.of(context).colorScheme.surface;
    final fgColor = Theme.of(context).colorScheme.onSurface;
    final fileExists = File(imagePath).existsSync();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: bgColor,
        foregroundColor: fgColor,
      ),
      backgroundColor: bgColor,
      body: fileExists
          ? PhotoView(
              imageProvider: FileImage(File(imagePath)),
              minScale: PhotoViewComputedScale.contained,
              maxScale: PhotoViewComputedScale.covered * 3,
              errorBuilder: (_, _, _) => Center(
                child: Icon(Icons.broken_image, color: fgColor, size: 64),
              ),
            )
          : Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.image_not_supported, color: fgColor, size: 64),
                  const SizedBox(height: 16),
                  Text('이미지를 찾을 수 없습니다', style: TextStyle(color: fgColor)),
                ],
              ),
            ),
    );
  }
}
