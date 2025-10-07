import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onnx_mobile_ocr/onnx_ocr_plugin_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MethodChannelOnnxMobileOcr platform = MethodChannelOnnxMobileOcr();
  const MethodChannel channel = MethodChannel('onnx_mobile_ocr');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (MethodCall methodCall) async {
        return '42';
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('getPlatformVersion', () async {
    expect(await platform.getPlatformVersion(), '42');
  });
}
