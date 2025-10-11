import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'mobile_ocr_plugin_platform_interface.dart';

/// An implementation of [MobileOcrPlatform] that uses method channels.
class MethodChannelMobileOcr extends MobileOcrPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('mobile_ocr');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }

  @override
  Future<List<Map<dynamic, dynamic>>> detectText({
    required String imagePath,
    bool includeAllConfidenceScores = false,
  }) async {
    final result =
        await methodChannel.invokeListMethod<Map<dynamic, dynamic>>(
      'detectText',
      {
        'imagePath': imagePath,
        'includeAllConfidenceScores': includeAllConfidenceScores,
      },
    );
    return result ?? const [];
  }

  @override
  Future<bool> hasText({
    required String imagePath,
  }) async {
    final result = await methodChannel.invokeMethod<bool>(
      'hasText',
      {
        'imagePath': imagePath,
      },
    );
    return result ?? false;
  }

  @override
  Future<Map<dynamic, dynamic>> prepareModels() async {
    final result = await methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'prepareModels',
    );
    return result ?? {};
  }
}
