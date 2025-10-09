import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_ocr/models/text_block.dart';

/// A widget that overlays detected text on top of the source image while
/// providing an editor-like selection experience.
class TextOverlayWidget extends StatefulWidget {
  final File imageFile;
  final List<TextBlock> textBlocks;
  final Function(List<TextBlock>)? onTextBlocksSelected;
  final Function(String)? onTextCopied;
  final VoidCallback? onSelectionStart;
  final bool showUnselectedBoundaries;
  final bool debugMode;

  const TextOverlayWidget({
    super.key,
    required this.imageFile,
    required this.textBlocks,
    this.onTextBlocksSelected,
    this.onTextCopied,
    this.onSelectionStart,
    this.showUnselectedBoundaries = true,
    this.debugMode = false,
  });

  @override
  State<TextOverlayWidget> createState() => _TextOverlayWidgetState();
}

class _TextOverlayWidgetState extends State<TextOverlayWidget> {
  static const double _epsilon = 1e-6;

  final GlobalKey _toolbarKey = GlobalKey();
  final TransformationController _transformController =
      TransformationController();

  Size? _imageSize;
  Size? _displaySize;
  Offset? _displayOffset;
  BoxConstraints? _lastConstraints;
  bool _metricsUpdateScheduled = false;
  _DisplayMetrics? _queuedMetrics;

  final Map<int, _BlockVisual> _blockVisuals = <int, _BlockVisual>{};
  final List<int> _blockOrder = <int>[];

  Map<int, TextSelection> _activeSelections = <int, TextSelection>{};
  _SelectionAnchor? _baseAnchor;
  _SelectionAnchor? _extentAnchor;
  bool _isSelecting = false;
  int _activePointerCount = 0;

  Offset _toolbarOffset = Offset.zero;
  bool _isToolbarDragging = false;
  Size? _toolbarSize;
  String _selectedTextPreview = '';

  @override
  void initState() {
    super.initState();
    _loadImageDimensions();
  }

  @override
  void didUpdateWidget(covariant TextOverlayWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.imageFile.path != widget.imageFile.path) {
      _resetForNewImage();
      return;
    }

