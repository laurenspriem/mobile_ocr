# OnnxOCR Plugin vs Python Reference

## High-Impact Deviations _(status 2025-10-06, Codex)_
- ✅ **Color channel order mismatch** – detection, recognition, and classification preprocessors now feed BGR tensors to ONNX (`android/src/main/kotlin/com/example/onnx_ocr_plugin/TextDetector.kt:73`, `TextRecognizer.kt:112`, `TextClassifier.kt:100`). This aligns us with the PaddleOCR training statistics used in the Python reference.
- ✅ **Detection geometry** – connected components are traced, converted to convex hulls, and fed through a rotating-calipers minimum-area rectangle implementation before scaling back to the source image (`TextDetector.kt:166-300`). Boxes are ordered with the same vertical grouping heuristic that the Python pipeline uses.
- ✅ **Unclip and contour handling** – instead of centroid scaling, rectangles are expanded using the PaddleOCR area/perimeter heuristic and then clamped to image bounds (`TextDetector.kt:421-463`). This mirrors pyclipper’s expansion behaviour for quadrilaterals.
- ✅ **Perspective crop quality** – crops now use an inverse perspective warp with Catmull–Rom bicubic sampling and replicate borders (`ImageUtils.kt:8-214`), closely mirroring `cv2.warpPerspective(..., INTER_CUBIC, BORDER_REPLICATE)`.
- ✅ **Angle classifier heuristics** – the native pipeline loads the classifier by default and runs it only when heuristics trigger (aspect ratio <0.5 or recognition confidence <0.65), staying lightweight while matching Python’s optional `use_angle_cls` (`OcrProcessor.kt:16-155`).
- ✅ **Large-image guard** – detector preprocessing now enforces the PaddleOCR `limit_side_len` rule on the longest side before rounding to multiples of 32 (`TextDetector.kt:93-108`).

## Detailed Differences

### Input Formatting & Normalization
1. [Resolved] **Color channel order** – Kotlin preprocessors now emit BGR tensors that mirror the cv2 pipeline (`TextDetector.kt:73-80`, `TextRecognizer.kt:112-119`, `TextClassifier.kt:100-107`).
2. [Open] **Data types** – Kotlin continues to operate solely in `Float`; Python occasionally promotes to float64. No accuracy deltas observed yet, but keep in mind for threshold tuning.
3. [Open] **Tensor creation** – Kotlin allocates fresh buffers each call. Python reuses NumPy arrays. This is a performance optimisation opportunity rather than a parity bug.

### Detection Pipeline
4. [Resolved] **Component discovery** – Connected components are now extracted via flood fill and converted into convex hulls before box fitting (`TextDetector.kt:166-205`).
5. [Resolved] **Polygon approximation** – Minimum-area rectangles are computed with rotating calipers, giving us oriented quads comparable to `cv2.minAreaRect` (`TextDetector.kt:242-300`).
6. [Resolved] **Box scoring** – Score calculation integrates probability values strictly inside the quadrilateral rather than over an axis-aligned bbox (`TextDetector.kt:212-239`).
7. [Resolved] **Minimum-area rectangle** – See item 5; bounding boxes now preserve rotation and correct side lengths.
8. [Resolved] **Unclip implementation** – Expansion uses the PaddleOCR area/perimeter heuristic with post-clamp to map bounds (`TextDetector.kt:421-463`).
9. [Resolved] **Clipping to bounds** – Every vertex is clamped before scaling back to the source image (`TextDetector.kt:421-463`).
10. [Resolved] **Line-order sorting** – Sorting now groups boxes by baseline tolerance before ordering left-to-right (`TextDetector.kt:387-414`).
11. [Open] **Detection config** – We still hardcode `det_box_type=quad`, `score_mode=fast`, and skip dilation. Flag for future configurability.
12. [Resolved] **Large-image guard** – Preprocessing caps the longest side at `limit_side_len` before padding to multiples of 32 (`TextDetector.kt:93-108`).

### Crop Extraction
13. [Resolved] **Perspective warp** – Manual inverse perspective warp with Catmull–Rom bicubic sampling and replicate borders mirrors the Python crop quality (`ImageUtils.kt:8-214`).
14. [Resolved] **Point ordering** – All quads are normalised to clockwise order before cropping (`ImageUtils.kt:84-118`, `OcrProcessor.kt:112-114`).
15. [Resolved] **Rotation heuristic** – The 90° correction is preserved post-warp; behaviour matches Python’s `np.rot90` branch for tall crops (`ImageUtils.kt:65-78`).

