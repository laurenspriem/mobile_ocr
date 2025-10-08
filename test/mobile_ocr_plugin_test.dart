import 'package:flutter_test/flutter_test.dart';
import 'package:onnx_mobile_ocr/mobile_ocr_plugin.dart';
import 'package:onnx_mobile_ocr/mobile_ocr_plugin_platform_interface.dart';
import 'package:onnx_mobile_ocr/mobile_ocr_plugin_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockMobileOcrPlatform
    with MockPlatformInterfaceMixin
    implements MobileOcrPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');

  @override
  Future<List<Map<dynamic, dynamic>>> detectText({
    required String imagePath,
    bool includeAllConfidenceScores = false,
  }) async {
    return [];
  }

  @override
  Future<Map<dynamic, dynamic>> prepareModels() async {
    return {
      'isReady': true,
      'version': 'test',
      'modelPath': '/tmp',
    };
  }
}

void main() {
  final MobileOcrPlatform initialPlatform = MobileOcrPlatform.instance;

  test('$MethodChannelMobileOcr is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelMobileOcr>());
  });

  test('getPlatformVersion', () async {
    MobileOcr mobileOcr = MobileOcr();
    MockMobileOcrPlatform fakePlatform = MockMobileOcrPlatform();
    MobileOcrPlatform.instance = fakePlatform;

    expect(await mobileOcr.getPlatformVersion(), '42');
  });
}
