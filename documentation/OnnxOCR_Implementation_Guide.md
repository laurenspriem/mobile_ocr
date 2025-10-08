# OnnxOCR Implementation Guide for Flutter Plugin

## Overview
The OnnxOCR repository implements a complete OCR pipeline using ONNX runtime with PaddleOCR v5 models. The system consists of three main components working in sequence: text detection, text angle classification (optional), and text recognition.

## OCR Pipeline Architecture

### Pipeline Flow
1. **Input Image** → Text Detection → Detected Text Boxes
2. **Detected Boxes** → Crop & Extract Text Regions
3. **Text Regions** → (Optional) Angle Classification → Rotated if needed
4. **Processed Regions** → Text Recognition → Final Text Output

### Key Classes
- `TextSystem` (predict_system.py): Main orchestrator class
- `TextDetector` (predict_det.py): Handles text detection
- `TextClassifier` (predict_cls.py): Handles text angle classification
- `TextRecognizer` (predict_rec.py): Handles text recognition

## Model Details

### 1. Text Detection Model (`det.onnx`)
**Path**: `models/ppocrv5/det/det.onnx`
**Size**: ~4.75 MB
**Algorithm**: DB (Differentiable Binarization)

#### Input Requirements
- **Format**: RGB image as numpy array
- **Preprocessing Steps**:
  1. **Resize**:
     - Default limit_side_len: 960 pixels
     - Resize to multiple of 32 (required by network)
     - Maintains aspect ratio
  2. **Normalization**:
     - Scale: 1.0/255.0
     - Mean: [0.485, 0.456, 0.406]
     - Std: [0.229, 0.224, 0.225]
  3. **Channel Order**: Convert HWC to CHW
  4. **Batch Dimension**: Add batch dimension (1, C, H, W)

#### Output
- **Format**: Probability maps (shape: [1, 1, H, W])
- **Postprocessing** (DBPostProcess):
  - Threshold: 0.3 (binarization threshold)
  - Box threshold: 0.6 (minimum score for boxes)
  - Unclip ratio: 1.5 (box expansion factor)
  - Returns: List of quadrilateral boxes [[x1,y1], [x2,y2], [x3,y3], [x4,y4]]

### 2. Text Angle Classification Model (`cls.onnx`)
**Path**: `models/ppocrv5/cls/cls.onnx`
**Size**: ~583 KB
**Purpose**: Detect if text is rotated 180 degrees

#### Input Requirements
- **Format**: Cropped text region (RGB)
- **Image Shape**: (3, 48, 192) - CHW format
- **Preprocessing**:
  1. Resize to fit (48, 192) maintaining aspect ratio
  2. Normalize: (pixel/255.0 - 0.5) / 0.5
  3. Padding with zeros to fixed width

#### Output
- **Format**: Probability array for ["0", "180"] classes
- **Action**: If class "180" probability > 0.9, rotate image 180°

### 3. Text Recognition Model (`rec.onnx`)
**Path**: `models/ppocrv5/rec/rec.onnx`
**Size**: ~16.5 MB
**Algorithm**: SVTR_LCNet (default) with CTC decoder

#### Input Requirements
- **Format**: Cropped text region (RGB)
- **Image Shape**: (3, 48, 320) - CHW format
- **Batch Size**: 6 (default for processing multiple regions)
- **Preprocessing**:
  1. Calculate max width-height ratio for batch
  2. Resize maintaining aspect ratio (height: 48)
  3. Normalize: (pixel/255.0 - 0.5) / 0.5
  4. Pad to maximum width in batch

#### Output
- **Format**: Character probability matrix [batch, seq_len, vocab_size]
- **Postprocessing** (CTCLabelDecode):
  - Character dictionary: `ppocrv5_dict.txt` (Chinese + English + symbols)
  - Uses CTC blank token removal
  - Returns: (text_string, confidence_score)

## Key Processing Functions

### Image Cropping (utils.py)
```python
get_rotate_crop_image(img, points):
    # Perspective transform to extract text region
    # Auto-rotate if height/width ratio >= 1.5

get_minarea_rect_crop(img, points):
    # Minimum area rectangle crop
```

