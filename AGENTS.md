# Repository Guidelines

## Project Overview
- Flutter plugin delivering on-device OCR via PaddleOCR v5 ONNX models.
- Android Kotlin layer mirrors the original Python `OnnxOCR` pipeline without OpenCV, keeping dependencies lightweight.
- Example app in `example/` offers regression checks with meme, receipt, and UI screenshots to validate detection accuracy.

## Project Structure & Module Organization
- `lib/` exposes the Dart API: method channel wiring in `onnx_ocr_plugin_method_channel.dart`, platform interface abstractions, and convenience entry points.
- `android/src/main/kotlin/com/ente/onnx_ocr/` hosts native pipeline code (`OcrProcessor`, `TextDetector`, `TextRecognizer`, `TextClassifier`, utilities).
- `documentation/` contains the context and implementation guides—treat these as the contract when porting Python behavior.
- `example/` demonstrates integration, ships reference assets in `example/assets/test_ocr/`, and doubles as the manual verification harness.
- Models download at runtime via `ModelManager`; nothing under `models/` should be checked in.

## Build, Test, and Development Commands
- `flutter pub get` (run here and in `example/`) loads dependencies.
- `flutter analyze` keeps Dart surface compliant with `analysis_options.yaml`.
- `flutter test` exercises plugin unit tests; add targeted cases when modifying method channel logic.
- `./gradlew test` (from `android/`) runs JVM tests—use it when adding Kotlin utilities.
- Use the Task tool, not Bash, to run `flutter run` for the example app.

## Coding Style & Naming Conventions
- Dart follows the lint set in `analysis_options.yaml`: lowerCamelCase members, UpperCamelCase types, prefer const constructors.
- Kotlin sticks to 4-space indentation, expressive function names (`processDetections`, `prepareInputTensor`), and brief KDoc for tensor math or geometry helpers.
- Keep filenames lowercase_with_underscores except for Kotlin files, which use PascalCase.
- Never introduce OpenCV or other native `.so` dependencies; rely on Android graphics APIs or pure Kotlin alternatives.

## Testing Guidelines
- Maintain unit coverage for Dart components; mirror new platform-channel methods with tests in `test/`.
- Validate OCR results through the example app, comparing console output against `example/assets/test_ocr/ground_truth.json`.
- When adding geometry or tensor logic, supplement with Kotlin unit tests and document manual verification in PR notes.

## Commit & Pull Request Guidelines
- Subject lines stay under 72 characters and in imperative mood (`Add Android tensor helper`).
- Describe scope, testing performed, and model download considerations in the PR body; attach console snippets or screenshots for OCR changes.
- Reference tracking issues (`Fixes #123`) and flag any skipped tests or follow-up work.

## Security & Configuration Tips
- Keep credentials out of logs; redact user data before merging.
- ONNX models and dictionaries are fetched on demand—never vendor them into the repo.
- Review diffs for large binaries or debug artifacts; delete any stray cached downloads before submitting.
