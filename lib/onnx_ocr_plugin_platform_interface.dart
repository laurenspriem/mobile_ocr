import 'dart:typed_data';

import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'onnx_ocr_plugin_method_channel.dart';

abstract class OnnxOcrPluginPlatform extends PlatformInterface {
  /// Constructs a OnnxOcrPluginPlatform.
  OnnxOcrPluginPlatform() : super(token: _token);

  static final Object _token = Object();

  static OnnxOcrPluginPlatform _instance = MethodChannelOnnxOcrPlugin();

  /// The default instance of [OnnxOcrPluginPlatform] to use.
  ///
  /// Defaults to [MethodChannelOnnxOcrPlugin].
  static OnnxOcrPluginPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [OnnxOcrPluginPlatform] when
  /// they register themselves.
  static set instance(OnnxOcrPluginPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }

  Future<Map<dynamic, dynamic>> detectText(Uint8List imageData) {
    throw UnimplementedError('detectText() has not been implemented.');
  }
}
