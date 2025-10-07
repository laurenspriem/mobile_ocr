# ONNX Mobile OCR

A Flutter plugin for performing Optical Character Recognition (OCR) using ONNX models. This plugin replicates the functionality of the PaddleOCR v5 models, running directly on Android devices for fast and accurate text detection and recognition.

## Features

- **Text Detection**: Detects text regions in images using DB (Differentiable Binarization) algorithm
- **Text Recognition**: Recognizes text content using SVTR_LCNet with CTC decoder
- **Text Angle Classification**: Automatically corrects rotated text (180-degree rotation)
- **On-device Processing**: All processing happens locally on the device
- **Support for Multiple Languages**: Includes Chinese and English character recognition
- **High Performance**: Optimized with ONNX Runtime for mobile devices

## Installation

Add this to your package's `pubspec.yaml` file:

```yaml
dependencies:
  onnx_mobile_ocr:
    git:
      url: https://github.com/laurenspriem/onnx_mobile_ocr
```

## Usage

### Basic Usage

```dart
import 'package:onnx_mobile_ocr/onnx_ocr_plugin.dart';

// Create plugin instance
final ocrPlugin = OnnxMobileOcr();

// Load image as Uint8List (PNG/JPEG format)
final Uint8List imageData = await loadImage();

// Perform OCR
final OcrResult result = await ocrPlugin.detectText(imageData);

// Access results
for (int i = 0; i < result.texts.length; i++) {
  print('Text: ${result.texts[i]}');
  print('Confidence: ${result.scores[i]}');
  print('Box: ${result.boxes[i].points}');
}
```

### Using with Image Picker

```dart
import 'package:image_picker/image_picker.dart';

final ImagePicker picker = ImagePicker();
final XFile? image = await picker.pickImage(source: ImageSource.gallery);

if (image != null) {
  final bytes = await image.readAsBytes();
  final result = await ocrPlugin.detectText(bytes);
  // Process results...
}
```

## Example App

The plugin includes a comprehensive example app that demonstrates:

- Loading images from camera or gallery
- Running OCR on selected images
- Displaying detected text regions with colored overlays
- Tapping on text regions to view and copy the recognized text
- Toggle text overlay visibility

To run the example:

```bash
cd example
flutter run
```

## Platform Support

Currently supports:
- ✅ Android (API 21+)
- ⬜ iOS (coming soon)

## Acknowledgments

This work would not be possible without:
- [PaddleOCR](https://github.com/PaddlePaddle/PaddleOCR) - The original OCR models and algorithms
- [OnnxOCR](https://github.com/jingsongliujing/OnnxOCR) - ONNX implementation and pipeline architecture
- [RapidOCR](https://github.com/RapidAI/RapidOCR) - ONNX model optimization work

## License

This plugin is released under the MIT License. The ONNX models are derived from PaddleOCR and follow their licensing terms.

