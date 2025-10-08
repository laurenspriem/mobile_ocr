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

// Ensure ONNX models are cached locally (downloads on first run)
await ocrPlugin.prepareModels();

// Perform OCR by supplying an image path
final textBlocks = await ocrPlugin.detectText(
  imagePath: '/path/to/image.png',
);

for (final block in textBlocks) {
  print('Text: ${block.text}');
  print('Confidence: ${block.confidence}');
  print('Position: x=${block.x}, y=${block.y}');
  print('Size: ${block.width}x${block.height}');
  print('Corners: ${block.points}');
}
```

#### Detection Output

Each `TextBlock` mirrors the shape produced by the PaddleOCR detector:

- `text` – recognized string
- `confidence` – recognition probability (0–1)
- `x`, `y`, `width`, `height` – axis-aligned bounding box, useful for quick overlays or cropping
- `points` – four corner points (clockwise) describing the oriented quadrilateral; the sample app uses these to draw rotated boxes exactly as they appear in the source image

### Using with Image Picker

```dart
import 'package:image_picker/image_picker.dart';

final ImagePicker picker = ImagePicker();
final XFile? image = await picker.pickImage(source: ImageSource.gallery);

if (image != null) {
  await ocrPlugin.prepareModels(); // Optional: ensure models are ready before detection
  final result = await ocrPlugin.detectText(imagePath: image.path);
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

## Model Assets

The ONNX models (~20 MB total) are **not** bundled with the plugin. They are hosted at
`https://models.ente.io/PP-OCRv5/` and downloaded on demand the first time you call
`prepareModels()`. Files are cached under `context.filesDir/onnx_ocr/PP-OCRv5/` with SHA-256
verification so subsequent runs work offline. You can call `prepareModels()` during app launch to
show a download progress indicator before triggering OCR.

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
