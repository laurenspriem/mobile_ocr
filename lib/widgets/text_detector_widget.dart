import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:mobile_ocr/mobile_ocr_plugin.dart';
import 'package:mobile_ocr/models/text_block.dart';
import 'package:mobile_ocr/widgets/text_overlay_widget.dart';

const Color _entePrimaryColor = Color(0xFF1DB954);
const double _enteSelectionHighlightOpacity = 0.28;

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

  /// Whether to show the inline selection preview banner.
  final bool enableSelectionPreview;

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
    this.enableSelectionPreview = false,
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
  Timer? _editorHintTimer;
  bool _showEditorHint = false;
  bool _isNetworkError = false;

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

  @override
  void dispose() {
    _editorHintTimer?.cancel();
    super.dispose();
  }

  void _initializeFile() {
    // Create file reference (this is just a reference, not actual loading)
    final file = File(widget.imagePath);

    if (!mounted) return;

    _editorHintTimer?.cancel();

    setState(() {
      _imageFile = file;
      _isFileReady = true;
      _showEditorHint = false;
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
        _isNetworkError = false;
      });
      _initializeFile();
    }
  }

  Future<void> _ensureModelsReady() async {
    if (_modelsReady) return;

    _modelPreparation ??= _ocr
        .prepareModels()
        .then((status) {
          _modelsReady = status.isReady;
        })
        .catchError((error, _) {
          final errorStr = error.toString().toLowerCase();
          _isNetworkError =
              errorStr.contains('network') ||
              errorStr.contains('connection') ||
              errorStr.contains('timeout') ||
              errorStr.contains('failed to download') ||
              errorStr.contains('http');

          if (_isNetworkError) {
            _errorMessage =
                'Network connection required to download OCR models on first use';
          } else {
            _errorMessage = 'Could not prepare OCR models';
          }
          debugPrint('Model preparation error: $error');
        })
        .whenComplete(() {
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
        _errorMessage = null;
        _isNetworkError = false;
      });
    }

    try {
      await _ensureModelsReady();
      if (_errorMessage != null) {
        throw Exception(_errorMessage);
      }

      final blocks = await _ocr.detectText(imagePath: imagePath);

      if (mounted && widget.imagePath == imagePath) {
        setState(() {
          _detectedTextBlocks = blocks;
          _errorMessage = null;
        });
        _handleEditorHint(blocks);
      }
    } catch (e) {
      debugPrint('Error detecting text: $e');
      if (mounted && widget.imagePath == imagePath) {
        setState(() {
          // Show user-friendly message based on error type
          final errorStr = e.toString().toLowerCase();
          if (errorStr.contains('image') &&
              errorStr.contains('not') &&
              errorStr.contains('exist')) {
            _errorMessage = 'Image file not found';
          } else if (errorStr.contains('failed to decode')) {
            _errorMessage = 'Could not read image file';
          } else {
            _errorMessage = 'Could not detect text in image';
          }
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CupertinoActivityIndicator(
                        radius: 10,
                        color: Colors.white,
                      ),
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
          if (_showEditorHint &&
              _detectedTextBlocks != null &&
              _detectedTextBlocks!.isNotEmpty)
            _buildEditorHint(),
          if (_errorMessage != null)
            Positioned(
              bottom: 32,
              left: 16,
              right: 16,
              child: _isNetworkError
                  ? _buildNetworkErrorBanner(_errorMessage!)
                  : _buildErrorBanner(_errorMessage!),
            ),
          // Show subtle message when no text was detected
          if (_detectedTextBlocks != null &&
              _detectedTextBlocks!.isEmpty &&
              _errorMessage == null)
            Positioned(
              top: 100,
              left: 0,
              right: 0,
              child: Center(child: _buildNoTextMessage()),
            ),
        ],
      ),
    );
  }

  Widget _buildEditorHint() {
    return Positioned(
      bottom: 36,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.75),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: CupertinoColors.activeBlue.withValues(alpha: 0.3),
                width: 0.8,
              ),
            ),
            child: const Text(
              'Drag across the text or double tap to select just what you need',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _handleEditorHint(List<TextBlock> blocks) {
    _editorHintTimer?.cancel();
    if (!mounted) {
      return;
    }

    if (blocks.isEmpty) {
      if (_showEditorHint) {
        setState(() {
          _showEditorHint = false;
        });
      }
      return;
    }

    setState(() {
      _showEditorHint = true;
    });

    _editorHintTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _showEditorHint = false;
      });
    });
  }

  void _dismissEditorHint() {
    if (!_showEditorHint) {
      return;
    }
    _editorHintTimer?.cancel();
    if (!mounted) {
      return;
    }
    setState(() {
      _showEditorHint = false;
    });
  }

  Widget _buildImageView() {
    // Show loading if file is not ready yet
    if (!_isFileReady || _imageFile == null) {
      return _buildLoadingIndicator();
    }

    if (_detectedTextBlocks != null) {
      final TextSelectionThemeData baseSelectionTheme = TextSelectionTheme.of(
        context,
      );
      final TextSelectionThemeData overlaySelectionTheme = baseSelectionTheme
          .copyWith(
            selectionColor: _entePrimaryColor.withValues(
              alpha: _enteSelectionHighlightOpacity,
            ),
            selectionHandleColor: _entePrimaryColor,
          );

      return TextSelectionTheme(
        data: overlaySelectionTheme,
        child: TextOverlayWidget(
          imageFile: _imageFile!,
          textBlocks: _detectedTextBlocks!,
          onTextBlocksSelected: widget.onTextBlocksSelected,
          onTextCopied: widget.onTextCopied,
          onSelectionStart: _dismissEditorHint,
          showUnselectedBoundaries: widget.showUnselectedBoundaries,
          enableSelectionPreview: widget.enableSelectionPreview,
          debugMode: widget.debugMode,
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: _isNetworkError
            ? _buildNetworkErrorBanner(_errorMessage!)
            : _buildErrorBanner(_errorMessage!),
      );
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
    return Container(
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
    );
  }

  Widget _buildNetworkErrorBanner(String message) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.orange.withValues(alpha: 0.3),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.orange.withValues(alpha: 0.2),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cloud_download_outlined,
            color: Colors.orange.shade300,
            size: 40,
          ),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w500,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () {
              setState(() {
                _errorMessage = null;
                _isNetworkError = false;
                _modelsReady = false;
              });
              _detectText();
            },
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Retry'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.orange.shade300,
              side: BorderSide(color: Colors.orange.shade300),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoTextMessage() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.search_off,
            color: Colors.white.withValues(alpha: 0.7),
            size: 16,
          ),
          const SizedBox(width: 8),
          Text(
            'No text detected',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.8),
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
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
