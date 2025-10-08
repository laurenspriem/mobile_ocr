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

/// Represents a detected block of text with its polygon outline.
class TextBlock {
  final String text;
  final double confidence;
  final List<Offset> points;

  const TextBlock({
    required this.text,
    required this.confidence,
    required this.points,
  });

  Rect get boundingBox {
    if (points.isEmpty) {
      return Rect.zero;
    }

    double minX = points.first.dx;
    double maxX = points.first.dx;
    double minY = points.first.dy;
    double maxY = points.first.dy;

    for (final point in points) {
      if (point.dx < minX) minX = point.dx;
      if (point.dx > maxX) maxX = point.dx;
      if (point.dy < minY) minY = point.dy;
      if (point.dy > maxY) maxY = point.dy;
    }

    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  Offset get center => boundingBox.center;

  factory TextBlock.fromMap(Map<dynamic, dynamic> map) {
    final confidence = (map['confidence'] as num).toDouble();
    final pointsList = map['points'] as List?;
    List<Offset> points;

    if (pointsList != null && pointsList.isNotEmpty) {
      points = pointsList
          .map(
            (point) => Offset(
              (point['x'] as num).toDouble(),
              (point['y'] as num).toDouble(),
            ),
          )
          .toList(growable: false);
    } else {
      final x = map['x'] as num?;
      final y = map['y'] as num?;
      final width = map['width'] as num?;
      final height = map['height'] as num?;

      if (x == null || y == null || width == null || height == null) {
        throw ArgumentError(
          'TextBlock map is missing polygon points and fallback rectangle.',
        );
      }

      final left = x.toDouble();
      final top = y.toDouble();
      final blockWidth = width.toDouble();
      final blockHeight = height.toDouble();

      points = <Offset>[
        Offset(left, top),
        Offset(left + blockWidth, top),
        Offset(left + blockWidth, top + blockHeight),
        Offset(left, top + blockHeight),
      ];
    }

    return TextBlock(
      text: map['text'] as String,
      confidence: confidence,
      points: points,
    );
  }

  Map<String, dynamic> toMap() => {
    'text': text,
    'confidence': confidence,
    'points': points
        .map((point) => {'x': point.dx, 'y': point.dy})
        .toList(growable: false),
  };
}
