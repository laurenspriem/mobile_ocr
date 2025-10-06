# OnnxOCR Plugin vs Python Reference

## High-Impact Deviations
- **Color channel order mismatch** – the plugin feeds tensors in RGB order for all three models (`android/src/main/kotlin/com/example/onnx_ocr_plugin/TextDetector.kt:68`, `TextRecognizer.kt:110`, `TextClassifier.kt:100`), while the Python ground truth keeps OpenCV's BGR ordering (`onnxocr/predict_det.py:94`, `onnxocr/predict_rec.py:62`). Because the PaddleOCR models were trained on BGR input, the mismatch shifts channel statistics and erodes recognition confidence.
- **Detection geometry reduced to axis-aligned boxes** – the plugin collapses contours to axis-aligned rectangles (`TextDetector.kt:285-312`), whereas Python derives true minimum-area rectangles with rotation (`onnxocr/db_postprocess.py:159-179`). Rotated or skewed text is therefore cropped incorrectly in the plugin.
- **Unclipping and contour handling simplified** – centroid-based expansion (`TextDetector.kt:358-399`) plus a hand-written flood-fill contour finder (`TextDetector.kt:179-244`) stand in for pyclipper’s polygon offset and OpenCV’s contour tracing (`onnxocr/db_postprocess.py:69-157`). This yields loose, unstable boxes and missed thin regions.
- **Perspective crop quality downgraded** – Android’s bilinear `Canvas.drawBitmap` warp (`android/src/main/kotlin/com/example/onnx_ocr_plugin/ImageUtils.kt:24-55`) lacks the cubic interpolation and replicate borders used in Python (`onnxocr/utils.py:24-48`), blurring edge characters and truncating strokes.
- **Angle classifier always enforced** – the plugin always runs the classifier (`android/src/main/kotlin/com/example/onnx_ocr_plugin/OcrProcessor.kt:80-84`), while Python only enables it when `use_angle_cls=True` (`onnxocr/utils.py:345`, `predict_system.py:20-36`). False rotations remove leading characters.
- **Large-image guard missing** – Python’s preprocessing always limits the longest side to ≤960 px (`onnxocr/operators.py:103-133`); the plugin accepts arbitrarily large bitmaps, causing memory pressure and inconsistent scaling.

## Detailed Differences

### Input Formatting & Normalization
1. **Color channel order**: Plugin extracts RGB (`TextDetector.kt:68-79`; `TextRecognizer.kt:110-119`; `TextClassifier.kt:100-107`). Python leaves arrays in BGR because inputs come from `cv2` (`onnxocr/predict_det.py:94-113`; `onnxocr/predict_rec.py:62-82`).
2. **Data types**: Plugin uses Kotlin `Float`; Python mixes float32 with float64 intermediates. Differences are minor but affect rounding near thresholds.
3. **Tensor creation**: Plugin recreates tensors via `FloatBuffer.wrap`; Python reuses NumPy arrays. Impact: performance only.

### Detection Pipeline
4. **Contour discovery**: Plugin’s BFS contour tracing (`TextDetector.kt:179-244`) lacks smoothing and hierarchy; Python relies on `cv2.findContours` + `cv2.approxPolyDP` (`onnxocr/db_postprocess.py:69-88`).
5. **Polygon approximation**: Plugin never simplifies polygons; Python uses Ramer–Douglas–Peucker (`db_postprocess.py:73-88`).
6. **Box scoring**: Plugin averages over the axis-aligned bounding rectangle (`TextDetector.kt:249-282`); Python masks the polygon interior before averaging (`db_postprocess.py:182-197`).
7. **Minimum-area rectangle**: Plugin uses min/max bounds (`TextDetector.kt:285-312`); Python runs `cv2.minAreaRect` and consistent point ordering (`db_postprocess.py:159-179`).
8. **Unclip implementation**: Plugin scales points outward from the centroid (`TextDetector.kt:358-399`); Python calls pyclipper offset (`db_postprocess.py:151-157`).
9. **Clipping to bounds**: Plugin forgets to clamp scaled boxes; Python clamps every vertex (`onnxocr/predict_det.py:61-75`). Missing clamp causes array-index crashes.
10. **Line-order sorting**: Plugin sorts purely by top-left y/x (`TextDetector.kt:350-355`); Python groups lines by y-delta tolerance first (`predict_system.py:45-68`).
11. **Detection config**: Plugin hardcodes quads, fast scoring, no dilation (`TextDetector.kt:13-18`). Python honours `det_box_type`, `det_db_score_mode`, `use_dilation`, and `max_candidates` (`predict_det.py:29-37`).
12. **Large-image guard**: Plugin lacks the ≤960 resizing path; Python enforces it before inference (`onnxocr/operators.py:103-133`).

### Crop Extraction
13. **Perspective warp**: Plugin uses `Matrix.setPolyToPoly` with bilinear sampling (`ImageUtils.kt:24-55`); Python uses `cv2.warpPerspective` with `INTER_CUBIC` + `BORDER_REPLICATE` (`onnxocr/utils.py:24-48`).
14. **Point ordering**: Plugin trusts incoming order; Python reorders clockwise first (`predict_det.py:50-58`).
15. **Rotation heuristic**: Plugin rotates via another bilinear resample (`ImageUtils.kt:56-70`); Python uses `np.rot90` (`onnxocr/utils.py:51-53`).

