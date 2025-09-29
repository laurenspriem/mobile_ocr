# ONNX OCR Flutter Plugin - Development Context

## Project Overview

### Intention
Create a Flutter plugin (initially Android-only) that performs Optical Character Recognition (OCR) on images using ONNX models. The plugin should:
- Take an image as input and return detected text
- Display selectable text overlay on top of images (similar to iOS apps)
- Be easily integrable into existing Flutter applications
- Process everything on-device for privacy and performance

### Implementation Strategy
The plugin is a **direct port** of the [OnnxOCR Python implementation](https://github.com/jingsongliujing/OnnxOCR) to Android/Kotlin, maintaining exact compatibility with:
- The same ONNX models (PaddleOCR v5)
- The same preprocessing/postprocessing logic
- The same detection, classification, and recognition pipeline

## Current Architecture

### Project Structure
```
onnx_ocr_plugin/
├── android/                    # Android native implementation
│   └── src/main/kotlin/
│       ├── OnnxOcrPlugin.kt   # Main plugin class (Flutter interface)
│       ├── OcrProcessor.kt     # OCR pipeline orchestrator
│       ├── TextDetector.kt     # Text detection (DB algorithm)
│       ├── TextRecognizer.kt   # Text recognition (CTC decoder)
│       ├── TextClassifier.kt   # Angle classification
│       └── ImageUtils.kt       # Image processing utilities
├── lib/                        # Flutter/Dart interface
│   ├── onnx_ocr_plugin.dart   # Main plugin API
│   └── onnx_ocr_plugin_platform_interface.dart
├── assets/models/              # ONNX models from PaddleOCR v5
│   ├── det/det.onnx           # Detection model (~4.75 MB)
│   ├── rec/rec.onnx           # Recognition model (~16.5 MB)
│   ├── cls/cls.onnx           # Classification model (~583 KB)
│   └── ppocrv5_dict.txt       # Character dictionary
└── example/                    # Sample app demonstrating usage
```

### OCR Pipeline (Exact Copy of OnnxOCR)

1. **Text Detection** (`TextDetector.kt`)
   - Algorithm: DB (Differentiable Binarization)
   - Input preprocessing:
     - Resize image with `limit_side_len=960` (min side)
     - Make dimensions multiple of 32
     - Normalize with mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]
     - Scale: 1/255
     - Convert to CHW format
   - Output postprocessing:
     - Threshold: 0.3 (binarization)
     - Box threshold: 0.6 (minimum score)
     - Unclip ratio: 1.5 (box expansion)
     - Min size: 3x3 pixels

2. **Text Angle Classification** (`TextClassifier.kt`)
   - Purpose: Detect 180-degree rotated text
   - Input shape: (3, 48, 192)
   - Normalization: (pixel/255 - 0.5) / 0.5
   - Threshold: 0.9 for rotation decision
   - Classes: ["0", "180"]

3. **Text Recognition** (`TextRecognizer.kt`)
   - Algorithm: SVTR_LCNet with CTC decoder
   - Input shape: (3, 48, 320)
   - Batch processing: 6 images at once
   - Normalization: (pixel/255 - 0.5) / 0.5
   - CTC decoding with blank token removal
   - Character dictionary: ppocrv5_dict.txt (Chinese + English)

### Key Implementation Details

#### Native Layer (Kotlin)
- **ONNX Runtime**: Version 1.16.3 for Android
- **Async Processing**: Kotlin coroutines for non-blocking operations
- **Memory Optimization**: All heavy processing stays in native layer
- **No OpenCV**: Custom image processing implementations
- **Batch Processing**: Recognition processes up to 6 regions simultaneously

#### Flutter Layer
- **Method Channel**: Communication with native code
- **Data Models**:
  - `OcrResult`: Contains boxes, texts, and confidence scores
  - `TextBox`: Four corner points defining text region
  - `TextResult`: Combined box + text + score
- **Image Support**: Accepts Uint8List (PNG/JPEG format)

#### Sample App Features
- Image selection from camera/gallery
- Text detection with visual overlay
- Tap-to-select text regions
- Selectable text display in dialogs
- View all detected text in a list
- Copy individual or all text to clipboard
- Confidence-based color coding (green/orange/red)

### Model Parameters (From OnnxOCR Analysis)

#### Detection Model
- **Preprocessing**: DetResizeForTest → NormalizeImage → ToCHWImage
- **Postprocessing**: DBPostProcess with polygon/quad output
- **Key parameters**:
  - `det_limit_side_len`: 960
  - `det_db_thresh`: 0.3
  - `det_db_box_thresh`: 0.6
  - `det_db_unclip_ratio`: 1.5

#### Recognition Model
- **Image dimensions**: 48 height, 320 max width
- **Character set**: ~6000+ Chinese characters + English + symbols
- **Decoding**: CTC with blank token at index 0
- **Confidence**: Average of character probabilities

## Current Issues

