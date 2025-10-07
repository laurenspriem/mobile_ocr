# ONNX OCR Flutter Plugin - Development Context

## Project Overview

### Intention

Create a Flutter plugin (initially Android-only) that performs Optical Character Recognition (OCR) on images using ONNX models. The plugin should:

- Take an image as input and return detected text
- Display selectable text overlay on top of images (similar to iOS apps)
- Be easily integrable into existing Flutter applications
- Process everything on-device for privacy and performance

### Implementation Strategy

The plugin is a **direct port** of the [OnnxOCR Python implementation](https://github.com/jingsongliujing/OnnxOCR) (cloned in `./OnnxOCR/`) to Android/Kotlin, maintaining exact compatibility with:

- The same ONNX models (PaddleOCR v5)
- The same preprocessing/postprocessing logic
- The same detection, classification, and recognition pipeline

### Critical Constraints

⚠️ **NO OPENCV OR LARGE SDKS** ⚠️

**This plugin MUST NOT use OpenCV or any other large SDK/library that bundles native .so files.**

The only exception is ONNX Runtime, which is allowed and needed.

**Reasoning:**

- OpenCV for Android adds 10-20 MB of native libraries (.so files) for multiple architectures
- This creates unacceptable bloat for the host application
- The plugin should remain lightweight and dependency-minimal

**Allowed Approaches:**

1. **Native Android APIs only** (Bitmap, Canvas, Matrix, Paint, etc.)
2. **Pure Kotlin/Java code** without native dependencies
3. **Custom implementations** of algorithms when needed
4. **Lightweight pure-code packages** that have no .so files or large SDK dependencies

**Forbidden Approaches:**

- ❌ OpenCV (cv2, org.opencv)
- ❌ Any library that bundles native .so files
- ❌ Large image processing SDKs

**When porting Python code that uses cv2:**

- Use Android's Bitmap and Canvas APIs for image operations
- Implement custom algorithms in Kotlin where necessary
- Accept that some operations may differ slightly from Python's cv2 implementation, as long as the end accuracy is still good.

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

- **ONNX Runtime**: Version 1.16.3 for Android (only allowed external dependency)
- **Async Processing**: Kotlin coroutines for non-blocking operations
- **Memory Optimization**: All heavy processing stays in native layer
- **No OpenCV**: All image processing uses native Android APIs (Bitmap, Canvas, Matrix, Paint) or custom Kotlin implementations
- **Zero .so file bloat**: No native libraries beyond ONNX Runtime
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

## Configuration Notes

### Android Build Configuration

```gradle
dependencies {
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.16.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3')
   }
```

### Required Permissions (Android)

```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />
```

## Testing & Verification Workflow

### Quick Testing via Sample App

The example app is configured for easy testing and verification of OCR functionality:

#### Running Tests

**For Developers:**

```bash
cd example/
flutter run
```

**For AI Agents:**

⚠️ **CRITICAL: ALWAYS use Task tool with general-purpose agent** ⚠️

NEVER run `flutter run` directly with Bash tool - it produces massive console output that ruins context.

Use the Task tool with the general-purpose subagent to:

1. Run `flutter run` in the example directory
2. Monitor the console output for OCR results
3. Report back only the key findings (detected text vs ground truth)
4. Do NOT include full logs in the context (to prevent overload)

#### What Happens Automatically

1. **Auto-load First Test Image** (3 second delay)

   - App loads `meme_love_you.jpeg` on startup
   - Waits 3 seconds for ONNX models to initialize
   - Automatically runs OCR

2. **Console Output Format**

   ```
   ========================================
   Loaded test image: meme_love_you.jpeg
   ========================================

   ⏳ Waiting 3 seconds for models to initialize...

   ========== OCR RESULTS ==========
   Total regions detected: 3

   Recognized texts:
   1. [95.2%] Nobody:
   2. [88.7%] Me randomly when I love you
   3. [92.3%] Source: @BeamCardShop
   ================================

   Ground truth texts for meme_love_you.jpeg:
     1. Nobody:
     2. Me randomly when I love you
     3. Source: @BeamCardShop
   ```

3. **What to Look For**
   - Number of detected regions matches ground truth
   - Recognized text matches ground truth text
   - Confidence scores (should be >80% for good detection)
   - Any missing or truncated words
   - Any OCR errors or exceptions

#### Testing Multiple Images

By default, only the first image is tested. To cycle through all 10 test images:

1. **Enable Auto-Cycle Feature Flag** (main.dart:14)

   ```dart
   const bool AUTO_CYCLE_TEST_IMAGES = true;  // Change to true
   ```

2. **Run Again**
   - Each image will be tested automatically
   - 10 second interval between images
   - All results logged to console

**Note for AI Agents:** Only enable auto-cycle if user specifically requests testing all images. For routine verification, testing the first image is sufficient.

#### Available Test Images

Located in `example/assets/test_ocr/`:

1. `meme_love_you.jpeg` - Pokemon meme (default)
2. `meme_perfect_couple.jpeg` - Stick figure temperature meme
3. `meme_ice_cream.jpeg` - Ice cream meme
4. `meme_waking_up.jpeg` - Waking up meme
5. `mail_screenshot.jpeg` - Dutch email conversation
6. `ocr_test.jpeg` - Vietnamese restaurant receipt
7. `screen_photos.jpeg` - Dutch FAQ text
8. `text_photos.jpeg` - Dutch poetry on sign
9. `receipt_swiggy.jpg` - Indian food delivery receipt
10. `payment_transactions.png` - Payment app screenshot

Ground truth for all images is in `example/assets/test_ocr/ground_truth.json`.

#### Manual Navigation

- Use arrow buttons (← →) in the app to cycle through test images
- Camera/Gallery buttons to test with custom images
- "Run OCR" button to re-process current image
- Toggle overlay to see detected text boxes visually

## Development Tips

1. **⚠️ CRITICAL: No Large Dependencies**:

   - **NEVER add OpenCV or similar SDKs** - they add 10-20 MB of .so files
   - Only use Android's native APIs: Bitmap, Canvas, Matrix, Paint, etc.
   - Write custom implementations rather than importing large libraries
   - When the Python code uses cv2, find Android equivalents or implement in pure Kotlin
   - Accept minor differences in output vs Python if it means avoiding bloat

2. **Debugging OCR Results**:

   - Enable `save_crop_res` to save cropped text regions
   - Log preprocessing values to verify normalization
   - Check tensor shapes match expected model inputs

3. **Memory Management**:

   - Always dispose of bitmaps after use
   - Close ONNX tensors explicitly
   - Use bitmap.recycle() in Kotlin

4. **Coordinate Systems**:
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
