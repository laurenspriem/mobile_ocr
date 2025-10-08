import 'dart:io';

import 'package:onnx_mobile_ocr/models/text_block.dart';

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