import 'dart:io';
import 'dart:ui';

import 'mobile_ocr_plugin_platform_interface.dart';

class MobileOcr {
  Future<String?> getPlatformVersion() {
    return MobileOcrPlatform.instance.getPlatformVersion();
  }

  /// Ensure that the native OCR models required on Android are downloaded.
  ///
  /// Downloads any missing files, verifies checksums, and caches them on disk.
  /// Returns a [ModelPreparationStatus] describing the cache status. This call
  /// is a no-op on iOS because it relies on the Vision framework.
  Future<ModelPreparationStatus> prepareModels() async {
    final result = await MobileOcrPlatform.instance.prepareModels();
    return ModelPreparationStatus.fromMap(result);
  }

  /// Detect text in an image at the provided file system path.
  ///
  /// [imagePath] must point to a readable PNG or JPEG file.
  /// By default, only returns results with confidence >= 0.8. Set
  /// [includeAllConfidenceScores] to true to include detections down to 0.5.
  Future<List<TextBlock>> detectText({
    required String imagePath,
    bool includeAllConfidenceScores = false,
  }) async {
    final file = File(imagePath);
    if (!file.existsSync()) {
      throw ArgumentError('Image file does not exist at path: $imagePath');
    }

    final results = await MobileOcrPlatform.instance.detectText(
      imagePath: file.path,
      includeAllConfidenceScores: includeAllConfidenceScores,
    );
    return results.map(TextBlock.fromMap).toList(growable: false);
  }
}

/// Describes the current preparation status of the native OCR model cache.
class ModelPreparationStatus {
  final bool isReady;
  final String? version;
  final String? modelPath;

  ModelPreparationStatus({required this.isReady, this.version, this.modelPath});

  factory ModelPreparationStatus.fromMap(Map<dynamic, dynamic> map) {
    return ModelPreparationStatus(
      isReady: map['isReady'] == true,
      version: map['version'] as String?,
      modelPath: map['modelPath'] as String?,
    );
  }
}

/// Represents a detected block of text with its bounding rectangle.
class TextBlock {
  final String text;
  final double confidence;
  final double x;
  final double y;
  final double width;
  final double height;
  final List<Offset> points;

  const TextBlock({
    required this.text,
    required this.confidence,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.points,
  });

  Rect get boundingBox => Rect.fromLTWH(x, y, width, height);
  Offset get center => Offset(x + width / 2, y + height / 2);

  factory TextBlock.fromMap(Map<dynamic, dynamic> map) {
    final confidence = (map['confidence'] as num).toDouble();
    final x = (map['x'] as num).toDouble();
    final y = (map['y'] as num).toDouble();
    final width = (map['width'] as num).toDouble();
    final height = (map['height'] as num).toDouble();
    final pointsList = map['points'] as List?;
    final points = (pointsList != null && pointsList.isNotEmpty)
        ? pointsList
            .map(
              (point) => Offset(
                (point['x'] as num).toDouble(),
                (point['y'] as num).toDouble(),
              ),
            )
            .toList(growable: false)
        : <Offset>[
            Offset(x, y),
            Offset(x + width, y),
            Offset(x + width, y + height),
            Offset(x, y + height),
          ];

    return TextBlock(
      text: map['text'] as String,
      confidence: confidence,
      x: x,
      y: y,
      width: width,
      height: height,
      points: points,
    );
  }

  Map<String, dynamic> toMap() => {
        'text': text,
        'confidence': confidence,
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'points': points
            .map(
              (point) => {
                'x': point.dx,
                'y': point.dy,
              },
            )
            .toList(growable: false),
      };
}