### Box Sorting (predict_system.py)
```python
sorted_boxes(dt_boxes):
    # Sort boxes top-to-bottom, left-to-right
    # Groups boxes on same line (y-diff < 10 pixels)
```

## Default Parameters

### Detection Parameters
- `det_algorithm`: "DB"
- `det_limit_side_len`: 960
- `det_limit_type`: "max"
- `det_db_thresh`: 0.3
- `det_db_box_thresh`: 0.6
- `det_db_unclip_ratio`: 1.5
- `det_box_type`: "quad"
- `use_dilation`: False
- `det_db_score_mode`: "fast"

### Classification Parameters
- `use_angle_cls`: False (disabled by default)
- `cls_image_shape`: "3, 48, 192"
- `cls_batch_num`: 6
- `cls_thresh`: 0.9
- `label_list`: ["0", "180"]

### Recognition Parameters
- `rec_algorithm`: "SVTR_LCNet"
- `rec_image_shape`: "3, 48, 320"
- `rec_batch_num`: 6
- `use_space_char`: True
- `drop_score`: 0.5 (minimum confidence threshold)

## ONNX Runtime Configuration

### Session Initialization
```python
providers = ['CUDAExecutionProvider', 'CPUExecutionProvider']  # GPU
providers = ['CPUExecutionProvider']  # CPU only
session = onnxruntime.InferenceSession(model_path, providers=providers)
```

### Model Input/Output Names
- Detection: Single input "x", single output for probability maps
- Classification: Single input, single output for class probabilities
- Recognition: Single input, single output for character probabilities

## Critical Implementation Notes

### 1. Coordinate System
- All coordinates are in pixels relative to original image
- Boxes are clipped to image boundaries
- Minimum box size: 3x3 pixels

### 2. Batch Processing
- Detection: Processes single images
- Classification: Batches up to 6 regions
- Recognition: Batches up to 6 regions
- Sorting by aspect ratio improves batch efficiency

### 3. Memory Management
- Images converted to float32 for processing
- Use numpy.copy() before ONNX inference
- Results filtered by confidence score

### 4. Performance Optimization
- Resize limit prevents memory overflow
- Multiple of 32 requirement for CNN efficiency
- "fast" scoring mode uses bounding box mean

## Android/Flutter Implementation Requirements

### Required Libraries
- ONNX Runtime for Android
- OpenCV or equivalent for image processing
- Support for numpy-like array operations

### Key Components to Implement
1. **Image Preprocessing Module**
   - Resize with aspect ratio preservation
   - Normalization operations
   - Channel reordering (HWC ↔ CHW)

2. **ONNX Model Loader**
   - Load three models into memory
   - Configure execution providers

3. **Postprocessing Module**
   - DB postprocessor for detection
   - CTC decoder for recognition
   - Character dictionary loader

4. **Geometry Operations**
   - Perspective transform
   - Polygon operations (using clipper algorithm)
   - Box sorting and filtering

### Input/Output Flow for Flutter Plugin

**Input**:
- Raw image data (Uint8List or similar)
- Configuration parameters (optional)

**Processing**:
1. Convert image to appropriate format
2. Run detection model
3. Extract text regions
4. Optionally classify angles
5. Run recognition model
6. Filter by confidence

**Output**:
```dart
class OCRResult {
  List<TextBox> boxes;  // Detected regions
  List<String> texts;    // Recognized text
  List<double> scores;   // Confidence scores
}

class TextBox {
  List<Point> points;  // 4 corner points
}
```

## Testing Recommendations

1. **Test Images**:
   - Various resolutions (small to large)
   - Different text orientations
   - Mixed languages (if supported)
   - Low contrast scenarios

2. **Performance Metrics**:
   - Detection speed
   - Recognition accuracy
   - Memory usage
   - Battery consumption

3. **Edge Cases**:
   - Empty images
   - Very small text
   - Rotated text
   - Overlapping text regions

## Dependencies

### Python Dependencies (for reference)
- onnxruntime
- opencv-python (cv2)
- numpy
- shapely (for polygon operations)
- pyclipper (for box expansion)
- PIL (Image processing)

### Equivalent Android/Java Libraries
- ONNX Runtime Android
- OpenCV Android SDK
- Clipper-java or similar
- Android Graphics/Canvas API