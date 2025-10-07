import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'onnx_ocr_plugin_platform_interface.dart';

/// An implementation of [OnnxMobileOcrPlatform] that uses method channels.
class MethodChannelOnnxMobileOcr extends OnnxMobileOcrPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('onnx_mobile_ocr');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }

  @override
  Future<Map<dynamic, dynamic>> detectText(
    Uint8List imageData, {
    bool includeAllConfidenceScores = false,
  }) async {
    final result = await methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'detectText',
      {
        'imageData': imageData,
        'includeAllConfidenceScores': includeAllConfidenceScores,
      },
    );
    return result ?? {};
  }
}
