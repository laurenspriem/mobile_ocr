# Mobile OCR

Mobile OCR is a Flutter plugin that delivers fully on-device text detection and
recognition on Android and iOS. The two platforms share the same Dart API:

- **Android (ONNX pipeline)** – A faithful port of the PaddleOCR v5 models,
  executed with ONNX Runtime for high-accuracy OCR without network access.
- **iOS (Apple Vision)** – Uses the system Vision framework, so no model
  downloads are required and the plugin stays lightweight.

Everything below describes the Android pipeline unless explicitly noted. The
iOS implementation returns the same JSON payload so the Dart surface remains
identical.

## Features

- Text detection (DB algorithm) with oriented bounding polygons
- Text recognition (SVTR_LCNet + CTC) mirroring PaddleOCR v5 behaviour
- Text angle classification and auto-rotation for skewed crops
- On-device processing with no network calls
- Multi-language character dictionary (Chinese + English)
- Shared results structure across Android and iOS

## Installation

Add this to your package's `pubspec.yaml` file:

```yaml
dependencies:
  mobile_ocr:
    git:
      url: https://github.com/laurenspriem/mobile_ocr
```

## Usage

### Basic Usage

```dart
import 'package:mobile_ocr/mobile_ocr_plugin.dart';

// Create plugin instance
final ocrPlugin = MobileOcr();

// Android only: ensure ONNX models are cached locally (downloads on first run).
// No-op on iOS because Vision ships with the OS.
await ocrPlugin.prepareModels();

// Perform OCR by supplying an image path
final textBlocks = await ocrPlugin.detectText(
  imagePath: '/path/to/image.png',
);

for (final block in textBlocks) {
  print('Text: ${block.text}');
  print('Confidence: ${block.confidence}');
  print('Corners: ${block.points}');
  final bounds = block.boundingBox;
  print('Bounds: ${bounds.left}, ${bounds.top} -> ${bounds.right}, ${bounds.bottom}');
}
```

#### Detection Output

Each `TextBlock` mirrors the shape produced by the PaddleOCR detector:

- `text` – recognized string
- `confidence` – recognition probability (0–1)
- `points` – four corner points (clockwise) describing the oriented quadrilateral; the sample app uses these to draw rotated boxes exactly as they appear in the source image
- `boundingBox` – convenience `Rect` derived from the polygon for quick overlays or cropping

### Using with Image Picker

```dart
import 'package:image_picker/image_picker.dart';

final ImagePicker picker = ImagePicker();
final XFile? image = await picker.pickImage(source: ImageSource.gallery);

if (image != null) {
  await ocrPlugin.prepareModels(); // Android: ensure models are ready (no-op on iOS)
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

## Android Model Assets (ONNX)

The ONNX models (~20 MB total) are **not** bundled with the plugin. They are hosted at
`https://models.ente.io/PP-OCRv5/` and downloaded on demand the first time you call
`prepareModels()`. Files are cached under `context.filesDir/onnx_ocr/PP-OCRv5/` with SHA-256
verification so subsequent runs work offline. You can call `prepareModels()` during app launch to
show a download progress indicator before triggering OCR.

iOS does not require this step because it relies on the built-in Vision framework.

## Platform Support

Currently supports:
- ✅ Android (API 24+)
- ✅ iOS 14+

## Acknowledgments

This work would not be possible without:
- [PaddleOCR](https://github.com/PaddlePaddle/PaddleOCR) - The original OCR models and algorithms
- [OnnxOCR](https://github.com/jingsongliujing/OnnxOCR) - ONNX implementation and pipeline architecture

## License

This plugin is released under the MIT License. The ONNX models are derived from PaddleOCR and follow their licensing terms.
