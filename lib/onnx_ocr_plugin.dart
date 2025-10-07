import 'dart:typed_data';
import 'dart:ui' as ui;

import 'onnx_ocr_plugin_platform_interface.dart';

class OnnxOcrPlugin {
  Future<String?> getPlatformVersion() {
    return OnnxOcrPluginPlatform.instance.getPlatformVersion();
  }

  /// Detect text in an image
  ///
  /// Takes a [Uint8List] representing the image data (PNG/JPEG format)
  /// Returns an [OcrResult] containing detected text boxes, recognized text, and confidence scores
  ///
  /// By default, only returns results with confidence >= 0.8
  /// Set [includeAllConfidenceScores] to true to include results with confidence >= 0.5
  Future<OcrResult> detectText(
    Uint8List imageData, {
    bool includeAllConfidenceScores = false,
  }) async {
    final result = await OnnxOcrPluginPlatform.instance.detectText(
      imageData,
      includeAllConfidenceScores: includeAllConfidenceScores,
    );
    return OcrResult.fromMap(result);
  }

  /// Detect text in an image from ui.Image
  Future<OcrResult> detectTextFromImage(ui.Image image) async {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) {
      throw Exception('Failed to convert image to byte data');
    }
    return detectText(byteData.buffer.asUint8List());
  }
}

/// OCR Result containing detected boxes, recognized text and confidence scores
class OcrResult {
  final List<TextBox> boxes;
  final List<String> texts;
  final List<double> scores;

  OcrResult({
    required this.boxes,
    required this.texts,
    required this.scores,
  });

  factory OcrResult.fromMap(Map<dynamic, dynamic> map) {
    final boxesList = (map['boxes'] as List? ?? []);
    final textsList = (map['texts'] as List? ?? []);
    final scoresList = (map['scores'] as List? ?? []);

    final boxes = boxesList.map((box) {
      final pointsList = (box['points'] as List);
      final points = pointsList.map((point) {
        return ui.Offset(
          (point['x'] as num).toDouble(),
          (point['y'] as num).toDouble(),
        );
      }).toList();
      return TextBox(points: points);
    }).toList();

    final texts = textsList.cast<String>();
    final scores = scoresList.map((s) => (s as num).toDouble()).toList();

    return OcrResult(
      boxes: boxes,
      texts: texts,
      scores: scores,
    );
  }

  bool get isEmpty => boxes.isEmpty;
  bool get isNotEmpty => boxes.isNotEmpty;

  /// Get text result at index with bounds checking
  TextResult? getResultAt(int index) {
    if (index < 0 || index >= boxes.length) return null;
    return TextResult(
      box: boxes[index],
      text: texts[index],
      score: scores[index],
    );
  }
}

/// Represents a detected text region
class TextBox {
  /// Four corner points of the text box in clockwise order
  final List<ui.Offset> points;

  TextBox({required this.points});

  /// Get the bounding rectangle of the text box
  ui.Rect get boundingRect {
    if (points.isEmpty) return ui.Rect.zero;

    double minX = points.first.dx;
    double maxX = points.first.dx;
    double minY = points.first.dy;
    double maxY = points.first.dy;

    for (final point in points) {
      minX = minX > point.dx ? point.dx : minX;
      maxX = maxX < point.dx ? point.dx : maxX;
      minY = minY > point.dy ? point.dy : minY;
      maxY = maxY < point.dy ? point.dy : maxY;
    }

    return ui.Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// Check if a point is inside the text box
  bool contains(ui.Offset point) {
    // Simple point-in-polygon test
    if (points.length != 4) return false;

    int intersections = 0;
    for (int i = 0; i < points.length; i++) {
      final p1 = points[i];
      final p2 = points[(i + 1) % points.length];

      if ((p1.dy <= point.dy && point.dy < p2.dy) ||
          (p2.dy <= point.dy && point.dy < p1.dy)) {
        final x = p1.dx + (point.dy - p1.dy) * (p2.dx - p1.dx) / (p2.dy - p1.dy);
        if (x > point.dx) {
          intersections++;
        }
      }
    }

    return intersections % 2 == 1;
  }
}

/// Combined result for a single text detection
class TextResult {
  final TextBox box;
  final String text;
  final double score;

  TextResult({
    required this.box,
    required this.text,
    required this.score,
  });
}