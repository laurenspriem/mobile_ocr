import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:onnx_mobile_ocr/models/text_block.dart';

/// A widget that overlays detected text blocks on an image with selection capabilities
class TextOverlayWidget extends StatefulWidget {
  final File imageFile;
  final List<TextBlock> textBlocks;
  final Function(List<TextBlock>)? onTextBlocksSelected;
  final Function(String)? onTextCopied;
  final bool showUnselectedBoundaries;
  final bool debugMode;

  const TextOverlayWidget({
    super.key,
    required this.imageFile,
    required this.textBlocks,
    this.onTextBlocksSelected,
    this.onTextCopied,
    this.showUnselectedBoundaries = true,
    this.debugMode = false,
  });

  @override
  State<TextOverlayWidget> createState() => _TextOverlayWidgetState();
}

class _TextOverlayWidgetState extends State<TextOverlayWidget>
    with TickerProviderStateMixin {
  static const double _epsilon = 1e-6;
  Size? _imageSize;
  Size? _displaySize;
  Offset? _displayOffset;

  // Selection state
  final Set<int> _selectedIndices = {};
  bool _isDragging = false;
  Offset? _dragStart;
  Offset? _dragEnd;
  Rect? _selectionRect;

  // Toolbar drag state
  Offset _toolbarOffset = Offset.zero;
  bool _isToolbarDragging = false;

  // Animation controllers
  late AnimationController _selectionAnimController;
  late Animation<double> _selectionAnimation;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  late final Listenable _overlayAnimation;

  // For pinch to zoom
  final TransformationController _transformController = TransformationController();

  @override
  void initState() {
    super.initState();
    _loadImageDimensions();

    _selectionAnimController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );

    _selectionAnimation = CurvedAnimation(
      parent: _selectionAnimController,
      curve: Curves.easeOutCubic,
    );

    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(
      begin: 0.3,
      end: 0.5,
    ).animate(CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOut,
    ));

    _overlayAnimation = Listenable.merge([
      _pulseController,
      _selectionAnimController,
    ]);
  }

  @override
  void dispose() {
    _selectionAnimController.dispose();
    _pulseController.dispose();
    _transformController.dispose();
    super.dispose();
  }

  Future<void> _loadImageDimensions() async {
    final bytes = await widget.imageFile.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;

    if (mounted) {
      setState(() {
        _imageSize = Size(image.width.toDouble(), image.height.toDouble());
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildInteractiveImage(),
        if (_selectedIndices.isNotEmpty) _buildSelectionToolbar(),
      ],
    );
  }

  Widget _buildInteractiveImage() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          onPanStart: (details) {
            setState(() {
              _isDragging = true;
              _dragStart = details.localPosition;
              _dragEnd = details.localPosition;
              _selectedIndices.clear();
            });
            HapticFeedback.lightImpact();
          },
          onPanUpdate: (details) {
            setState(() {
              _dragEnd = details.localPosition;
              _updateSelectionRect();
              _updateSelectedBlocks();
            });
          },
          onPanEnd: (details) {
            setState(() {
              _isDragging = false;
              if (_selectedIndices.isNotEmpty) {
                _selectionAnimController.forward(from: 0);
                HapticFeedback.mediumImpact();
                _notifySelection();
              }
            });
          },
          child: InteractiveViewer(
            transformationController: _transformController,
            minScale: 0.5,
            maxScale: 4.0,
            child: Stack(
              children: [
                Center(
                  child: Image.file(
                    widget.imageFile,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                      if (frame != null && _displaySize == null) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          _calculateDisplayMetrics(constraints);
                        });
                      }
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
                if (_displaySize != null && _imageSize != null)
                  ..._buildTextOverlays(),
                if (_isDragging && _selectionRect != null)
                  _buildDragSelectionOverlay(),
              ],
            ),
          ),
        );
      },
    );
  }

  void _calculateDisplayMetrics(BoxConstraints constraints) {
    if (_imageSize == null) return;

    final double imageAspectRatio = _imageSize!.width / _imageSize!.height;
    final double containerAspectRatio = constraints.maxWidth / constraints.maxHeight;

    double displayWidth;
    double displayHeight;

    if (imageAspectRatio > containerAspectRatio) {
      displayWidth = constraints.maxWidth;
      displayHeight = constraints.maxWidth / imageAspectRatio;
    } else {
      displayHeight = constraints.maxHeight;
      displayWidth = constraints.maxHeight * imageAspectRatio;
    }

    final offsetX = (constraints.maxWidth - displayWidth) / 2;
    final offsetY = (constraints.maxHeight - displayHeight) / 2;

    setState(() {
      _displaySize = Size(displayWidth, displayHeight);
      _displayOffset = Offset(offsetX, offsetY);
    });
  }

  void _updateSelectionRect() {
    if (_dragStart == null || _dragEnd == null) return;

    final left = min(_dragStart!.dx, _dragEnd!.dx);
    final top = min(_dragStart!.dy, _dragEnd!.dy);
    final right = max(_dragStart!.dx, _dragEnd!.dx);
    final bottom = max(_dragStart!.dy, _dragEnd!.dy);

    _selectionRect = Rect.fromLTRB(left, top, right, bottom);
  }

  void _updateSelectedBlocks() {
    if (_selectionRect == null ||
        _displaySize == null ||
        _imageSize == null ||
        _displayOffset == null) {
      return;
    }

    _selectedIndices.clear();

    for (int i = 0; i < widget.textBlocks.length; i++) {
      final scaledPoints = _getScaledPoints(widget.textBlocks[i]);
      if (scaledPoints.isEmpty) {
        continue;
      }

      final bounds = _rectFromPoints(scaledPoints);
      if (!_selectionRect!.overlaps(bounds)) {
        continue;
      }

      if (_polygonIntersectsRect(scaledPoints, _selectionRect!)) {
        _selectedIndices.add(i);
      }
    }
  }

  List<Widget> _buildTextOverlays() {
    if (_displaySize == null || _imageSize == null || _displayOffset == null) {
      return [];
    }

    return widget.textBlocks.asMap().entries.map((entry) {
      final index = entry.key;
      final block = entry.value;
      final isSelected = _selectedIndices.contains(index);

      final scaledPoints = _getScaledPoints(block);
      if (scaledPoints.isEmpty) {
        return const SizedBox.shrink();
      }

      final bounds = _rectFromPoints(scaledPoints);
      final localPolygon = _toLocalPoints(scaledPoints, bounds.topLeft);

      return Positioned(
        left: bounds.left,
        top: bounds.top,
        width: bounds.width,
        height: bounds.height,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapDown: (details) {
            final tapPoint = Offset(
              bounds.left + details.localPosition.dx,
              bounds.top + details.localPosition.dy,
            );
            if (_pointInPolygon(scaledPoints, tapPoint)) {
              _handleTextBlockTap(index, block);
            }
          },
          child: AnimatedBuilder(
            animation: _overlayAnimation,
            builder: (context, child) {
              final double pulseValue =
                  isSelected ? _pulseAnimation.value : 0.0;
              final double selectionProgress = _selectionAnimation.value;
              return CustomPaint(
                painter: _TextBlockPainter(
                  polygon: localPolygon,
                  isSelected: isSelected,
                  showBoundary: widget.showUnselectedBoundaries,
                  pulseValue: pulseValue,
                  selectionProgress: selectionProgress,
                  isDragging: _isDragging,
                ),
              );
            },
          ),
        ),
      );
    }).toList();
  }

  Widget _buildDragSelectionOverlay() {
    if (_selectionRect == null) return const SizedBox.shrink();

    return Positioned(
      left: _selectionRect!.left,
      top: _selectionRect!.top,
      width: _selectionRect!.width,
      height: _selectionRect!.height,
      child: Container(
        decoration: BoxDecoration(
          color: CupertinoColors.activeBlue.withValues(alpha: 0.1),
          border: Border.all(
            color: CupertinoColors.activeBlue,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }

  List<Offset> _getScaledPoints(TextBlock block) {
    if (_displaySize == null || _imageSize == null || _displayOffset == null) {
      return const [];
    }

    final scaleX = _displaySize!.width / _imageSize!.width;
    final scaleY = _displaySize!.height / _imageSize!.height;

    return block.points
        .map((point) => Offset(
              _displayOffset!.dx + (point.dx * scaleX),
              _displayOffset!.dy + (point.dy * scaleY),
            ))
        .toList(growable: false);
  }

  Rect _rectFromPoints(List<Offset> points) {
    var minX = points.first.dx;
    var maxX = points.first.dx;
    var minY = points.first.dy;
    var maxY = points.first.dy;

    for (final point in points) {
      minX = min(minX, point.dx);
      maxX = max(maxX, point.dx);
      minY = min(minY, point.dy);
      maxY = max(maxY, point.dy);
    }

    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  List<Offset> _toLocalPoints(List<Offset> points, Offset origin) {
    return points
        .map((point) => point - origin)
        .toList(growable: false);
  }

  bool _polygonIntersectsRect(List<Offset> polygon, Rect rect) {
    if (polygon.any(rect.contains)) {
      return true;
    }

    final rectCorners = [
      rect.topLeft,
      rect.topRight,
      rect.bottomRight,
      rect.bottomLeft,
    ];
    if (rectCorners.any((corner) => _pointInPolygon(polygon, corner))) {
      return true;
    }

    final rectEdges = <(Offset, Offset)>[
      (rect.topLeft, rect.topRight),
      (rect.topRight, rect.bottomRight),
      (rect.bottomRight, rect.bottomLeft),
      (rect.bottomLeft, rect.topLeft),
    ];

    for (int i = 0; i < polygon.length; i++) {
      final start = polygon[i];
      final end = polygon[(i + 1) % polygon.length];

      for (final edge in rectEdges) {
        if (_segmentsIntersect(start, end, edge.$1, edge.$2)) {
          return true;
        }
      }
    }

    return false;
  }

  bool _pointInPolygon(List<Offset> polygon, Offset point) {
    if (polygon.length < 3) {
      return false;
    }

    var inside = false;
    for (int i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final xi = polygon[i].dx;
      final yi = polygon[i].dy;
      final xj = polygon[j].dx;
      final yj = polygon[j].dy;

      final intersects =
          ((yi > point.dy) != (yj > point.dy)) &&
          (point.dx <
              (xj - xi) *
                      (point.dy - yi) /
                      ((yj - yi).abs() < _epsilon ? _epsilon : (yj - yi)) +
                  xi);
      if (intersects) {
        inside = !inside;
      }
    }

    return inside;
  }

  bool _segmentsIntersect(Offset p1, Offset q1, Offset p2, Offset q2) {
    final o1 = _orientation(p1, q1, p2);
    final o2 = _orientation(p1, q1, q2);
    final o3 = _orientation(p2, q2, p1);
    final o4 = _orientation(p2, q2, q1);

    if (((o1 > 0 && o2 < 0) || (o1 < 0 && o2 > 0)) &&
        ((o3 > 0 && o4 < 0) || (o3 < 0 && o4 > 0))) {
      return true;
    }

    if (o1.abs() < _epsilon && _onSegment(p1, q1, p2)) return true;
    if (o2.abs() < _epsilon && _onSegment(p1, q1, q2)) return true;
    if (o3.abs() < _epsilon && _onSegment(p2, q2, p1)) return true;
    if (o4.abs() < _epsilon && _onSegment(p2, q2, q1)) return true;

    return false;
  }

  double _orientation(Offset a, Offset b, Offset c) {
    return (b.dx - a.dx) * (c.dy - a.dy) - (b.dy - a.dy) * (c.dx - a.dx);
  }

  bool _onSegment(Offset a, Offset b, Offset c) {
    return c.dx <= max(a.dx, b.dx) + _epsilon &&
        c.dx + _epsilon >= min(a.dx, b.dx) &&
        c.dy <= max(a.dy, b.dy) + _epsilon &&
        c.dy + _epsilon >= min(a.dy, b.dy);
  }

  Widget _buildSelectionToolbar() {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    return Positioned(
      bottom: (MediaQuery.of(context).padding.bottom + 20 - _toolbarOffset.dy)
          .clamp(20.0, screenHeight - 100),
      left: (_toolbarOffset.dx + screenWidth / 2 - 100).clamp(10.0, screenWidth - 210),
      child: GestureDetector(
        onPanStart: (details) {
          setState(() {
            _isToolbarDragging = true;
          });
        },
        onPanUpdate: (details) {
          setState(() {
            _toolbarOffset += details.delta;
          });
        },
        onPanEnd: (details) {
          setState(() {
            _isToolbarDragging = false;
          });
        },
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          builder: (context, value, child) {
            return Transform.scale(
              scale: value,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: _isToolbarDragging
                      ? Colors.black.withValues(alpha: 0.95)
                      : Colors.black.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: _isToolbarDragging ? 10 : 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      color: CupertinoColors.systemBlue,
                      borderRadius: BorderRadius.circular(14),
                      minimumSize: const Size(28, 28),
                      onPressed: _copySelectedText,
                      child: const Row(
                        children: [
                          Icon(CupertinoIcons.doc_on_clipboard,
                              size: 16, color: Colors.white),
                          SizedBox(width: 4),
                          Text('Copy',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              )),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      color: CupertinoColors.systemPurple,
                      borderRadius: BorderRadius.circular(14),
                      minimumSize: const Size(28, 28),
                      onPressed: _copyAllText,
                      child: const Row(
                        children: [
                          Icon(CupertinoIcons.doc_on_doc_fill,
                              size: 16, color: Colors.white),
                          SizedBox(width: 4),
                          Text('Copy All',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              )),
                        ],
                      ),
                    ),
                    if (widget.debugMode) ...[
                      const SizedBox(width: 8),
                      CupertinoButton(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(24, 24),
                        onPressed: _showDebugDialog,
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            CupertinoIcons.list_bullet_indent,
                            color: Colors.white70,
                            size: 14,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: 8),
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(24, 24),
                      onPressed: _clearSelection,
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          CupertinoIcons.xmark,
                          color: Colors.white70,
                          size: 14,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _handleTextBlockTap(int index, TextBlock block) {
    setState(() {
      if (_selectedIndices.contains(index)) {
        _selectedIndices.remove(index);
      } else {
        _selectedIndices.add(index);
      }
    });

    if (_selectedIndices.isNotEmpty) {
      _selectionAnimController.forward(from: 0);
    }

    HapticFeedback.lightImpact();
    _notifySelection();
  }

  void _notifySelection() {
    if (widget.onTextBlocksSelected != null) {
      final selectedBlocks = _selectedIndices
          .map((index) => widget.textBlocks[index])
          .toList();

      // Sort blocks by vertical position, then horizontal
      selectedBlocks.sort((a, b) {
        final aRect = a.boundingBox;
        final bRect = b.boundingBox;
        final yDiff = aRect.top.compareTo(bRect.top);
        if (yDiff != 0) return yDiff;
        return aRect.left.compareTo(bRect.left);
      });

      widget.onTextBlocksSelected!(selectedBlocks);
    }
  }

  void _copySelectedText() {
    if (_selectedIndices.isEmpty) return;

    final selectedBlocks = _selectedIndices
        .map((index) => widget.textBlocks[index])
        .toList();

    final text = _getTextFromBlocks(selectedBlocks);
    Clipboard.setData(ClipboardData(text: text));
    widget.onTextCopied?.call(text);

    HapticFeedback.mediumImpact();

    // Auto-hide after a short delay
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        _clearSelection();
      }
    });
  }

  void _copyAllText() {
    final text = _getTextFromBlocks(widget.textBlocks);
    Clipboard.setData(ClipboardData(text: text));
    widget.onTextCopied?.call(text);

    HapticFeedback.mediumImpact();

    // Auto-hide after a short delay
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        _clearSelection();
      }
    });
  }

  String _getTextFromBlocks(List<TextBlock> blocks) {
    // Sort blocks to create coherent paragraph
    final sortedBlocks = List<TextBlock>.from(blocks);
    sortedBlocks.sort((a, b) {
      final aRect = a.boundingBox;
      final bRect = b.boundingBox;
      final yDiff = aRect.top.compareTo(bRect.top);
      if (yDiff != 0) return yDiff;
      return aRect.left.compareTo(bRect.left);
    });

    // Group blocks by line (similar y position)
    final List<List<TextBlock>> lines = [];
    List<TextBlock> currentLine = [];
    double? lastBaseline;

    for (final block in sortedBlocks) {
      final rect = block.boundingBox;
      if (lastBaseline == null ||
          (rect.top - lastBaseline).abs() < rect.height / 2) {
        currentLine.add(block);
      } else {
        if (currentLine.isNotEmpty) {
          lines.add(currentLine);
        }
        currentLine = [block];
      }
      lastBaseline = rect.top;
    }
    if (currentLine.isNotEmpty) {
      lines.add(currentLine);
    }

    // Join text with appropriate spacing
    return lines.map((line) {
      line.sort((a, b) =>
          a.boundingBox.left.compareTo(b.boundingBox.left));
      return line.map((block) => block.text).join(' ');
    }).join('\n');
  }

  void _clearSelection() {
    setState(() {
      _selectedIndices.clear();
      _selectionRect = null;
      _toolbarOffset = Offset.zero;
    });
  }

  Future<void> _showDebugDialog() async {
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Detected Text (${widget.textBlocks.length})'),
          content: SizedBox(
            width: double.maxFinite,
            child: widget.textBlocks.isEmpty
                ? const Text('No text detected.')
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: widget.textBlocks.length,
                    separatorBuilder: (context, index) =>
                        const Divider(height: 16),
                    itemBuilder: (context, index) {
                      final block = widget.textBlocks[index];
                      final confidence = block.confidence.clamp(0, 1);
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            block.text.isEmpty ? '(empty)' : block.text,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Confidence: ${(confidence * 100).toStringAsFixed(1)}%',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.black54,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }
}

class _TextBlockPainter extends CustomPainter {
  final List<Offset> polygon;
  final bool isSelected;
  final bool showBoundary;
  final double pulseValue;
  final double selectionProgress;
  final bool isDragging;

  const _TextBlockPainter({
    required this.polygon,
    required this.isSelected,
    required this.showBoundary,
    required this.pulseValue,
    required this.selectionProgress,
    required this.isDragging,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (polygon.length < 3) return;

    final double clampedProgress =
        selectionProgress.clamp(0.0, 1.0).toDouble();
    final path = Path()..addPolygon(polygon, true);

    final double selectedFillAlpha =
        isDragging ? pulseValue.clamp(0.1, 0.6).toDouble() : 0.25;
    const double unselectedFillAlpha = 0.08;

    final Color? fillColor = isSelected
        ? CupertinoColors.activeBlue.withValues(alpha: selectedFillAlpha)
        : showBoundary
            ? Colors.grey.withValues(alpha: unselectedFillAlpha)
            : null;

    if (isSelected) {
      final shadowPaint = Paint()
        ..color = CupertinoColors.activeBlue.withValues(
          alpha: 0.18 * clampedProgress,
        )
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 4);
      canvas.drawPath(path, shadowPaint);
    }

    if (fillColor != null) {
      final fillPaint = Paint()
        ..style = PaintingStyle.fill
        ..color = fillColor;
      canvas.drawPath(path, fillPaint);
    }

    if (isSelected || showBoundary) {
      final strokeWidth = isSelected
          ? (ui.lerpDouble(1.0, 1.6, clampedProgress) ?? 1.4)
          : 0.8;

      final borderPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = isSelected
            ? CupertinoColors.activeBlue
            : Colors.grey.withValues(alpha: 0.25);
      canvas.drawPath(path, borderPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _TextBlockPainter oldDelegate) {
    return oldDelegate.polygon != polygon ||
        oldDelegate.isSelected != isSelected ||
        oldDelegate.showBoundary != showBoundary ||
        oldDelegate.pulseValue != pulseValue ||
        oldDelegate.selectionProgress != selectionProgress ||
        oldDelegate.isDragging != isDragging;
  }
}
