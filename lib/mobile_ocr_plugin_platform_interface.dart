import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'mobile_ocr_plugin_method_channel.dart';

abstract class MobileOcrPlatform extends PlatformInterface {
  /// Constructs a MobileOcrPlatform.
  MobileOcrPlatform() : super(token: _token);

  static final Object _token = Object();

  static MobileOcrPlatform _instance = MethodChannelMobileOcr();

  /// The default instance of [MobileOcrPlatform] to use.
  ///
  /// Defaults to [MethodChannelMobileOcr].
  static MobileOcrPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [MobileOcrPlatform] when
  /// they register themselves.
  static set instance(MobileOcrPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }

  Future<List<Map<dynamic, dynamic>>> detectText({
    required String imagePath,
    bool includeAllConfidenceScores = false,
  }) {
    throw UnimplementedError('detectText() has not been implemented.');
  }

  Future<Map<dynamic, dynamic>> prepareModels() {
    throw UnimplementedError('prepareModels() has not been implemented.');
  }
}
