import 'dart:typed_data';

import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'onnx_ocr_plugin_method_channel.dart';

abstract class OnnxMobileOcrPlatform extends PlatformInterface {
  /// Constructs a OnnxMobileOcrPlatform.
  OnnxMobileOcrPlatform() : super(token: _token);

  static final Object _token = Object();

  static OnnxMobileOcrPlatform _instance = MethodChannelOnnxMobileOcr();

  /// The default instance of [OnnxMobileOcrPlatform] to use.
  ///
  /// Defaults to [MethodChannelOnnxMobileOcr].
  static OnnxMobileOcrPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [OnnxMobileOcrPlatform] when
  /// they register themselves.
  static set instance(OnnxMobileOcrPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }

  Future<Map<dynamic, dynamic>> detectText(
    Uint8List imageData, {
    bool includeAllConfidenceScores = false,
  }) {
    throw UnimplementedError('detectText() has not been implemented.');
  }

  Future<Map<dynamic, dynamic>> prepareModels() {
    throw UnimplementedError('prepareModels() has not been implemented.');
  }
}
