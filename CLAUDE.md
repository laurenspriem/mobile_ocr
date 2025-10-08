# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`onnx_mobile_ocr` is a Flutter plugin for on-device OCR using ONNX models. It's a direct port of [OnnxOCR](https://github.com/jingsongliujing/OnnxOCR) to Android/Kotlin, maintaining exact compatibility with PaddleOCR v5 models and processing pipeline.

**Critical Constraint**: NO OpenCV or large SDKs. Only native Android APIs (Bitmap, Canvas, Matrix, Paint) and ONNX Runtime are allowed to prevent native library bloat.

## Common Commands

### Plugin Testing
```bash
# Run Flutter tests
flutter test

# Run Android unit tests
cd android && ./gradlew test
```

### Example App
```bash
cd example

# Run example app
flutter run

# CRITICAL FOR AI AGENTS: Never use Bash tool directly for flutter run
# Use Task tool with general-purpose agent instead to avoid context pollution
```

### Test Configuration

Example app auto-loads test images with ground truth validation:
- First image loads automatically after 3 seconds
- Enable auto-cycle: Set `AUTO_CYCLE_TEST_IMAGES = true` in `example/lib/main.dart:14`
- Test images: `example/assets/test_ocr/` with `ground_truth.json`

## Architecture

### OCR Pipeline (3 Stages)

Direct port of OnnxOCR's processing pipeline:

1. **Text Detection** (`android/src/main/kotlin/.../TextDetector.kt`)
   - DB algorithm, model: `det.onnx` (4.75 MB)
   - Resize to 960px min side, normalize with mean/std, CHW format
   - Postprocess: threshold=0.3, box_threshold=0.6, unclip_ratio=1.5

2. **Angle Classification** (`TextClassifier.kt`)
   - Detects 180° rotation, model: `cls.onnx` (583 KB)
   - Input: (3, 48, 192), threshold=0.9

3. **Text Recognition** (`TextRecognizer.kt`)
   - SVTR_LCNet + CTC decoder, model: `rec.onnx` (16.5 MB)
   - Input: (3, 48, 320), batch_size=6
   - Dictionary: `ppocrv5_dict.txt`

### Model Delivery

Models are NOT bundled with the plugin:
- **Hosted**: `https://models.ente.io/PP-OCRv5/`
- **Managed by**: `ModelManager.kt` (download, verify SHA-256, cache)
- **Cached**: `context.filesDir/onnx_ocr/PP-OCRv5/`
- **Triggered**: First `prepareModels()` call
- **Offline**: Works offline after initial download

### Component Structure

**Native (Kotlin)** - `android/src/main/kotlin/io/ente/onnx_mobile_ocr/`:
- `OnnxMobileOcrPlugin.kt`: Flutter method channel interface
- `OcrProcessor.kt`: Pipeline orchestrator
- `ModelManager.kt`: Download/cache manager
- `TextDetector.kt`: Detection stage
- `TextClassifier.kt`: Classification stage
- `TextRecognizer.kt`: Recognition stage
- `ImageUtils.kt`: Pure Kotlin image preprocessing (NO OpenCV)

**Flutter (Dart)** - `lib/`:
- `onnx_ocr_plugin.dart`: Public API (`detectText()`, `prepareModels()`)
- `onnx_ocr_plugin_platform_interface.dart`: Platform interface
- `onnx_ocr_plugin_method_channel.dart`: Method channel implementation

**Models** - Downloaded at runtime:
- `det.onnx`, `rec.onnx`, `cls.onnx`, `ppocrv5_dict.txt`

**Example** - `example/`:
- Full demo app with test images and ground truth validation
- Shows text overlay, selection, copying, confidence visualization

## Implementation Rules

### No OpenCV Rule

When porting Python `cv2` operations:
- ✅ Use Android `Bitmap`, `Canvas`, `Matrix`, `Paint`
- ✅ Implement custom algorithms in pure Kotlin
- ✅ Accept minor differences if it avoids dependencies
- ❌ Never use OpenCV or libraries that bundle .so files
- ❌ Never add large image processing SDKs

### Model Parameter Compatibility

Must match OnnxOCR exactly:
- Detection: `limit_side_len=960`, `db_thresh=0.3`, `box_thresh=0.6`, `unclip_ratio=1.5`
- Classification: `thresh=0.9`, shape `(3, 48, 192)`
- Recognition: `batch_num=6`, shape `(3, 48, 320)`
- Normalization:
  - Detection: mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]
  - Rec/Cls: (pixel/255 - 0.5) / 0.5

### Memory Management

- Always call `bitmap.recycle()` after use
- Close ONNX tensors explicitly
- Keep heavy processing in native layer
- Use Kotlin coroutines for async work

## Dependencies

**Android** (`android/build.gradle`):
```gradle
implementation("com.microsoft.onnxruntime:onnxruntime-android:latest.release")
implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
```

**Flutter** (`pubspec.yaml`):
```yaml
dependencies:
  flutter: {sdk: flutter}
  plugin_platform_interface: ^2.0.2
  path_provider: ^2.1.0

dev_dependencies:
  flutter_test: {sdk: flutter}
  flutter_lints: ^5.0.0
```

## Platform Support

- ✅ Android (API 24+)
- ⬜ iOS (planned)

## Reference Documentation

- `documentation/ONNX_OCR_PLUGIN_CONTEXT.md`: Complete context, testing workflow
- `documentation/OnnxOCR_Implementation_Guide.md`: Model specs, algorithms
- Original: [OnnxOCR](https://github.com/jingsongliujing/OnnxOCR)
- Models: [PaddleOCR v5](https://github.com/PaddlePaddle/PaddleOCR)
