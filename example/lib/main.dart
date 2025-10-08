import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:onnx_mobile_ocr/onnx_ocr_plugin.dart';
import 'package:image_picker/image_picker.dart';

// Feature flag: Set to true to enable automatic cycling through test images
const bool AUTO_CYCLE_TEST_IMAGES = false;
const int AUTO_CYCLE_INTERVAL_SECONDS = 10;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ONNX OCR Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
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
  final _ocrPlugin = OnnxMobileOcr();
  final ImagePicker _picker = ImagePicker();

  File? _imageFile;
  Uint8List? _imageBytes;
  List<TextBlock>? _detectedText;
  bool _isProcessing = false;
  bool _showTextOverlay = false;
  bool _includeAllConfidenceScores = false;
  TextBlock? _selectedText;
  String _platformVersion = 'Unknown';
  Size? _imageOriginalSize;
  bool _modelsReady = false;
  bool _isPreparingModels = false;
  Future<bool>? _prepareModelsFuture;
  String? _modelVersion;
  Directory? _assetCacheDirectory;

  // Test images list (starting with meme images)
  final List<String> _testImages = [
    'assets/test_ocr/meme_love_you.jpeg',
    'assets/test_ocr/meme_perfect_couple.jpeg',
    'assets/test_ocr/meme_ice_cream.jpeg',
    'assets/test_ocr/meme_waking_up.jpeg',
    'assets/test_ocr/text_photos.jpeg',
    'assets/test_ocr/payment_transactions.png',
    'assets/test_ocr/receipt_swiggy.jpg',
    'assets/test_ocr/screen_photos.jpeg',
    'assets/test_ocr/mail_screenshot.jpeg',
    'assets/test_ocr/ocr_test.jpeg',
  ];

  int _currentTestImageIndex = 0;
  Map<String, dynamic>? _groundTruth;
  Timer? _autoCycleTimer;
  bool _isFirstImageLoad = true;

  @override
  void initState() {
    super.initState();
    initPlatformState();
    _loadGroundTruth();
    _loadTestImage();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureModelsReady();
    });

    // Start auto-cycle timer if feature is enabled
    if (AUTO_CYCLE_TEST_IMAGES) {
      print(
        '\n🔄 AUTO-CYCLE MODE ENABLED: Images will cycle every $AUTO_CYCLE_INTERVAL_SECONDS seconds\n',
      );
      _startAutoCycleTimer();
    }
  }

  @override
  void dispose() {
    _autoCycleTimer?.cancel();
    super.dispose();
  }

  void _startAutoCycleTimer() {
    _autoCycleTimer?.cancel();
    _autoCycleTimer = Timer.periodic(
      Duration(seconds: AUTO_CYCLE_INTERVAL_SECONDS),
      (timer) {
        if (!_isProcessing) {
          _nextTestImage();
        }
      },
    );
  }

  void _stopAutoCycleTimer() {
    _autoCycleTimer?.cancel();
    _autoCycleTimer = null;
  }

  Future<void> initPlatformState() async {
    String platformVersion;
    try {
      platformVersion =
          await _ocrPlugin.getPlatformVersion() ?? 'Unknown platform version';
    } on PlatformException {
      platformVersion = 'Failed to get platform version.';
    }

    if (!mounted) return;

    setState(() {
      _platformVersion = platformVersion;
    });
  }

  Future<void> _loadGroundTruth() async {
    try {
      final jsonString = await rootBundle.loadString(
        'assets/test_ocr/ground_truth.json',
      );
      _groundTruth = json.decode(jsonString);
    } catch (e) {
      print('Failed to load ground truth: $e');
    }
  }

  Future<Directory> _ensureAssetCacheDirectory() async {
    final existing = _assetCacheDirectory;
    if (existing != null) {
      return existing;
    }

    final dir =
        await Directory.systemTemp.createTemp('onnx_ocr_assets_cache');
    _assetCacheDirectory = dir;
    return dir;
  }

  Future<File> _writeBytesToCacheFile(
    Uint8List bytes,
    String filename,
  ) async {
    final cacheDir = await _ensureAssetCacheDirectory();
    final file = File('${cacheDir.path}/$filename');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<bool> _ensureModelsReady() {
    final existing = _prepareModelsFuture;
    if (existing != null) {
      return existing;
    }

    final future = _prepareModels();
    _prepareModelsFuture = future;
    future.whenComplete(() {
      _prepareModelsFuture = null;
    });
    return future;
  }

  Future<bool> _prepareModels() async {
    if (mounted) {
      setState(() {
        _isPreparingModels = true;
      });
    }

    try {
      final status = await _ocrPlugin.prepareModels();
      if (!mounted) {
        return status.isReady;
      }

      setState(() {
        _modelsReady = status.isReady;
        _modelVersion = status.version;
      });

      if (!status.isReady) {
        _showError('Model preparation did not complete successfully.');
      }
      return status.isReady;
    } catch (e) {
      if (mounted) {
        _showError('Failed to prepare OCR models: $e');
      }
      return false;
    } finally {
      if (mounted) {
        setState(() {
          _isPreparingModels = false;
        });
      }
    }
  }

  Future<void> _loadTestImage() async {
    if (_currentTestImageIndex >= _testImages.length) return;

    try {
      final assetPath = _testImages[_currentTestImageIndex];
      final bytes = await rootBundle.load(assetPath);
      final imageBytes = bytes.buffer.asUint8List();
      final cachedFile = await _writeBytesToCacheFile(
        imageBytes,
        assetPath.split('/').last,
      );

      // Decode image to get dimensions
      final codec = await ui.instantiateImageCodec(imageBytes);
      final frame = await codec.getNextFrame();
      final uiImage = frame.image;

      setState(() {
        _imageFile = cachedFile;
        _imageBytes = imageBytes;
        _imageOriginalSize = Size(
          uiImage.width.toDouble(),
          uiImage.height.toDouble(),
        );
        _detectedText = null;
        _showTextOverlay = false;
        _selectedText = null;
      });

      uiImage.dispose();

      print('\n========================================');
      print('Loaded test image: ${assetPath.split('/').last}');
      print('========================================\n');

      // Wait 3 seconds before processing the first image to allow models to load
      if (_isFirstImageLoad) {
        print('⏳ Waiting 3 seconds for models to initialize...\n');
        await Future.delayed(const Duration(seconds: 3));
        _isFirstImageLoad = false;
      }

      // Auto-run OCR
      await _performOcr();
    } catch (e) {
      print('Failed to load test image: $e');
      _showError('Failed to load test image: $e');
    }
  }

  void _nextTestImage() {
    setState(() {
      _currentTestImageIndex =
          (_currentTestImageIndex + 1) % _testImages.length;
    });
    _loadTestImage();
  }

  void _previousTestImage() {
    // Stop auto-cycle when user manually navigates
    if (AUTO_CYCLE_TEST_IMAGES && _autoCycleTimer != null) {
      _stopAutoCycleTimer();
      print('⏸️  Auto-cycle stopped (manual navigation)');
    }

    setState(() {
      _currentTestImageIndex =
          (_currentTestImageIndex - 1 + _testImages.length) %
          _testImages.length;
    });
    _loadTestImage();
  }

  void _manualNextTestImage() {
    // Stop auto-cycle when user manually navigates
    if (AUTO_CYCLE_TEST_IMAGES && _autoCycleTimer != null) {
      _stopAutoCycleTimer();
      print('⏸️  Auto-cycle stopped (manual navigation)');
    }
    _nextTestImage();
  }

  Future<void> _pickImage(ImageSource source) async {
    // Stop auto-cycle when user manually picks an image
    if (AUTO_CYCLE_TEST_IMAGES) {
      _stopAutoCycleTimer();
      print('⏸️  Auto-cycle stopped (manual image selection)');
    }

    try {
      final XFile? image = await _picker.pickImage(source: source);
      if (image == null) return;

      final bytes = await image.readAsBytes();

      // Decode image to get dimensions
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final uiImage = frame.image;

      setState(() {
        _imageFile = File(image.path);
        _imageBytes = bytes;
        _imageOriginalSize = Size(
          uiImage.width.toDouble(),
          uiImage.height.toDouble(),
        );
        _detectedText = null;
        _showTextOverlay = false;
        _selectedText = null;
      });

      uiImage.dispose();
    } catch (e) {
      _showError('Failed to pick image: $e');
    }
  }

  Future<void> _performOcr() async {
    final imageFile = _imageFile;
    if (imageFile == null) {
      _showError('Please select an image first');
      return;
    }

    if (!await imageFile.exists()) {
      _showError('Image file not found on disk.');
      return;
    }

    setState(() {
      _isProcessing = true;
      _selectedText = null;
    });

    final modelsReady = await _ensureModelsReady();
    if (!modelsReady) {
      setState(() {
        _isProcessing = false;
      });
      return;
    }

    try {
      final result = await _ocrPlugin.detectText(
        imagePath: imageFile.path,
        includeAllConfidenceScores: _includeAllConfidenceScores,
      );
      setState(() {
        _detectedText = result;
        _showTextOverlay = true;
      });

      if (result.isEmpty) {
        _showMessage('No text detected in the image');
        print('No text detected');
      } else {
        _showMessage('Detected ${result.length} text region(s)');

        // Log recognized texts
        print('\n========== OCR RESULTS ==========');
        print('Total regions detected: ${result.length}');
        print('\nRecognized texts:');
        for (int i = 0; i < result.length; i++) {
          print(
            '${i + 1}. [${(result[i].confidence * 100).toStringAsFixed(1)}%] ${result[i].text}',
          );
        }
        print('================================\n');
      }

      // Always show ground truth if available
      final currentImageName = _testImages[_currentTestImageIndex]
          .split('/')
          .last;
      if (_groundTruth != null && _groundTruth!.containsKey(currentImageName)) {
        final groundTruthTexts =
            _groundTruth![currentImageName]['texts'] as List;
        print('Ground truth texts for $currentImageName:');
        for (int i = 0; i < groundTruthTexts.length; i++) {
          print('  ${i + 1}. ${groundTruthTexts[i]}');
        }
        print('');
      }
    } catch (e) {
      print('OCR ERROR: $e');
      _showError('OCR failed: $e');
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  void _toggleTextOverlay() {
    setState(() {
      _showTextOverlay = !_showTextOverlay;
      if (!_showTextOverlay) {
        _selectedText = null;
      }
    });
  }

  void _handleTapOnImage(
    TapDownDetails details,
    RenderBox renderBox,
    BoxFit fit,
  ) {
    if (_detectedText == null ||
        !_showTextOverlay ||
        _imageOriginalSize == null) {
      return;
    }

    // Get the actual position and size of the displayed image
    final localPosition = renderBox.globalToLocal(details.globalPosition);
    final displaySize = renderBox.size;

    // Calculate the actual image display area considering BoxFit.contain
    final fittedSizes = applyBoxFit(fit, _imageOriginalSize!, displaySize);
    final FittedSizes(:destination, :source) = fittedSizes;

    // Calculate offset where image is rendered (for centering)
    final dx = (displaySize.width - destination.width) / 2;
    final dy = (displaySize.height - destination.height) / 2;

    // Convert tap position to image coordinates
    final relativeX = (localPosition.dx - dx) / destination.width;
    final relativeY = (localPosition.dy - dy) / destination.height;

    if (relativeX < 0 || relativeX > 1 || relativeY < 0 || relativeY > 1) {
      return; // Tap is outside the image
    }

    final imageX = relativeX * _imageOriginalSize!.width;
    final imageY = relativeY * _imageOriginalSize!.height;
    final imagePoint = ui.Offset(imageX, imageY);

    // Find which text block was tapped
    for (final block in _detectedText!) {
      if (_polygonContainsPoint(block.points, imagePoint)) {
        setState(() {
          _selectedText = block;
        });
        _showTextDialog();
        break;
      }
    }
  }

  void _showTextDialog() {
    if (_selectedText == null) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Detected Text'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              _selectedText!.text,
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              'Confidence: ${(_selectedText!.confidence * 100).toStringAsFixed(1)}%',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _selectedText!.text));
              Navigator.pop(context);
              _showMessage('Text copied to clipboard');
            },
            child: const Text('Copy'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showAllDetectedText() {
    final blocks = _detectedText;
    if (blocks == null || blocks.isEmpty) {
      _showMessage('No text detected');
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('All Detected Text (${blocks.length} items)'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: blocks.length,
            itemBuilder: (context, index) {
              final block = blocks[index];
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  title: SelectableText(
                    block.text,
                    style: const TextStyle(fontSize: 14),
                  ),
                  subtitle: Text(
                    'Confidence: ${(block.confidence * 100).toStringAsFixed(1)}%',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.copy, size: 20),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: block.text));
                      _showMessage(
                        'Copied: ${block.text.substring(0, block.text.length.clamp(0, 30))}...',
                      );
                    },
                  ),
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              final allText = blocks.map((b) => b.text).join('\n');
              Clipboard.setData(ClipboardData(text: allText));
              Navigator.pop(context);
              _showMessage('All text copied to clipboard');
            },
            child: const Text('Copy All'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showError(String error) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error), backgroundColor: Colors.red));
  }

  @override
  Widget build(BuildContext context) {
    final bool isBusy = _isProcessing || _isPreparingModels;
    return Scaffold(
      appBar: AppBar(
        title: const Text('ONNX OCR Plugin Demo'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            color: Colors.grey[200],
            child: Text(
              'Running on: $_platformVersion',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (_isPreparingModels) ...[
            const LinearProgressIndicator(),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              child: Text(
                'Preparing OCR models...',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ] else if (!_modelsReady) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              child: Text(
                'OCR models will download the first time you run detection.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ] else if (_modelVersion != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              child: Text(
                'Models ready (version $_modelVersion)',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
          Expanded(
            child: _imageBytes == null
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.image_outlined,
                          size: 100,
                          color: Colors.grey,
                        ),
                        SizedBox(height: 16),
                        Text('Loading test image...'),
                      ],
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      return GestureDetector(
                        onTapDown: (details) {
                          if (_imageBytes != null) {
                            final RenderBox box =
                                context.findRenderObject() as RenderBox;
                            _handleTapOnImage(details, box, BoxFit.contain);
                          }
                        },
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _imageFile != null
                                ? Image.file(_imageFile!, fit: BoxFit.contain)
                                : Image.memory(
                                    _imageBytes!,
                                    fit: BoxFit.contain,
                                  ),
                            if (_showTextOverlay &&
                                _detectedText != null &&
                                _detectedText!.isNotEmpty &&
                                _imageOriginalSize != null)
                              CustomPaint(
                                size: constraints.biggest,
                                painter: TextOverlayPainter(
                                  textBlocks: _detectedText!,
                                  selectedBlock: _selectedText,
                                  imageOriginalSize: _imageOriginalSize!,
                                  displaySize: constraints.biggest,
                                  fit: BoxFit.contain,
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                if (_detectedText != null)
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.blue[50],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        Text('Found: ${_detectedText!.length} text(s)'),
                        Row(
                          children: [
                            const Text('Overlay'),
                            Switch(
                              value: _showTextOverlay,
                              onChanged: (value) => _toggleTextOverlay(),
                            ),
                          ],
                        ),
                        IconButton(
                          icon: const Icon(Icons.list_alt),
                          tooltip: 'View all text',
                          onPressed: _showAllDetectedText,
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                // Low confidence toggle
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orange[50],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.warning_amber,
                        size: 16,
                        color: Colors.orange,
                      ),
                      const SizedBox(width: 8),
                      const Text('Include low confidence (<80%)'),
                      Switch(
                        value: _includeAllConfidenceScores,
                        onChanged: (value) {
                          setState(() {
                            _includeAllConfidenceScores = value;
                          });
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                // Test image navigation
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AUTO_CYCLE_TEST_IMAGES && _autoCycleTimer != null
                        ? Colors.green[100]
                        : Colors.grey[100],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            onPressed: isBusy ? null : _previousTestImage,
                            icon: const Icon(Icons.arrow_back),
                            tooltip: 'Previous test image',
                          ),
                          Flexible(
                            child: Text(
                              'Test ${_currentTestImageIndex + 1}/${_testImages.length}: ${_testImages[_currentTestImageIndex].split('/').last}',
                              style: Theme.of(context).textTheme.bodySmall,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          IconButton(
                            onPressed: isBusy ? null : _manualNextTestImage,
                            icon: const Icon(Icons.arrow_forward),
                            tooltip: 'Next test image',
                          ),
                        ],
                      ),
                      if (AUTO_CYCLE_TEST_IMAGES && _autoCycleTimer != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            '🔄 Auto-cycling every ${AUTO_CYCLE_INTERVAL_SECONDS}s',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.green[700],
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton.icon(
                      onPressed: isBusy
                          ? null
                          : () => _pickImage(ImageSource.camera),
                      icon: const Icon(Icons.camera_alt),
                      label: const Text('Camera'),
                    ),
                    ElevatedButton.icon(
                      onPressed: isBusy
                          ? null
                          : () => _pickImage(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library),
                      label: const Text('Gallery'),
                    ),
                    ElevatedButton.icon(
                      onPressed: _imageBytes == null || isBusy
                          ? null
                          : _performOcr,
                      icon: _isProcessing
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.text_fields),
                      label: Text(
                        _isProcessing
                            ? 'Processing...'
                            : _isPreparingModels
                            ? 'Preparing...'
                            : 'Run OCR',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool _polygonContainsPoint(List<ui.Offset> polygon, ui.Offset point) {
    if (polygon.length < 3) {
      return false;
    }

    var inside = false;
    for (int i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final xi = polygon[i].dx;
      final yi = polygon[i].dy;
      final xj = polygon[j].dx;
      final yj = polygon[j].dy;

      final intersect = ((yi > point.dy) != (yj > point.dy)) &&
          (point.dx <
              (xj - xi) * (point.dy - yi) / ((yj - yi).abs() < 1e-6 ? 1e-6 : (yj - yi)) +
                  xi);
      if (intersect) {
        inside = !inside;
      }
    }
    return inside;
  }
}

class TextOverlayPainter extends CustomPainter {
  final List<TextBlock> textBlocks;
  final TextBlock? selectedBlock;
  final Size imageOriginalSize;
  final Size displaySize;
  final BoxFit fit;

  TextOverlayPainter({
    required this.textBlocks,
    this.selectedBlock,
    required this.imageOriginalSize,
    required this.displaySize,
    required this.fit,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final fittedSizes = applyBoxFit(fit, imageOriginalSize, displaySize);
    final FittedSizes(:destination, :source) = fittedSizes;

    final dx = (displaySize.width - destination.width) / 2;
    final dy = (displaySize.height - destination.height) / 2;

    canvas.save();
    canvas.translate(dx, dy);

    final scaleX = destination.width / imageOriginalSize.width;
    final scaleY = destination.height / imageOriginalSize.height;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    for (final block in textBlocks) {
      final isSelected = identical(selectedBlock, block);
      final score = block.confidence;

      if (isSelected) {
        paint
          ..color = Colors.blue
          ..strokeWidth = 3.0;
      } else if (score > 0.8) {
        paint
          ..color = Colors.green
          ..strokeWidth = 2.0;
      } else if (score > 0.5) {
        paint
          ..color = Colors.orange
          ..strokeWidth = 2.0;
      } else {
        paint
          ..color = const Color(0xB3F44336)
          ..strokeWidth = 2.0;
      }

      final polygon = block.points
          .map(
            (point) => ui.Offset(
              point.dx * scaleX,
              point.dy * scaleY,
            ),
          )
          .toList(growable: false);

      if (polygon.length >= 3) {
        final path = Path()..moveTo(polygon.first.dx, polygon.first.dy);
        for (int i = 1; i < polygon.length; i++) {
          path.lineTo(polygon[i].dx, polygon[i].dy);
        }
        path.close();
        canvas.drawPath(path, paint);
      } else {
        final rect = ui.Rect.fromLTWH(
          block.x * scaleX,
          block.y * scaleY,
          block.width * scaleX,
          block.height * scaleY,
        );
        canvas.drawRect(rect, paint);
      }

      if (block.text.isNotEmpty && polygon.length >= 2) {
        final labelColor = paint.color.withValues(alpha: 0.8);
        final textPainter = TextPainter(
          text: TextSpan(
            text: block.text.length > 30
                ? '${block.text.substring(0, 30)}...'
                : block.text,
            style: TextStyle(
              color: Colors.white,
              fontSize: 12,
              backgroundColor: labelColor,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();

        final topLeft = polygon.first;
        final topRight = polygon[1];
        final edgeVector = topRight - topLeft;
        final edgeLength = edgeVector.distance;

        if (edgeLength > 1e-3) {
          final angle = math.atan2(edgeVector.dy, edgeVector.dx);
          final normal = ui.Offset(-edgeVector.dy, edgeVector.dx);
          final normalLength = normal.distance;
          final unitNormal = normalLength > 1e-3
              ? normal / normalLength
              : const ui.Offset(0, -1);
          const labelGap = 6.0;
          final midpoint = ui.Offset(
            (topLeft.dx + topRight.dx) / 2,
            (topLeft.dy + topRight.dy) / 2,
          );
          final anchor = midpoint + unitNormal * labelGap;

          canvas.save();
          canvas.translate(anchor.dx, anchor.dy);
          canvas.rotate(angle);
          canvas.translate(-textPainter.width / 2, -textPainter.height);
          textPainter.paint(canvas, ui.Offset.zero);
          canvas.restore();
        } else {
          final bounds = _polygonBounds(polygon);
          final textPosition = ui.Offset(bounds.left, bounds.top - textPainter.height);
          textPainter.paint(canvas, textPosition);
        }
      }
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(TextOverlayPainter oldDelegate) {
    return oldDelegate.textBlocks != textBlocks ||
        oldDelegate.selectedBlock != selectedBlock ||
        oldDelegate.imageOriginalSize != imageOriginalSize ||
        oldDelegate.displaySize != displaySize ||
        oldDelegate.fit != fit;
  }

  ui.Rect _polygonBounds(List<ui.Offset> polygon) {
    double minX = polygon.first.dx;
    double maxX = polygon.first.dx;
    double minY = polygon.first.dy;
    double maxY = polygon.first.dy;

    for (final point in polygon) {
      if (point.dx < minX) minX = point.dx;
      if (point.dx > maxX) maxX = point.dx;
      if (point.dy < minY) minY = point.dy;
      if (point.dy > maxY) maxY = point.dy;
    }

    return ui.Rect.fromLTRB(minX, minY, maxX, maxY);
  }
}
