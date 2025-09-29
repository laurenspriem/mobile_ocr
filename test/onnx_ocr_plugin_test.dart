import 'package:flutter_test/flutter_test.dart';
import 'package:onnx_ocr_plugin/onnx_ocr_plugin.dart';
import 'package:onnx_ocr_plugin/onnx_ocr_plugin_platform_interface.dart';
import 'package:onnx_ocr_plugin/onnx_ocr_plugin_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockOnnxOcrPluginPlatform
    with MockPlatformInterfaceMixin
    implements OnnxOcrPluginPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final OnnxOcrPluginPlatform initialPlatform = OnnxOcrPluginPlatform.instance;

  test('$MethodChannelOnnxOcrPlugin is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelOnnxOcrPlugin>());
  });

  test('getPlatformVersion', () async {
    OnnxOcrPlugin onnxOcrPlugin = OnnxOcrPlugin();
    MockOnnxOcrPluginPlatform fakePlatform = MockOnnxOcrPluginPlatform();
    OnnxOcrPluginPlatform.instance = fakePlatform;

    expect(await onnxOcrPlugin.getPlatformVersion(), '42');
  });
}
