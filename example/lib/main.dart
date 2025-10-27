import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_ocr/mobile_ocr.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mobile OCR Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const OcrDemoPage(),
    );
  }
}

class OcrDemoPage extends StatefulWidget {
  const OcrDemoPage({super.key});

  @override
  State<OcrDemoPage> createState() => _OcrDemoPageState();
}

class _OcrDemoPageState extends State<OcrDemoPage> {
  static const List<String> _testImageAssets = <String>[
    'assets/test_ocr/bob_ios_detection_issue.JPEG',
    'assets/test_ocr/mail_screenshot.jpeg',
    'assets/test_ocr/meme_ice_cream.jpeg',
    'assets/test_ocr/meme_love_you.jpeg',
    'assets/test_ocr/meme_perfect_couple.jpeg',
    'assets/test_ocr/meme_waking_up.jpeg',
    'assets/test_ocr/ocr_test.jpeg',
    'assets/test_ocr/payment_transactions.png',
    'assets/test_ocr/receipt_swiggy.jpg',
    'assets/test_ocr/screen_photos.jpeg',
    'assets/test_ocr/text_photos.jpeg',
  ];

  final ImagePicker _picker = ImagePicker();
  final MobileOcr _mobileOcr = MobileOcr();
  final Map<String, String> _cachedAssetPaths = <String, String>{};
  Directory? _assetCacheDirectory;
  String? _imagePath;
  bool _isPickingImage = false;
  bool _isCheckingHasText = false;
  bool? _lastHasTextResult;
  int? _currentTestImageIndex;
  bool _isLoadingTestImage = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mobile OCR'),
        actions: [
          if (_imagePath != null)
            IconButton(
              tooltip: 'Clear image',
              icon: const Icon(Icons.close),
              onPressed: () {
                setState(() {
                  _imagePath = null;
                  _lastHasTextResult = null;
                  _isCheckingHasText = false;
                });
              },
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _imagePath == null
                ? _buildPlaceholder(context)
                : TextDetectorWidget(
                    key: ValueKey(_imagePath),
                    imagePath: _imagePath!,
                    debugMode: true,
                    enableSelectionPreview: true,
                    onTextCopied: (text) => _showSnackBar(
                      context,
                      text.isEmpty
                          ? 'Copied empty text'
                          : 'Copied text (${text.length} chars)',
                    ),
                  ),
          ),
          if (_lastHasTextResult != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'hasText result: ${_lastHasTextResult!}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          _buildActionBar(context),
        ],
      ),
    );
  }

  Widget _buildPlaceholder(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.image_outlined,
            size: 96,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          Text(
            'Pick an image to run OCR',
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionBar(BuildContext context) {
    final hasImage = _imagePath != null;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                if (hasImage)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isCheckingHasText ? null : _checkHasText,
                      icon: const Icon(Icons.text_fields_outlined),
                      label: _isCheckingHasText
                          ? const Text('Checking...')
                          : const Text('hasText'),
                    ),
                  ),
                if (hasImage) const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isPickingImage
                        ? null
                        : () => _pickImage(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('Gallery'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _isPickingImage
                        ? null
                        : () => _pickImage(ImageSource.camera),
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: const Text('Camera'),
                  ),
                ),
              ],
            ),
            if (_testImageAssets.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  IconButton(
                    tooltip: 'Previous test image',
                    onPressed: _isLoadingTestImage
                        ? null
                        : () => _cycleTestImage(-1),
                    icon: const Icon(Icons.arrow_left),
                  ),
                  Expanded(
                    child: Center(
                      child: _isLoadingTestImage
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(
                              _currentTestImageIndex != null
                                  ? _formatAssetLabel(
                                      _testImageAssets[_currentTestImageIndex!],
                                    )
                                  : 'Tap arrows for test images',
                              style: Theme.of(context).textTheme.bodyMedium,
                              textAlign: TextAlign.center,
                            ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Next test image',
                    onPressed: _isLoadingTestImage
                        ? null
                        : () => _cycleTestImage(1),
                    icon: const Icon(Icons.arrow_right),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _checkHasText() async {
    final path = _imagePath;
    if (path == null) {
      return;
    }

    setState(() {
      _isCheckingHasText = true;
      _lastHasTextResult = null;
    });

    try {
      debugPrint('Checking hasText for $path');
      final result = await _mobileOcr.hasText(imagePath: path);
      if (!mounted) return;
      setState(() {
        _lastHasTextResult = result;
      });
      _showSnackBar(context, 'hasText result: $result');
    } catch (error) {
      if (!mounted) return;
      debugPrint('hasText failed for $path: $error');
      _showSnackBar(context, 'hasText failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isCheckingHasText = false;
        });
      }
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    setState(() {
      _isPickingImage = true;
    });

    try {
      final file = await _picker.pickImage(source: source);
      if (file == null) {
        return;
      }

      if (!mounted) return;
      setState(() {
        _imagePath = file.path;
        _lastHasTextResult = null;
        _isCheckingHasText = false;
      });
    } catch (error) {
      if (!mounted) return;
      _showSnackBar(context, 'Failed to pick image: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isPickingImage = false;
        });
      }
    }
  }

  Future<void> _cycleTestImage(int direction) async {
    if (_testImageAssets.isEmpty || _isLoadingTestImage) {
      return;
    }
    final total = _testImageAssets.length;
    final currentIndex = _currentTestImageIndex;
    final nextIndex = currentIndex == null
        ? (direction >= 0 ? 0 : total - 1)
        : _wrapIndex(currentIndex + direction, total);
    setState(() {
      _isLoadingTestImage = true;
    });
    try {
      final assetPath = _testImageAssets[nextIndex];
      final filePath = await _prepareTestAsset(assetPath);
      if (!mounted) return;
      setState(() {
        _currentTestImageIndex = nextIndex;
        _imagePath = filePath;
        _lastHasTextResult = null;
        _isCheckingHasText = false;
      });
    } catch (error) {
      if (!mounted) return;
      _showSnackBar(context, 'Failed to load test image: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingTestImage = false;
        });
      }
    }
  }

  Future<String> _prepareTestAsset(String assetPath) async {
    final cachedPath = _cachedAssetPaths[assetPath];
    if (cachedPath != null && await File(cachedPath).exists()) {
      return cachedPath;
    }
    final cacheDir = await _ensureAssetCacheDirectory();
    final fileName = assetPath.split('/').last;
    final filePath = '${cacheDir.path}${Platform.pathSeparator}$fileName';
    final file = File(filePath);
    final data = await rootBundle.load(assetPath);
    await file.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
    _cachedAssetPaths[assetPath] = file.path;
    return file.path;
  }

  Future<Directory> _ensureAssetCacheDirectory() async {
    final existing = _assetCacheDirectory;
    if (existing != null) {
      return existing;
    }
    final directory =
        await Directory.systemTemp.createTemp('mobile_ocr_example_assets_');
    _assetCacheDirectory = directory;
    return directory;
  }

  String _formatAssetLabel(String assetPath) {
    final fileName = assetPath.split('/').last;
    final baseName = fileName.split('.').first;
    return baseName.replaceAll('_', ' ');
  }

  int _wrapIndex(int value, int length) {
    final mod = value % length;
    return mod < 0 ? mod + length : mod;
  }

  void _showSnackBar(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
