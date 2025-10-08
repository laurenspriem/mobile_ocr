import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_ocr/mobile_ocr_plugin_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MethodChannelMobileOcr platform = MethodChannelMobileOcr();
  const MethodChannel channel = MethodChannel('mobile_ocr');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          switch (methodCall.method) {
            case 'getPlatformVersion':
              return '42';
            case 'detectText':
              return [
                {
                  'text': 'hello',
                  'confidence': 0.9,
                  'points': [
                    {'x': 1.0, 'y': 2.0},
                    {'x': 11.0, 'y': 2.0},
                    {'x': 11.0, 'y': 7.0},
                    {'x': 1.0, 'y': 7.0},
                  ],
                },
              ];
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('getPlatformVersion', () async {
    expect(await platform.getPlatformVersion(), '42');
  });

  test('detectText forwards path', () async {
    final results = await platform.detectText(
      imagePath: '/tmp/test.png',
      includeAllConfidenceScores: true,
    );
    expect(results, hasLength(1));
    expect(results.first['text'], 'hello');
    expect(results.first['points'], isNotEmpty);
  });
}
