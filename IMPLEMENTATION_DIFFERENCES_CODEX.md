# OnnxOCR Plugin vs Python Reference

## High-Impact Deviations _(status 2025-10-05, Codex)_
- ✅ **Color channel order mismatch** – detection, recognition, and classification preprocessors now feed BGR tensors to ONNX (`android/src/main/kotlin/com/example/onnx_ocr_plugin/TextDetector.kt:73`, `TextRecognizer.kt:112`, `TextClassifier.kt:100`). This aligns us with the PaddleOCR training statistics used in the Python reference.
- ✅ **Detection geometry** – connected components are traced, converted to convex hulls, and fed through a rotating-calipers minimum-area rectangle implementation before scaling back to the source image (`TextDetector.kt:166-300`). Boxes are ordered with the same vertical grouping heuristic that the Python pipeline uses.
- ✅ **Unclip and contour handling** – instead of centroid scaling, rectangles are expanded using the PaddleOCR area/perimeter heuristic and then clamped to image bounds (`TextDetector.kt:421-463`). This mirrors pyclipper’s expansion behaviour for quadrilaterals.
- ✅ **Perspective crop quality** – crops are generated with an explicit inverse perspective warp and bilinear sampling with replicate borders (`ImageUtils.kt:8-82`, `ImageUtils.kt:187-214`). This matches the behaviour of `cv2.warpPerspective(..., INTER_CUBIC, BORDER_REPLICATE)` closely enough for our test set.
- ✅ **Angle classifier toggle** – angle classification is now optional. The default constructor disables it (matching `use_angle_cls=False` in Python) and only loads the classifier model when explicitly requested (`OcrProcessor.kt:20-137`).
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
13. [Resolved] **Perspective warp** – Manual inverse perspective warp with bilinear sampling and replicate borders matches the reference output more closely (`ImageUtils.kt:8-82`, `ImageUtils.kt:187-214`).
14. [Resolved] **Point ordering** – All quads are normalised to clockwise order before cropping (`ImageUtils.kt:84-118`, `OcrProcessor.kt:112-114`).
15. [Resolved] **Rotation heuristic** – The 90° correction is preserved post-warp; behaviour matches Python’s `np.rot90` branch for tall crops (`ImageUtils.kt:65-78`).

### Angle Classification
16. [Resolved] **Always-on classifier** – Angle classification is optional and disabled by default (`OcrProcessor.kt:20-137`).
17. [Open] **Batch ordering** – Kotlin still processes classifier batches in input order. Reference sorts by aspect ratio first; consider mirroring if accuracy gaps resurface.
18. [Open] **Returned metadata** – We still return only rotated bitmaps. Python exposes classification labels/scores for debugging; add if diagnostic visibility becomes necessary.

### Text Recognition
19. [Resolved] **Color order** – Recognition preprocessing follows the same BGR channel ordering as detection (`TextRecognizer.kt:112-119`).
20. [Parity] **Batch width calculation** – Both implementations maintain height 48, pad to the widest crop in the batch, and cap width at 320.
21. [Parity] **CTC decoding & dictionary** – The Kotlin decoder mirrors Python’s blank/repeat removal and uses the same dictionary loading (space appended, blank prepended).

### Pipeline Control & Error Handling
24. [Open] **Detector/classifier reuse** – `OcrProcessor` still instantiates helper objects per request (`OcrProcessor.kt:107-126`). Consider caching if profiling shows churn.
25. [Resolved] **Bounds protection** – Vertices are clamped before cropping/drawing, preventing OOB errors (`TextDetector.kt:421-462`, `ImageUtils.kt:147-158`).
26. [Open] **Model toggles** – Angle classification default now matches Python, but thresholds/score modes remain hardcoded. Future work: expose these through the Flutter API (`OcrProcessor.kt:20-137`).
27. [Parity] **Drop score** – Both sides use 0.5 as the default recognition confidence cut-off.

### Miscellaneous
28. [Open] **Candidate limit** – We still evaluate every contour; Python caps at `max_candidates=1000` (`db_postprocess.py:33-46`). If performance regresses, mirror the limit.
29. [Open] **Binary map storage** – Kotlin uses `BooleanArray`; Python uses NumPy arrays. Purely a performance consideration.
30. [Open] **Error reporting** – Native side returns generic `PlatformException`s; richer diagnostics remain a to-do.
31. [Open] **Testing aids** – Python can persist intermediate crops; the plugin still lacks equivalent instrumentation hooks.

## Modernization Plan _(updated 2025-10-05)_

### Recently Completed
- **Stage 0 (parity quick wins)** – BGR preprocessing, angle-classifier default handling, and resize/clamp safeguards now mirror the Python defaults.
- **Stage 1 (DB post-process fidelity)** – Component extraction, rotating-calipers rectangles, polygon scoring, and area/perimeter unclipping all align with the reference implementation.
- **Stage 2 (crop quality)** – Manual inverse homography with replicate borders is in place; further interpolation tweaks can iterate from this baseline.

### Upcoming Focus Areas
1. **Expose tuning knobs** – Surface detection thresholds, scoring modes, and optional angle classification through the Flutter API so future experiments do not require native changes.
2. **Performance profiling** – Measure the impact of per-request helper instantiation and consider caching ONNX tensors/buffers if GC pressure becomes visible on large batches.
3. **Diagnostics & tooling** – Provide hooks to return classifier confidences, save intermediate crops, or emit debug overlays to match the Python tooling experience.
4. **Candidate/throughput controls** – Evaluate whether replicating `max_candidates` or classifier batch sorting brings measurable gains once accuracy is confirmed on-device.

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
