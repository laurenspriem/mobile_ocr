import 'package:flutter_test/flutter_test.dart';
import 'package:onnx_mobile_ocr/mobile_ocr_plugin.dart';
import 'package:onnx_mobile_ocr/mobile_ocr_plugin_platform_interface.dart';
import 'package:onnx_mobile_ocr/mobile_ocr_plugin_method_channel.dart';
import 'package:onnx_mobile_ocr/models/text_block.dart';
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
    return {'isReady': true, 'version': 'test', 'modelPath': '/tmp'};
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

  test('TextBlock computes bounding box from points', () {
    final block = TextBlock.fromMap({
      'text': 'hello',
      'confidence': 0.9,
      'points': [
        {'x': 1.0, 'y': 2.0},
        {'x': 5.0, 'y': 2.0},
        {'x': 5.0, 'y': 6.0},
        {'x': 1.0, 'y': 6.0},
      ],
    });

    expect(block.boundingBox.left, 1.0);
    expect(block.boundingBox.top, 2.0);
    expect(block.boundingBox.width, 4.0);
    expect(block.boundingBox.height, 4.0);
  });

  test('TextBlock falls back to rectangle fields when points absent', () {
    final block = TextBlock.fromMap({
      'text': 'hello',
      'confidence': 0.9,
      'x': 2.0,
      'y': 3.0,
      'width': 8.0,
      'height': 4.0,
    });

    expect(block.points, hasLength(4));
    expect(block.boundingBox.left, 2.0);
    expect(block.boundingBox.top, 3.0);
    expect(block.boundingBox.right, 10.0);
    expect(block.boundingBox.bottom, 7.0);
  });
}