### Angle Classification
16. [Resolved] **Heuristic triggering** – Classification runs only for aspect-ratio outliers or low-confidence recognitions, retaining whichever recognition score is higher to avoid regressions (`OcrProcessor.kt:84-146`).
17. [Open] **Batch ordering** – Kotlin still processes classifier batches in input order. Reference sorts by aspect ratio first; consider mirroring if accuracy gaps resurface.
18. [Open] **Returned metadata** – We still return only rotated bitmaps. Python exposes classification labels/scores for debugging; add if diagnostic visibility becomes necessary.

### Text Recognition
19. [Resolved] **Color order** – Recognition preprocessing follows the same BGR channel ordering as detection (`TextRecognizer.kt:112-119`).
20. [Resolved] **Dynamic width & padding** – Batch width now matches Python’s `sorted_imgs` logic, using per-batch ratios, zero padding beyond the resized crop, and minimal blank space (`TextRecognizer.kt:52-127`).
21. [Parity] **CTC decoding & dictionary** – The Kotlin decoder mirrors Python’s blank/repeat removal and uses the same dictionary loading (space appended, blank prepended).

### Pipeline Control & Error Handling
24. [Open] **Detector/classifier reuse** – `OcrProcessor` still instantiates helper objects per request (`OcrProcessor.kt:107-126`). Consider caching if profiling shows churn.
25. [Resolved] **Bounds protection** – Vertices are clamped before cropping/drawing, preventing OOB errors (`TextDetector.kt:421-462`, `ImageUtils.kt:147-158`).
26. [Open] **Model toggles** – Angle classification heuristics now live in Kotlin, yet detection thresholds/score modes remain hardcoded. Future work: expose these through the Flutter API for experimentation (`OcrProcessor.kt:13-155`).
27. [Parity] **Drop score** – Both sides use 0.5 as the default recognition confidence cut-off.

### Miscellaneous
28. [Open] **Candidate limit** – We still evaluate every contour; Python caps at `max_candidates=1000` (`db_postprocess.py:33-46`). If performance regresses, mirror the limit.
29. [Open] **Binary map storage** – Kotlin uses `BooleanArray`; Python uses NumPy arrays. Purely a performance consideration.
30. [Open] **Error reporting** – Native side returns generic `PlatformException`s; richer diagnostics remain a to-do.
31. [Open] **Testing aids** – Python can persist intermediate crops; the plugin still lacks equivalent instrumentation hooks.

## Modernization Plan _(updated 2025-10-06)_

### Recently Completed
- **Stage 0 (parity quick wins)** – BGR preprocessing, limit-side resizing, and confidence heuristics are in place; angle classification now gates itself via heuristics instead of running globally.
- **Stage 1 (DB post-process fidelity)** – Component extraction, rotating-calipers rectangles, polygon scoring, and area/perimeter unclipping all align with the reference implementation.
- **Stage 2 (crop quality & recognition prep)** – Inverse homography uses Catmull–Rom bicubic sampling with replicate borders, and the recognizer/classifier match PaddleOCR’s width rounding and zero-padding semantics.

### Upcoming Focus Areas
1. **Reference artifact capture** – Run the Python pipeline with `save_crop_res` enabled (needs external env with OpenCV) and archive crops/logits so we can diff them against the Kotlin debug outputs.
2. **Recognition batching parity** – Mirror PaddleOCR’s per-batch aspect-ratio resorting and confirm whether an explicit softmax on ONNX logits is required; evaluate impact on the “I love you” sample.
3. **Classifier telemetry** – Expose classifier logits and applied-rotation flags through `DebugOptions`/Flutter so mis-rotations are easy to diagnose.
4. **Configuration surface** – Surface detection/recognition thresholds and angle-class toggles through the Dart API to unblock experimentation without native edits.

### Stage 3 – Verification & Regression Harness (Week 3)
- Instrument the plugin to optionally dump probability maps, detected polygons, cropped images, and recognition logits alongside the Python artifacts.
- Build a comparison harness that runs Python + plugin on identical inputs, diffs intermediate artifacts, and reports tolerances.
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
1. Generate Python reference crops/recognition outputs for the sample set (requires external env with OpenCV) and store them under `analysis/` for future diffs.
2. Add Kotlin debug toggles to dump pre-/post-angle crop bitmaps alongside recognition logits so we can compare against the Python artifacts when available.
3. Confirm whether the ONNX recognizer emits logits or probabilities; if logits, prototype an optional softmax step and measure its impact on the “Me randomly when I love you” sentence.
4. Prototype PaddleOCR-style per-batch width sorting in Kotlin and benchmark both accuracy and latency.