    if (!identical(oldWidget.textBlocks, widget.textBlocks)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _computeBlockVisuals();
        });
      });
    }
  }

  Future<void> _loadImageDimensions() async {
    final bytes = await widget.imageFile.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;

    if (!mounted) {
      return;
    }

    setState(() {
      _imageSize = Size(image.width.toDouble(), image.height.toDouble());
    });
  }

  void _resetForNewImage() {
    setState(() {
      _imageSize = null;
      _displaySize = null;
      _displayOffset = null;
      _lastConstraints = null;
      _metricsUpdateScheduled = false;
      _queuedMetrics = null;
      _blockVisuals.clear();
      _blockOrder.clear();
      _activeSelections = <int, TextSelection>{};
      _baseAnchor = null;
      _extentAnchor = null;
      _isSelecting = false;
      _toolbarOffset = Offset.zero;
      _selectedTextPreview = '';
    });
    _loadImageDimensions();
  }

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildInteractiveImage(),
        if (_selectedTextPreview.isNotEmpty) _buildSelectionPreview(),
        if (widget.textBlocks.isNotEmpty) _buildSelectionToolbar(),
      ],
    );
  }

  Widget _buildInteractiveImage() {
    return LayoutBuilder(
      builder: (context, constraints) {
        _scheduleMetricsRebuild(constraints);

        return Listener(
          onPointerDown: (_) => _activePointerCount += 1,
          onPointerUp: (_) =>
              _activePointerCount = max(0, _activePointerCount - 1),
          onPointerCancel: (_) =>
              _activePointerCount = max(0, _activePointerCount - 1),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (details) {
              if (_activePointerCount > 1) {
                return;
              }
              _onPanStart(details);
            },
            onPanUpdate: (details) {
              if (_activePointerCount > 1) {
                return;
              }
              _onPanUpdate(details);
            },
            onPanEnd: (details) {
              if (_isSelecting) {
                _onPanEnd(details);
              }
            },
            onLongPressStart: (details) {
              if (_activePointerCount > 1) {
                return;
              }
              _onLongPressStart(details);
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
                      frameBuilder:
                          (context, child, frame, wasSynchronouslyLoaded) {
                            if (frame != null) {
                              _scheduleMetricsRebuild(constraints);
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
                  ..._buildEditableBlockOverlays(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _scheduleMetricsRebuild(BoxConstraints constraints) {
    if (_imageSize == null) {
      return;
    }

    if (_lastConstraints != null &&
        (_lastConstraints!.maxWidth - constraints.maxWidth).abs() < 0.5 &&
        (_lastConstraints!.maxHeight - constraints.maxHeight).abs() < 0.5) {
      return;
    }

    _lastConstraints = constraints;
    final metrics = _calculateMetrics(constraints);

    final bool needsUpdate =
        _displaySize == null ||
        !_roughlyEqualsSize(_displaySize!, metrics.size) ||
        _displayOffset == null ||
        !_roughlyEqualsOffset(_displayOffset!, metrics.offset);

    if (!needsUpdate) {
      return;
    }

    if (_metricsUpdateScheduled) {
      _queuedMetrics = metrics;
      return;
    }

    _metricsUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _metricsUpdateScheduled = false;
        _queuedMetrics = null;
        return;
      }
      final pending = _queuedMetrics ?? metrics;
      _queuedMetrics = null;
      _applyMetrics(pending);
      _metricsUpdateScheduled = false;
    });
  }

  _DisplayMetrics _calculateMetrics(BoxConstraints constraints) {
    final double imageAspect = _imageSize!.width / _imageSize!.height;
    final double containerAspect = constraints.maxWidth / constraints.maxHeight;

    double displayWidth;
    double displayHeight;

    if (imageAspect > containerAspect) {
      displayWidth = constraints.maxWidth;
      displayHeight = displayWidth / imageAspect;
    } else {
      displayHeight = constraints.maxHeight;
      displayWidth = displayHeight * imageAspect;
    }

    final double offsetX = (constraints.maxWidth - displayWidth) / 2;
    final double offsetY = (constraints.maxHeight - displayHeight) / 2;

    return _DisplayMetrics(
      Size(displayWidth, displayHeight),
      Offset(offsetX, offsetY),
    );
  }

  void _applyMetrics(_DisplayMetrics metrics) {
    setState(() {
      _displaySize = metrics.size;
      _displayOffset = metrics.offset;
      _computeBlockVisuals();
    });
  }

  List<Widget> _buildEditableBlockOverlays() {
    if (_displaySize == null || _imageSize == null || _displayOffset == null) {
      return const [];
    }

    final List<Widget> overlays = <Widget>[];
    for (final index in _blockOrder) {
      final visual = _blockVisuals[index];
      if (visual == null) {
        continue;
      }

      overlays.add(
        Positioned(
          left: visual.bounds.left,
          top: visual.bounds.top,
          width: visual.bounds.width,
          height: visual.bounds.height,
          child: IgnorePointer(
            child: CustomPaint(
              painter: _EditableBlockPainter(
                visual: visual,
                selection: _activeSelections[index],
                showBoundary: widget.showUnselectedBoundaries,
              ),
            ),
          ),
        ),
      );
    }

    return overlays;
  }

  Widget _buildSelectionPreview() {
    final mediaQuery = MediaQuery.of(context);
    return Positioned(
      top: mediaQuery.padding.top + 16,
      left: 16,
      right: 16,
      child: IgnorePointer(
        ignoring: true,
        child: AnimatedOpacity(
          opacity: _selectedTextPreview.isEmpty ? 0 : 1,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              _selectedTextPreview,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                height: 1.3,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSelectionToolbar() {
    final mediaQuery = MediaQuery.of(context);
    final screenWidth = mediaQuery.size.width;
    final screenHeight = mediaQuery.size.height;

    final bool hasSelection = _activeSelections.isNotEmpty;
    final bool hasAllSelected = hasSelection && _isEverythingSelected();

    final renderBox =
        _toolbarKey.currentContext?.findRenderObject() as RenderBox?;
    final Size? measuredSize = renderBox?.size;
    if (measuredSize != null) {
      _scheduleToolbarSizeUpdate(measuredSize);
    }
    final toolbarSize = measuredSize ?? _toolbarSize ?? const Size(220, 52);
    final double toolbarWidth = toolbarSize.width;
    final double toolbarHeight = toolbarSize.height;

    final double baseLeft = (screenWidth - toolbarWidth) / 2;
    final double baseBottom = mediaQuery.padding.bottom + 20;

    final double minLeft = 10.0;
    final double maxLeft = screenWidth - toolbarWidth - 10.0;
    final double minBottom = 20.0;
    final double maxBottom = screenHeight - toolbarHeight - 20.0;

    final double left = (baseLeft + _toolbarOffset.dx).clamp(
      minLeft,
      max(minLeft, maxLeft),
    );
    final double bottom = (baseBottom - _toolbarOffset.dy).clamp(
      minBottom,
      max(minBottom, maxBottom),
    );

    return Positioned(
      bottom: bottom,
      left: left,
      child: GestureDetector(
        onPanStart: (_) {
          setState(() {
            _isToolbarDragging = true;
          });
        },
        onPanUpdate: (details) {
          setState(() {
            _toolbarOffset += details.delta;
          });
        },
        onPanEnd: (_) {
          setState(() {
            _isToolbarDragging = false;
          });
        },
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.0, end: hasSelection ? 1.0 : 0.0),
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          builder: (context, value, child) {
            if (value <= 0) {
              return const SizedBox.shrink();
            }
            return Transform.scale(
              scale: value,
              child: Container(
                key: _toolbarKey,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
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
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      color: CupertinoColors.systemBlue,
                      borderRadius: BorderRadius.circular(14),
                      minimumSize: const Size(28, 28),
                      onPressed: hasSelection ? _copySelectedText : null,
                      child: const Row(
                        children: [
                          Icon(
                            CupertinoIcons.doc_on_clipboard,
                            size: 16,
                            color: Colors.white,
                          ),
                          SizedBox(width: 4),
                          Text(
                            'Copy',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      color: CupertinoColors.systemPurple,
                      borderRadius: BorderRadius.circular(14),
                      minimumSize: const Size(28, 28),
                      onPressed: widget.textBlocks.isEmpty || hasAllSelected
                          ? null
                          : _selectAllBlocks,
                      child: const Row(
                        children: [
                          Icon(
                            CupertinoIcons.checkmark_seal_fill,
                            size: 16,
                            color: Colors.white,
                          ),
                          SizedBox(width: 4),
                          Text(
                            'Select All',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(24, 24),
                      onPressed: hasSelection ? _clearSelection : null,
                      child: Opacity(
                        opacity: hasSelection ? 1 : 0.3,
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
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _scheduleToolbarSizeUpdate(Size size) {
    final current = _toolbarSize;
    if (current != null &&
        (current.width - size.width).abs() < 0.5 &&
        (current.height - size.height).abs() < 0.5) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _toolbarSize = size;
      });
    });
  }

  void _onPanStart(DragStartDetails details) {
    final blockIndex = _hitTestBlock(details.localPosition);
    if (blockIndex == null) {
      _clearSelection();
      return;
    }

    final anchor = _anchorForPoint(blockIndex, details.localPosition);
    widget.onSelectionStart?.call();
    setState(() {
      _isSelecting = true;
      _baseAnchor = anchor;
      _extentAnchor = anchor;
      _activeSelections = _computeSelections(_baseAnchor, _extentAnchor);
      _selectedTextPreview = _selectionPreviewText();
    });
    if (_activeSelections.isNotEmpty) {
      HapticFeedback.selectionClick();
    }
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (!_isSelecting) {
      return;
    }

    final blockIndex =
        _hitTestBlock(details.localPosition) ??
        _nearestBlockIndex(details.localPosition);
    if (blockIndex == null) {
      return;
    }

    final anchor = _anchorForPoint(blockIndex, details.localPosition);
    setState(() {
      _extentAnchor = anchor;
      _activeSelections = _computeSelections(_baseAnchor, _extentAnchor);
      _selectedTextPreview = _selectionPreviewText();
    });
  }

  void _onPanEnd(DragEndDetails details) {
    if (!_isSelecting) {
      return;
    }

    setState(() {
      _isSelecting = false;
      if (_activeSelections.isEmpty) {
        _selectedTextPreview = '';
      }
    });

    if (_activeSelections.isNotEmpty) {
      HapticFeedback.lightImpact();
      _notifySelection();
    } else {
      _baseAnchor = null;
      _extentAnchor = null;
    }
  }

  void _onLongPressStart(LongPressStartDetails details) {
    final blockIndex = _hitTestBlock(details.localPosition);
    if (blockIndex == null) {
      return;
    }

    final anchor = _anchorForPoint(blockIndex, details.localPosition);
    widget.onSelectionStart?.call();
    setState(() {
      _isSelecting = true;
      _baseAnchor = anchor;
      _extentAnchor = anchor;
      _activeSelections = _computeSelections(_baseAnchor, _extentAnchor);
      _selectedTextPreview = _selectionPreviewText();
    });
    HapticFeedback.mediumImpact();
  }

  _SelectionAnchor _anchorForPoint(int blockIndex, Offset globalPoint) {
    final visual = _blockVisuals[blockIndex];
    if (visual == null || visual.characterCount == 0) {
      return _SelectionAnchor(blockIndex, const TextPosition(offset: 0));
    }

    final bounds = visual.bounds;
    if (globalPoint.dx <= bounds.left - 1) {
      return _SelectionAnchor(blockIndex, const TextPosition(offset: 0));
    }
    if (globalPoint.dx >= bounds.right + 1) {
      return _SelectionAnchor(
        blockIndex,
        TextPosition(offset: visual.characterCount),
      );
    }

    for (int i = 0; i < visual.characters.length; i++) {
      final character = visual.characters[i];
      if (_pointInPolygon(character.polygon, globalPoint)) {
        return _SelectionAnchor(blockIndex, TextPosition(offset: i));
      }
    }

    int bestIndex = 0;
    double bestDistance = double.infinity;
    for (int i = 0; i < visual.characters.length; i++) {
      final rect = visual.characters[i].bounds;
      final dx = _distanceToRange(globalPoint.dx, rect.left, rect.right);
      final dy = _distanceToRange(globalPoint.dy, rect.top, rect.bottom);
      final distance = sqrt(dx * dx + dy * dy);
      if (distance < bestDistance) {
        bestDistance = distance;
        bestIndex = i;
      }
    }

    return _SelectionAnchor(blockIndex, TextPosition(offset: bestIndex));
  }

  int? _hitTestBlock(Offset point) {
    for (final entry in _blockVisuals.entries) {
      final polygon = entry.value.scaledPolygon;
      if (polygon.isEmpty) {
        continue;
      }
      if (_pointInPolygon(polygon, point)) {
        return entry.key;
      }
    }
    return null;
  }

  int? _nearestBlockIndex(Offset point) {
    if (_blockVisuals.isEmpty) {
      return null;
    }

    int? nearestIndex;
    double smallestDistance = double.infinity;

    for (final entry in _blockVisuals.entries) {
      final rect = entry.value.bounds;
      final dx = _distanceToRange(point.dx, rect.left, rect.right);
      final dy = _distanceToRange(point.dy, rect.top, rect.bottom);
      final distance = sqrt(dx * dx + dy * dy);
      if (distance < smallestDistance) {
        smallestDistance = distance;
        nearestIndex = entry.key;
      }
    }

    return nearestIndex;
  }

  double _distanceToRange(double value, double min, double max) {
    if (value < min) return min - value;
    if (value > max) return value - max;
    return 0.0;
  }

  void _computeBlockVisuals() {
    _blockVisuals.clear();
    _blockOrder.clear();

    if (_displaySize == null || _imageSize == null || _displayOffset == null) {
      return;
    }

    for (final entry in widget.textBlocks.asMap().entries) {
      final index = entry.key;
      final block = entry.value;

      final scaledPoints = _getScaledPoints(block);
      if (scaledPoints.length < 3) {
        continue;
      }

      final bounds = _rectFromPoints(scaledPoints);
      if (bounds.width <= 0 || bounds.height <= 0) {
        continue;
      }

      final origin = bounds.topLeft;
      final localPolygon = scaledPoints
          .map((point) => point - origin)
          .toList(growable: false);
      final characters = _buildCharacterVisuals(block, scaledPoints, bounds);
      if (characters.isEmpty) {
        continue;
      }

      _blockVisuals[index] = _BlockVisual(
        index: index,
        block: block,
        scaledPolygon: scaledPoints,
        localPolygon: localPolygon,
        bounds: bounds,
        characters: characters,
      );
      _blockOrder.add(index);
    }

    _blockOrder.sort(_compareBlockIndices);
    _clampAnchorsToVisuals();
    _activeSelections = _computeSelections(_baseAnchor, _extentAnchor);
    _selectedTextPreview = _selectionPreviewText();
  }

  List<_CharacterVisual> _buildCharacterVisuals(
    TextBlock block,
    List<Offset> scaledBlockPolygon,
    Rect blockBounds,
  ) {
    final origin = blockBounds.topLeft;

    if (block.characters.isNotEmpty) {
      final visuals = <_CharacterVisual>[];
      for (final character in block.characters) {
        final scaled = _getScaledCharacterPoints(character);
        if (scaled.length < 3) {
          continue;
        }
        final localPolygon = scaled
            .map((point) => point - origin)
            .toList(growable: false);
        if (localPolygon.isEmpty) {
          continue;
        }
        final rect = _rectFromPoints(localPolygon);
        visuals.add(
          _CharacterVisual(
            text: character.text,
            confidence: character.confidence,
            polygon: localPolygon,
            bounds: rect,
          ),
        );
      }
      if (visuals.isNotEmpty) {
        return visuals;
      }
    }

    return _buildFallbackCharacters(block, scaledBlockPolygon, blockBounds);
  }

  List<_CharacterVisual> _buildFallbackCharacters(
    TextBlock block,
    List<Offset> scaledBlockPolygon,
    Rect blockBounds,
  ) {
    final origin = blockBounds.topLeft;

    if (scaledBlockPolygon.length < 4) {
      if (scaledBlockPolygon.length >= 3) {
        final localPolygon = scaledBlockPolygon
            .map((point) => point - origin)
            .toList(growable: false);
        final rect = _rectFromPoints(localPolygon);
        return [
          _CharacterVisual(
            text: block.text,
            confidence: block.confidence,
            polygon: localPolygon,
            bounds: rect,
          ),
        ];
      }
      return const [];
    }

    final topLeft = scaledBlockPolygon[0];
    final topRight = scaledBlockPolygon[1];
    final bottomRight = scaledBlockPolygon[2];
    final bottomLeft = scaledBlockPolygon[3];

    if (block.text.isEmpty) {
      final localPolygon = scaledBlockPolygon
          .map((point) => point - origin)
          .toList(growable: false);
      final rect = _rectFromPoints(localPolygon);
      return [
        _CharacterVisual(
          text: '',
          confidence: block.confidence,
          polygon: localPolygon,
          bounds: rect,
        ),
      ];
    }

    final characters = <_CharacterVisual>[];
    final text = block.text;
    final length = text.length;
    for (int i = 0; i < length; i++) {
      final startRatio = i / length;
      final endRatio = (i + 1) / length;

      final topStart = _interpolateOffset(topLeft, topRight, startRatio);
      final topEnd = _interpolateOffset(topLeft, topRight, endRatio);
      final bottomStart = _interpolateOffset(
        bottomLeft,
        bottomRight,
        startRatio,
      );
      final bottomEnd = _interpolateOffset(bottomLeft, bottomRight, endRatio);

      final polygon = <Offset>[topStart, topEnd, bottomEnd, bottomStart];
      final localPolygon = polygon
          .map((point) => point - origin)
          .toList(growable: false);
      final rect = _rectFromPoints(localPolygon);
      characters.add(
        _CharacterVisual(
          text: text[i],
          confidence: block.confidence,
          polygon: localPolygon,
          bounds: rect,
        ),
      );
    }

    return characters;
  }

  List<Offset> _getScaledCharacterPoints(CharacterBox character) {
    if (_displaySize == null || _imageSize == null || _displayOffset == null) {
      return const [];
    }

    final double scaleX = _displaySize!.width / _imageSize!.width;
    final double scaleY = _displaySize!.height / _imageSize!.height;

    return character.points
        .map(
          (point) => Offset(
            _displayOffset!.dx + (point.dx * scaleX),
            _displayOffset!.dy + (point.dy * scaleY),
          ),
        )
        .toList(growable: false);
  }

  Offset _interpolateOffset(Offset start, Offset end, double ratio) {
    final clamped = ratio.clamp(0.0, 1.0);
    return Offset(
      start.dx + (end.dx - start.dx) * clamped,
      start.dy + (end.dy - start.dy) * clamped,
    );
  }

  int _compareBlockIndices(int a, int b) {
    final visualA = _blockVisuals[a];
    final visualB = _blockVisuals[b];
    if (visualA == null || visualB == null) {
      return a.compareTo(b);
    }

    final rectA = visualA.bounds;
    final rectB = visualB.bounds;

    final double verticalDiff = rectA.top - rectB.top;
    final double verticalThreshold = max(rectA.height, rectB.height) * 0.25;
    if (verticalDiff.abs() > verticalThreshold) {
      return verticalDiff < 0 ? -1 : 1;
    }

    final double horizontalDiff = rectA.left - rectB.left;
    if (horizontalDiff.abs() > 2) {
      return horizontalDiff < 0 ? -1 : 1;
    }

    return a.compareTo(b);
  }

  void _clampAnchorsToVisuals() {
    if (_baseAnchor != null &&
        !_blockVisuals.containsKey(_baseAnchor!.blockIndex)) {
      _baseAnchor = null;
    } else if (_baseAnchor != null) {
      final visual = _blockVisuals[_baseAnchor!.blockIndex];
      if (visual != null) {
        final offset = _baseAnchor!.position.offset.clamp(
          0,
          visual.characterCount,
        );
        _baseAnchor = _SelectionAnchor(
          _baseAnchor!.blockIndex,
          TextPosition(offset: offset),
        );
      }
    }

    if (_extentAnchor != null &&
        !_blockVisuals.containsKey(_extentAnchor!.blockIndex)) {
      _extentAnchor = null;
    } else if (_extentAnchor != null) {
      final visual = _blockVisuals[_extentAnchor!.blockIndex];
      if (visual != null) {
        final offset = _extentAnchor!.position.offset.clamp(
          0,
          visual.characterCount,
        );
        _extentAnchor = _SelectionAnchor(
          _extentAnchor!.blockIndex,
          TextPosition(offset: offset),
        );
      }
    }
  }

  Map<int, TextSelection> _computeSelections(
    _SelectionAnchor? base,
    _SelectionAnchor? extent,
  ) {
    final result = <int, TextSelection>{};

    if (base == null || extent == null) {
      return result;
    }

    final int baseOrderIndex = _blockOrder.indexOf(base.blockIndex);
    final int extentOrderIndex = _blockOrder.indexOf(extent.blockIndex);
    if (baseOrderIndex == -1 || extentOrderIndex == -1) {
      return result;
    }

    var startAnchor = base;
    var endAnchor = extent;
    var startIndex = baseOrderIndex;
    var endIndex = extentOrderIndex;

    if (startIndex > endIndex) {
      startAnchor = extent;
      endAnchor = base;
      startIndex = extentOrderIndex;
      endIndex = baseOrderIndex;
    } else if (startIndex == endIndex &&
        endAnchor.position.offset < startAnchor.position.offset) {
      final temp = startAnchor;
      startAnchor = endAnchor;
      endAnchor = temp;
    }

    if (startAnchor.blockIndex == endAnchor.blockIndex &&
        startAnchor.position.offset == endAnchor.position.offset) {
      return result;
    }

    for (int i = startIndex; i <= endIndex; i++) {
      final blockIndex = _blockOrder[i];
      final visual = _blockVisuals[blockIndex];
      if (visual == null || visual.characterCount == 0) {
        continue;
      }

      int startOffset = 0;
      int endOffset = visual.characterCount;

      if (blockIndex == startAnchor.blockIndex) {
        startOffset = startAnchor.position.offset.clamp(
          0,
          visual.characterCount,
        );
      }
      if (blockIndex == endAnchor.blockIndex) {
        endOffset = endAnchor.position.offset.clamp(0, visual.characterCount);
      }

      if (blockIndex == startAnchor.blockIndex &&
          blockIndex == endAnchor.blockIndex) {
        final int minOffset = min(startOffset, endOffset);
        final int maxOffset = max(startOffset, endOffset);
        startOffset = minOffset;
        endOffset = maxOffset;
      }

      if (startOffset == endOffset) {
        continue;
      }

      result[blockIndex] = TextSelection(
        baseOffset: startOffset,
        extentOffset: endOffset,
      );
    }

    return result;
  }

  bool _isEverythingSelected() {
    if (_blockVisuals.isEmpty ||
        _activeSelections.length != _blockVisuals.length) {
      return false;
    }

    for (final entry in _activeSelections.entries) {
      final visual = _blockVisuals[entry.key];
      if (visual == null) {
        return false;
      }
      final selection = entry.value;
      if (selection.start != 0 || selection.end != visual.characterCount) {
        return false;
      }
    }

    return true;
  }

  void _copySelectedText() {
    final text = _collectSelectionText();
    if (text.isEmpty) {
      return;
    }

    Clipboard.setData(ClipboardData(text: text));
    widget.onTextCopied?.call(text);
    HapticFeedback.mediumImpact();

    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      _clearSelection();
    });
  }

  void _selectAllBlocks() {
    if (_blockOrder.isEmpty) {
      return;
    }

    final firstIndex = _blockOrder.first;
    final lastIndex = _blockOrder.last;
    final firstVisual = _blockVisuals[firstIndex];
    final lastVisual = _blockVisuals[lastIndex];
    if (firstVisual == null || lastVisual == null) {
      return;
    }

    widget.onSelectionStart?.call();
    setState(() {
      _baseAnchor = _SelectionAnchor(firstIndex, const TextPosition(offset: 0));
      _extentAnchor = _SelectionAnchor(
        lastIndex,
        TextPosition(offset: lastVisual.characterCount),
      );
      _activeSelections = _computeSelections(_baseAnchor, _extentAnchor);
      _selectedTextPreview = _selectionPreviewText();
    });
    _notifySelection();
    HapticFeedback.selectionClick();
  }

  void _clearSelection() {
    setState(() {
      _activeSelections = <int, TextSelection>{};
      _baseAnchor = null;
      _extentAnchor = null;
      _isSelecting = false;
      _toolbarOffset = Offset.zero;
      _selectedTextPreview = '';
    });
  }

  String _collectSelectionText() {
    final selectedIndices = _blockOrder
        .where((index) => _activeSelections.containsKey(index))
        .toList();
    if (selectedIndices.isEmpty) {
      return '';
    }

    final buffer = StringBuffer();
    for (int i = 0; i < selectedIndices.length; i++) {
      final index = selectedIndices[i];
      final selection = _activeSelections[index]!;
      final visual = _blockVisuals[index];
      if (visual == null || visual.characterCount == 0) {
        continue;
      }

      final start = selection.start.clamp(0, visual.characterCount);
      final end = selection.end.clamp(start, visual.characterCount);
      if (start < end) {
        final segment = visual.characters
            .sublist(start, end)
            .map((character) => character.text)
            .join();
        buffer.write(segment);
      }

      if (i < selectedIndices.length - 1) {
        final currentRect = visual.bounds;
        final nextVisual = _blockVisuals[selectedIndices[i + 1]];
        if (nextVisual != null) {
          final nextRect = nextVisual.bounds;
          final bool sameLine =
              (nextRect.top - currentRect.top).abs() <
              min(currentRect.height, nextRect.height) * 0.6;
          buffer.write(sameLine ? ' ' : '\n');
        } else {
          buffer.write('\n');
        }
      }
    }

    return buffer.toString();
  }

  String _selectionPreviewText() {
    final raw = _collectSelectionText().trim();
    if (raw.isEmpty) {
      return '';
    }
    const int maxLength = 160;
    if (raw.length <= maxLength) {
      return raw;
    }
    return '${raw.substring(0, maxLength - 1).trimRight()}…';
  }

  void _notifySelection() {
    if (widget.onTextBlocksSelected == null) {
      return;
    }

    final selectedBlocks = _blockOrder
        .where((index) => _activeSelections.containsKey(index))
        .map((index) => widget.textBlocks[index])
        .toList();

    if (selectedBlocks.isEmpty) {
      return;
    }

    widget.onTextBlocksSelected!(selectedBlocks);
  }

  List<Offset> _getScaledPoints(TextBlock block) {
    if (_displaySize == null || _imageSize == null || _displayOffset == null) {
      return const [];
    }

    final double scaleX = _displaySize!.width / _imageSize!.width;
    final double scaleY = _displaySize!.height / _imageSize!.height;

    return block.points
        .map(
          (point) => Offset(
            _displayOffset!.dx + (point.dx * scaleX),
            _displayOffset!.dy + (point.dy * scaleY),
          ),
        )
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

  bool _roughlyEqualsSize(Size a, Size b) {
    return (a.width - b.width).abs() < 0.5 && (a.height - b.height).abs() < 0.5;
  }

  bool _roughlyEqualsOffset(Offset a, Offset b) {
    return (a.dx - b.dx).abs() < 0.5 && (a.dy - b.dy).abs() < 0.5;
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
                            style: const TextStyle(fontWeight: FontWeight.w600),
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

class _SelectionAnchor {
  const _SelectionAnchor(this.blockIndex, this.position);

  final int blockIndex;
  final TextPosition position;
}

class _CharacterVisual {
  const _CharacterVisual({
    required this.text,
    required this.confidence,
    required this.polygon,
    required this.bounds,
  });

  final String text;
  final double confidence;
  final List<Offset> polygon;
  final Rect bounds;
}

class _BlockVisual {
  _BlockVisual({
    required this.index,
    required this.block,
    required this.scaledPolygon,
    required this.localPolygon,
    required this.bounds,
    required this.characters,
  });

  final int index;
  final TextBlock block;
  final List<Offset> scaledPolygon;
  final List<Offset> localPolygon;
  final Rect bounds;
  final List<_CharacterVisual> characters;

  int get characterCount => characters.length;
}

class _DisplayMetrics {
  const _DisplayMetrics(this.size, this.offset);

  final Size size;
  final Offset offset;
}

class _EditableBlockPainter extends CustomPainter {
  const _EditableBlockPainter({
    required this.visual,
    required this.showBoundary,
    this.selection,
  });

  final _BlockVisual visual;
  final bool showBoundary;
  final TextSelection? selection;

  @override
  void paint(Canvas canvas, Size size) {
    if (showBoundary && visual.localPolygon.length >= 3) {
      final boundaryPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9
        ..color = Colors.white.withValues(alpha: 0.18);
      final boundaryPath = Path()..addPolygon(visual.localPolygon, true);
      canvas.drawPath(boundaryPath, boundaryPaint);
    }

    if (selection != null && !selection!.isCollapsed) {
      final start = selection!.start.clamp(0, visual.characterCount);
      final end = selection!.end.clamp(start, visual.characterCount);
      if (start < end) {
        final highlightPaint = Paint()
          ..style = PaintingStyle.fill
          ..color = CupertinoColors.activeBlue.withValues(alpha: 0.35);
        for (int index = start; index < end; index++) {
          if (index >= visual.characters.length) break;
          final character = visual.characters[index];
          if (character.polygon.length >= 3) {
            final path = Path()..addPolygon(character.polygon, true);
            canvas.drawPath(path, highlightPaint);
          } else {
            canvas.drawRRect(
              RRect.fromRectAndRadius(
                character.bounds.inflate(1.5),
                const Radius.circular(3),
              ),
              highlightPaint,
            );
          }
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _EditableBlockPainter oldDelegate) {
    return oldDelegate.visual != visual ||
        oldDelegate.selection != selection ||
        oldDelegate.showBoundary != showBoundary;
  }
}
