import 'package:flutter_test/flutter_test.dart';
import 'package:onnx_mobile_ocr/onnx_ocr_plugin.dart';
import 'package:onnx_mobile_ocr/onnx_ocr_plugin_platform_interface.dart';
import 'package:onnx_mobile_ocr/onnx_ocr_plugin_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockOnnxMobileOcrPlatform
    with MockPlatformInterfaceMixin
    implements OnnxMobileOcrPlatform {

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
  final OnnxMobileOcrPlatform initialPlatform = OnnxMobileOcrPlatform.instance;

  test('$MethodChannelOnnxMobileOcr is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelOnnxMobileOcr>());
  });

  test('getPlatformVersion', () async {
    OnnxMobileOcr onnxMobileOcr = OnnxMobileOcr();
    MockOnnxMobileOcrPlatform fakePlatform = MockOnnxMobileOcrPlatform();
    OnnxMobileOcrPlatform.instance = fakePlatform;

    expect(await onnxMobileOcr.getPlatformVersion(), '42');
  });
}
