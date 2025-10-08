import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:mobile_ocr/mobile_ocr_plugin.dart';
import 'package:mobile_ocr/models/text_block.dart';
import 'package:mobile_ocr/widgets/text_overlay_widget.dart';

/// A complete text detection widget that displays an image and allows
/// users to select and copy detected text.
class TextDetectorWidget extends StatefulWidget {
  /// The path to the image file to detect text from
  final String imagePath;

  /// Callback when text is copied
  final Function(String)? onTextCopied;

  /// Callback when text blocks are selected
  final Function(List<TextBlock>)? onTextBlocksSelected;

  /// Whether to auto-detect text on load
  final bool autoDetect;

  /// Custom loading widget
  final Widget? loadingWidget;

  /// Background color
  final Color backgroundColor;

  /// Whether to show boundaries for unselected text
  final bool showUnselectedBoundaries;

  /// Enable debug utilities like the detected-text dialog.
  final bool debugMode;

  const TextDetectorWidget({
    super.key,
    required this.imagePath,
    this.onTextCopied,
    this.onTextBlocksSelected,
    this.autoDetect = true,
    this.loadingWidget,
    this.backgroundColor = Colors.black,
    this.showUnselectedBoundaries = true,
    this.debugMode = false,
  });

  @override
  State<TextDetectorWidget> createState() => _TextDetectorWidgetState();
}

class _TextDetectorWidgetState extends State<TextDetectorWidget> {
  final MobileOcr _ocr = MobileOcr();
  List<TextBlock>? _detectedTextBlocks;
  bool _isProcessing = false;
  File? _imageFile;
  bool _isFileReady = false;
  bool _modelsReady = false;
  Future<void>? _modelPreparation;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    // Set initial processing state if auto-detecting
    if (widget.autoDetect) {
      _isProcessing = true;
    }
    // Schedule file initialization after first frame to ensure immediate rendering
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeFile();
    });
  }

  void _initializeFile() {
    // Create file reference (this is just a reference, not actual loading)
    final file = File(widget.imagePath);

    if (!mounted) return;

    setState(() {
      _imageFile = file;
      _isFileReady = true;
    });

    // Now that file is ready, start detection if needed
    if (widget.autoDetect) {
      _preloadImageAndDetect();
    } else {
      // Preload image even when not auto-detecting
      if (mounted) {
        precacheImage(FileImage(file), context);
      }
    }
  }

  Future<void> _preloadImageAndDetect() async {
    if (_imageFile == null) return;
    // Preload image asynchronously (non-blocking)
    precacheImage(FileImage(_imageFile!), context);
    // Detect text immediately
    _detectText();
  }

  @override
  void didUpdateWidget(covariant TextDetectorWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imagePath != widget.imagePath) {
      setState(() {
        _isProcessing = widget.autoDetect;
        _detectedTextBlocks = null;
        _imageFile = null;
        _isFileReady = false;
        _errorMessage = null;
      });
      _initializeFile();
    }
  }

  Future<void> _ensureModelsReady() async {
    if (_modelsReady) return;

    _modelPreparation ??= _ocr.prepareModels().then((status) {
      _modelsReady = status.isReady;
    }).catchError((error, _) {
      _errorMessage = 'Failed to prepare OCR models: $error';
    }).whenComplete(() {
      _modelPreparation = null;
    });

    await _modelPreparation;
  }

  Future<void> _detectText() async {
    final String imagePath = widget.imagePath;

    // Don't set processing true here if already processing
    if (!_isProcessing) {
      setState(() {
        _isProcessing = true;
        _detectedTextBlocks = null;
      });
    }

    try {
      await _ensureModelsReady();
      if (_errorMessage != null) {
        throw Exception(_errorMessage);
      }

      final blocks = await _ocr.detectText(
        imagePath: imagePath,
      );

      if (mounted && widget.imagePath == imagePath) {
        setState(() {
          _detectedTextBlocks = blocks;
          _errorMessage = null;
        });
      }
    } catch (e) {
      debugPrint('Error detecting text: $e');
      if (mounted && widget.imagePath == imagePath) {
        setState(() {
          _errorMessage = e.toString();
        });
      }
    } finally {
      if (mounted && widget.imagePath == imagePath) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: widget.backgroundColor,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _buildImageView(),
          // Show processing indicator on top of image when detecting text
          if (_isFileReady && _isProcessing && _detectedTextBlocks == null)
            Positioned(
              top: 100,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CupertinoActivityIndicator(radius: 10, color: Colors.white),
                      SizedBox(width: 8),
                      Text(
                        'Detecting text...',
                        style: TextStyle(color: Colors.white, fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_errorMessage != null)
            Positioned(
              bottom: 32,
              left: 16,
              right: 16,
              child: _buildErrorBanner(_errorMessage!),
            ),
        ],
      ),
    );
  }

  Widget _buildImageView() {
    // Show loading if file is not ready yet
    if (!_isFileReady || _imageFile == null) {
      return _buildLoadingIndicator();
    }

    if (_detectedTextBlocks != null) {
      return TextOverlayWidget(
        imageFile: _imageFile!,
        textBlocks: _detectedTextBlocks!,
        onTextBlocksSelected: widget.onTextBlocksSelected,
        onTextCopied: widget.onTextCopied,
        showUnselectedBoundaries: widget.showUnselectedBoundaries,
        debugMode: widget.debugMode,
      );
    }

    if (_errorMessage != null) {
      return _buildErrorBanner(_errorMessage!);
    }

    return InteractiveViewer(
      minScale: 0.5,
      maxScale: 4.0,
      child: Center(
        child: Image.file(
          _imageFile!,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (wasSynchronouslyLoaded) {
              return child;
            }
            return AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              child: child,
            );
          },
        ),
      ),
    );
  }

  Widget _buildLoadingIndicator() {
    if (widget.loadingWidget != null) {
      return widget.loadingWidget!;
    }

    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: CupertinoColors.activeBlue.withValues(alpha: 0.3),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: CupertinoColors.activeBlue.withValues(alpha: 0.2),
              blurRadius: 20,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CupertinoActivityIndicator(
              radius: 14,
              color: CupertinoColors.activeBlue,
            ),
            const SizedBox(width: 12),
            Text(
              'Detecting Text',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorBanner(String message) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  /// Manually trigger text detection
  Future<void> detectText() {
    return _detectText();
  }

  /// Get the currently detected text blocks
  List<TextBlock>? get detectedTextBlocks => _detectedTextBlocks;

  /// Check if text detection is currently processing
  bool get isProcessing => _isProcessing;
}
