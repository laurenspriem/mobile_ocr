import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:onnx_ocr_plugin/onnx_ocr_plugin.dart';
import 'package:image_picker/image_picker.dart';

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
  final _ocrPlugin = OnnxOcrPlugin();
  final ImagePicker _picker = ImagePicker();

  File? _imageFile;
  Uint8List? _imageBytes;
  OcrResult? _ocrResult;
  bool _isProcessing = false;
  bool _showTextOverlay = false;
  TextResult? _selectedText;
  String _platformVersion = 'Unknown';
  Size? _imageOriginalSize;

  @override
  void initState() {
    super.initState();
    initPlatformState();
  }

  Future<void> initPlatformState() async {
    String platformVersion;
    try {
      platformVersion = await _ocrPlugin.getPlatformVersion() ?? 'Unknown platform version';
    } on PlatformException {
      platformVersion = 'Failed to get platform version.';
    }

    if (!mounted) return;

    setState(() {
      _platformVersion = platformVersion;
    });
  }

  Future<void> _pickImage(ImageSource source) async {
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
        _imageOriginalSize = Size(uiImage.width.toDouble(), uiImage.height.toDouble());
        _ocrResult = null;
        _showTextOverlay = false;
        _selectedText = null;
      });

      uiImage.dispose();
    } catch (e) {
      _showError('Failed to pick image: $e');
    }
  }

  Future<void> _performOcr() async {
    if (_imageBytes == null) {
      _showError('Please select an image first');
      return;
    }

    setState(() {
      _isProcessing = true;
      _selectedText = null;
    });

    try {
      final result = await _ocrPlugin.detectText(_imageBytes!);
      setState(() {
        _ocrResult = result;
        _showTextOverlay = true;
      });

      if (result.isEmpty) {
        _showMessage('No text detected in the image');
      } else {
        _showMessage('Detected ${result.texts.length} text region(s)');
      }
    } catch (e) {
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

  void _handleTapOnImage(TapDownDetails details, RenderBox renderBox, BoxFit fit) {
    if (_ocrResult == null || !_showTextOverlay || _imageOriginalSize == null) return;

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

    // Find which text box was tapped
    for (int i = 0; i < _ocrResult!.boxes.length; i++) {
      if (_ocrResult!.boxes[i].contains(imagePoint)) {
        setState(() {
          _selectedText = _ocrResult!.getResultAt(i);
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
              'Confidence: ${(_selectedText!.score * 100).toStringAsFixed(1)}%',
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
    if (_ocrResult == null || _ocrResult!.isEmpty) {
      _showMessage('No text detected');
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('All Detected Text (${_ocrResult!.texts.length} items)'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _ocrResult!.texts.length,
            itemBuilder: (context, index) {
              final text = _ocrResult!.texts[index];
              final score = _ocrResult!.scores[index];
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  title: SelectableText(
                    text,
                    style: const TextStyle(fontSize: 14),
                  ),
                  subtitle: Text(
                    'Confidence: ${(score * 100).toStringAsFixed(1)}%',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.copy, size: 20),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: text));
                      _showMessage('Copied: ${text.substring(0, text.length.clamp(0, 30))}...');
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
              final allText = _ocrResult!.texts.join('\n');
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _showError(String error) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error),
        backgroundColor: Colors.red,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
          Expanded(
            child: _imageFile == null
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.image_outlined, size: 100, color: Colors.grey),
                        SizedBox(height: 16),
                        Text('Select an image to perform OCR'),
                      ],
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      return GestureDetector(
                        onTapDown: (details) {
                          if (_imageFile != null) {
                            final RenderBox box = context.findRenderObject() as RenderBox;
                            _handleTapOnImage(details, box, BoxFit.contain);
                          }
                        },
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.file(
                              _imageFile!,
                              fit: BoxFit.contain,
                            ),
                            if (_showTextOverlay && _ocrResult != null && _imageOriginalSize != null)
                              CustomPaint(
                                size: constraints.biggest,
                                painter: TextOverlayPainter(
                                  ocrResult: _ocrResult!,
                                  selectedText: _selectedText,
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
                if (_ocrResult != null)
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.blue[50],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        Text('Found: ${_ocrResult!.texts.length} text(s)'),
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
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _isProcessing ? null : () => _pickImage(ImageSource.camera),
                      icon: const Icon(Icons.camera_alt),
                      label: const Text('Camera'),
                    ),
                    ElevatedButton.icon(
                      onPressed: _isProcessing ? null : () => _pickImage(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library),
                      label: const Text('Gallery'),
                    ),
                    ElevatedButton.icon(
                      onPressed: _imageBytes == null || _isProcessing ? null : _performOcr,
                      icon: _isProcessing
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.text_fields),
                      label: Text(_isProcessing ? 'Processing...' : 'Run OCR'),
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
}

class TextOverlayPainter extends CustomPainter {
  final OcrResult ocrResult;
  final TextResult? selectedText;
  final Size imageOriginalSize;
  final Size displaySize;
  final BoxFit fit;

  TextOverlayPainter({
    required this.ocrResult,
    this.selectedText,
    required this.imageOriginalSize,
    required this.displaySize,
    required this.fit,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Calculate the actual image display area considering BoxFit.contain
    final fittedSizes = applyBoxFit(fit, imageOriginalSize, displaySize);
    final FittedSizes(:destination, :source) = fittedSizes;

    // Calculate offset where image is rendered (for centering)
    final dx = (displaySize.width - destination.width) / 2;
    final dy = (displaySize.height - destination.height) / 2;

    // Save the canvas state and translate to image position
    canvas.save();
    canvas.translate(dx, dy);

    // Scale factor from original image to displayed image
    final scaleX = destination.width / imageOriginalSize.width;
    final scaleY = destination.height / imageOriginalSize.height;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    for (int i = 0; i < ocrResult.boxes.length; i++) {
      final box = ocrResult.boxes[i];
      final text = ocrResult.texts[i];
      final score = ocrResult.scores[i];

      // Set color based on selection and confidence
      if (selectedText != null && selectedText!.box == box) {
        paint.color = Colors.blue;
        paint.strokeWidth = 3.0;
      } else if (score > 0.8) {
        paint.color = Colors.green;
        paint.strokeWidth = 2.0;
      } else if (score > 0.5) {
        paint.color = Colors.orange;
        paint.strokeWidth = 2.0;
      } else {
        paint.color = Colors.red.withOpacity(0.7);
        paint.strokeWidth = 2.0;
      }

      // Draw the text box with scaled coordinates
      final path = Path();
      if (box.points.isNotEmpty) {
        final scaledPoints = box.points.map((p) =>
          Offset(p.dx * scaleX, p.dy * scaleY)
        ).toList();

        path.moveTo(scaledPoints.first.dx, scaledPoints.first.dy);
        for (int j = 1; j < scaledPoints.length; j++) {
          path.lineTo(scaledPoints[j].dx, scaledPoints[j].dy);
        }
        path.close();
        canvas.drawPath(path, paint);

        // Draw text label
        if (text.isNotEmpty && scaledPoints.isNotEmpty) {
          // Find the top-left point for label positioning
          double minY = scaledPoints.first.dy;
          double minX = scaledPoints.first.dx;
          for (final point in scaledPoints) {
            if (point.dy < minY) {
              minY = point.dy;
              minX = point.dx;
            }
          }

          final textPainter = TextPainter(
            text: TextSpan(
              text: text.length > 30 ? '${text.substring(0, 30)}...' : text,
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                backgroundColor: paint.color.withOpacity(0.8),
              ),
            ),
            textDirection: TextDirection.ltr,
          );
          textPainter.layout();

          // Position text above the box
          final textPosition = Offset(minX, minY - 20);
          textPainter.paint(canvas, textPosition);
        }
      }
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(TextOverlayPainter oldDelegate) {
    return oldDelegate.ocrResult != ocrResult ||
           oldDelegate.selectedText != selectedText ||
           oldDelegate.imageOriginalSize != imageOriginalSize ||
           oldDelegate.displaySize != displaySize;
  }
}