### 1. **Spaces Not Detected** 🔴
- **Problem**: Spaces between words are missing in recognized text
- **Likely Cause**:
  - Character dictionary might not include space character properly
  - CTC decoder might be removing spaces as blanks
  - Need to verify `use_space_char` parameter is properly handled

### 2. **Truncated Words/Sentences** 🔴
- **Problem**: Beginning and/or ending of text is often incorrect or missing
- **Likely Causes**:
  - Text region cropping might be too tight (not enough padding)
  - Perspective transform might be cutting off edges
  - Unclip ratio (1.5) might need adjustment
  - Recognition model input width (320) might be too small for long text

### 3. **App Crashes on Large Images** 🔴
- **Problem**: Sample app crashes with medium/large images
- **Symptoms**: Likely OutOfMemoryError
- **Likely Causes**:
  - No image downscaling before processing
  - Bitmap operations creating multiple copies in memory
  - ONNX session memory not being released properly
  - Need to implement image size limits or progressive downscaling

## Next Steps / TODOs

### High Priority Fixes
1. **Fix Memory Issues**
   - [ ] Add image size validation and automatic downscaling
   - [ ] Implement memory-efficient bitmap handling
   - [ ] Add proper cleanup of ONNX tensors after inference
   - [ ] Consider processing in tiles for very large images

2. **Fix Text Recognition Accuracy**
   - [ ] Debug space character handling in CTC decoder
   - [ ] Adjust text region cropping padding
   - [ ] Test different unclip ratios for better text coverage
   - [ ] Verify character dictionary is loaded correctly

3. **Fix Word Truncation**
   - [ ] Add padding to cropped text regions
   - [ ] Check if perspective transform is preserving full text
   - [ ] Test with different recognition input widths

### Feature Enhancements
1. **Performance Optimization**
   - [ ] Profile and optimize preprocessing operations
   - [ ] Implement caching for repeated OCR on same image
   - [ ] Add progress callbacks for long operations

2. **Language Support**
   - [ ] Make character dictionary configurable
   - [ ] Add English-only mode for smaller model size
   - [ ] Support for additional languages

3. **iOS Support**
   - [ ] Implement iOS native code (Swift/Objective-C)
   - [ ] Ensure feature parity with Android

4. **Advanced Features**
   - [ ] Add text region editing/correction
   - [ ] Implement paragraph detection and reading order
   - [ ] Add export formats (PDF, structured text)

### Code Quality
1. **Error Handling**
   - [ ] Add comprehensive error messages
   - [ ] Implement fallback mechanisms
   - [ ] Add logging for debugging

2. **Testing**
   - [ ] Unit tests for image processing functions
   - [ ] Integration tests for OCR pipeline
   - [ ] Performance benchmarks

3. **Documentation**
   - [ ] API documentation
   - [ ] Integration guide
   - [ ] Troubleshooting guide

## Technical Debt

1. **Contour Detection**: Current implementation is simplified
   - Need proper connected component analysis
   - Should use more sophisticated contour tracing

2. **Minimum Area Rectangle**: Using bounding box instead of proper min area rect
   - Need to implement rotating calipers algorithm

3. **Polygon Expansion**: Basic implementation of unclip operation
   - Should use proper Clipper library for polygon operations

## Configuration Notes

### Android Build Configuration
```gradle
dependencies {
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.16.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
}
```

### Required Permissions (Android)
```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />
```

## Development Tips

1. **Debugging OCR Results**:
   - Enable `save_crop_res` to save cropped text regions
   - Log preprocessing values to verify normalization
   - Check tensor shapes match expected model inputs

2. **Memory Management**:
   - Always dispose of bitmaps after use
   - Close ONNX tensors explicitly
   - Use bitmap.recycle() in Kotlin

3. **Coordinate Systems**:
   - OCR returns coordinates in original image space
   - UI overlay needs transformation to display space
   - Remember to account for BoxFit scaling

## References

- Original Implementation: [OnnxOCR](https://github.com/jingsongliujing/OnnxOCR)
- Models Source: PaddlePaddle's PaddleOCR v5
- ONNX Runtime: [Microsoft ONNX Runtime](https://onnxruntime.ai/)
- OCR Algorithm Papers:
  - DB: [Real-time Scene Text Detection with Differentiable Binarization](https://arxiv.org/abs/1911.08947)
  - SVTR: [Scene Text Recognition with Permuted Autoregressive Sequence Models](https://arxiv.org/abs/2207.06966)

## Session Summary

**Date**: 2025-09-29

**Accomplished**:
- ✅ Created complete Flutter plugin structure
- ✅ Implemented Android native OCR processing
- ✅ Ported all three models (detection, classification, recognition)
- ✅ Created functional sample app with text overlay
- ✅ Fixed overlay positioning issues
- ✅ Added "view all text" feature

**Discovered Issues**:
- ❌ Spaces not detected in text
- ❌ Word truncation at boundaries
- ❌ Memory crashes with large images

**Time Spent**: ~4 hours

**Next Session Priority**: Fix memory issues first (blocking issue), then address text accuracy problems.