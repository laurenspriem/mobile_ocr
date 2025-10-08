import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:onnx_mobile_ocr/onnx_mobile_ocr.dart';

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
  final ImagePicker _picker = ImagePicker();
  String? _imagePath;
  bool _isPickingImage = false;

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
                    onTextCopied: (text) => _showSnackBar(
                      context,
                      text.isEmpty
                          ? 'Copied empty text'
                          : 'Copied text (${text.length} chars)',
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
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        child: Row(
          children: [
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
      ),
    );
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

  void _showSnackBar(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
        ),
      );
  }

}