### Angle Classification
16. **Always-on classifier**: Plugin runs classifier unconditionally (`OcrProcessor.kt:80-84`). Python respects `use_angle_cls` flag (`predict_system.py:20-36`).
17. **Batch ordering**: Plugin preserves original list order (`TextClassifier.kt:19-43`); Python sorts by aspect ratio and restores order (`onnxocr/predict_cls.py:27-71`).
18. **Returned metadata**: Plugin only returns rotated bitmaps; Python yields label + score for debugging.

### Text Recognition
19. **Color order**: Same RGB/BGR issue as detection.
20. **Batch width calculation**: Both enforce height 48 & width ≤320; behaviour matches.
21. **Interpolation**: Plugin uses bilinear; Python uses linear. Difference minimal.
22. **CTC decoding**: Both strip repeats/blanks; plugin averages timestep maxima, Python masks confidences—behaviour equivalent.
23. **Dictionary handling**: Both append space and prepend blank identically.

### Pipeline Control & Error Handling
24. **Detector/classifier reuse**: Plugin instantiates wrappers per call (`OcrProcessor.kt:103-118`); Python reuses `TextSystem`. Performance impact only.
25. **Bounds protection**: Plugin doesn’t clamp before cropping (leads to OOB); Python ensures bounds (`predict_det.py:61-75`).
26. **Model toggles**: Plugin hides toggles for angle classifier, thresholds, etc.; Python exposes them via CLI args (`onnxocr/utils.py:271-370`).
27. **Drop score**: Both default to 0.5; parity.

### Miscellaneous
28. **Candidate limit**: Plugin scans all contours; Python caps at `max_candidates=1000` (`db_postprocess.py:33-46`).
29. **Binary map storage**: Plugin uses `BooleanArray`; Python uses NumPy. Only affects speed.
30. **Error reporting**: Plugin wraps errors in generic method-channel exceptions; Python surfaces richer diagnostics.
31. **Testing aids**: Python can save crops (`TextSystem.draw_crop_rec_res`); plugin lacks equivalent toggles.

## Modernization Plan

### Stage 0 – Quick Parity Fixes (Days 1–3)
- **RGB→BGR conversion** before tensor creation across detector, classifier, recognizer.
- **Respect Python toggles**: expose `use_angle_cls`, thresholds, scoring modes, `det_box_type` in the Dart API and wire through Kotlin. Disable the angle classifier by default to match Python.
- **Clamp and resize**: add ≤960px limit in detection preprocessing plus explicit vertex clamping before cropping to eliminate OOB crashes.
- **Add configuration tests**: ensure new toggles round-trip from Dart/Fuchsia layers.

**Success metric**: models run without crashes on large assets; recognition improves immediately on known samples (e.g., “I love you”).

### Stage 1 – Faithful DB Post-processing Port (Week 1–2)
- Swap flood-fill contour tracing for a proper border-following algorithm (Suzuki or similar) mirroring `cv2.findContours` output.
- Apply Ramer–Douglas–Peucker approximation and rotating-calipers minimum rectangles for consistent quadrilateral extraction.
- Integrate a pure-Java offset solution (Clipper2 Java port, JTS Topology Suite, or Apache Commons Geometry) to reproduce pyclipper’s unclip expansion without native binaries.
- Reproduce polygon-masked scoring, min-size filtering, and candidate limits exactly.

**Success metric**: plugin produces detection boxes that visually overlap Python output across the sample set.

### Stage 2 – High-Quality Perspective Crops (Week 2–3)
- Implement a Kotlin homography warp with bicubic interpolation and replicate-edge padding (can be built on top of RenderScript intrinsics or manual sampling loops).
- Normalise point ordering before homography computation to eliminate skew from misordered boxes.

**Success metric**: cropped glyph strips from plugin and Python become pixel-close when diffed.

### Stage 3 – Verification & Regression Harness (Week 3)
- Instrument the plugin to optionally dump probability maps, detected polygons, and cropped images.
- Build a comparison harness that runs Python + plugin on identical inputs, diffs intermediate artifacts, and reports thresholds.
- Capture golden outputs from the reference implementation; add JVM tests that assert the Kotlin pipeline matches within tolerance.

**Success metric**: automated regression suite flags drift; developers can iterate confidently.

### Stage 4 – Optional Enhancements & Contingencies (Week 4+)
- **Geometry/tooling options**: document when to lean on pure-Java libraries (JTS, Clipper2 Java) versus bespoke code or a tiny JNI shim (if pure Kotlin cannot hit accuracy targets). Keep each addition ≤1 MB to satisfy size constraints.
- **Fallback plan**: if pure JVM algorithms still underperform, scope a minimal native helper exposing only the necessary OpenCV routines (~300 KB) or explore training a lightweight detection model tailored for Android inputs.

**Success metric**: either pure JVM solution matches Python or stakeholders sign off on fallback path with clear size/performance trade-offs.

## Success Metrics & Monitoring
- **Baseline**: collect accuracy numbers (text match, average confidence) before changes.
- **Target**: ≥95 % text match against Python ground truth on provided test set; processing time ≤500 ms for 1080p image on target device.
- **Stretch**: parity within numerical tolerance across the diff harness.
- **Telemetry**: log toggles and model timings for field diagnostics (behind debug flag).

## Next Actions
1. Implement RGB→BGR conversion and ≤960 resize guard.
2. Expose `use_angle_cls` flag and disable classifier by default.
3. Add bounding-box clamping and unit tests covering large images.
4. Evaluate Clipper2 Java vs JTS for Stage 1 polygon needs and plan integration.

Staging the work keeps the plugin lightweight, aligns behaviour with the Python ground truth, and provides measurable checkpoints so the team can decide when accuracy is “good enough” or when to escalate to richer geometry tooling.
