import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_ocr/models/text_block.dart';

const double _kHighlightHorizontalPadding = 2.5;
const double _kHighlightVerticalPadding = 1.6;
const double _kHighlightCornerRadius = 4.0;
const double _kHighlightLineToleranceFactor = 0.7;
const double _kCopyPointerHeight = 8.0;

/// A widget that overlays detected text on top of the source image while
/// providing an editor-like selection experience.
class TextOverlayWidget extends StatefulWidget {
  final File imageFile;
  final List<TextBlock> textBlocks;
  final Function(List<TextBlock>)? onTextBlocksSelected;
  final Function(String)? onTextCopied;
  final VoidCallback? onSelectionStart;
  final bool showUnselectedBoundaries;
  final bool enableSelectionPreview;
  final bool debugMode;

  const TextOverlayWidget({
    super.key,
    required this.imageFile,
    required this.textBlocks,
    this.onTextBlocksSelected,
    this.onTextCopied,
    this.onSelectionStart,
    this.showUnselectedBoundaries = true,
    this.enableSelectionPreview = false,
    this.debugMode = false,
  });

  @override
  State<TextOverlayWidget> createState() => _TextOverlayWidgetState();
}

class _TextOverlayWidgetState extends State<TextOverlayWidget> {
  static const double _epsilon = 1e-6;
  static const double _characterHitPadding = 3.0;
  static const double _handleHeadDiameter = 20.0;
  static const double _handlePointerHeight = 12.0;
  static const double _handlePointerWidth = 16.0;
  static const double _handleHitboxExtent = 44.0;
  static const double _copyButtonWidth = 104.0;
  static const double _copyButtonHeight = 34.0;
  static const double _copyButtonSpacing = 12.0;
  static const double _copyPointerHeight = _kCopyPointerHeight;
  static const Color _handleFillColor = Color(0xFF2563EB);
  static const Color _handleStrokeColor = Color(0xFF2563EB);
  static final RegExp _wordCharacterPattern = RegExp(
    r'[\p{L}\p{N}]',
    unicode: true,
  );

  final GlobalKey _interactiveViewerKey = GlobalKey();
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

  String _selectedTextPreview = '';
  Offset? _pendingDoubleTapScenePoint;
  _HandleType? _activeHandle;
  Offset? _activeHandleTouchOffset;

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

    if (!oldWidget.enableSelectionPreview && widget.enableSelectionPreview) {
      if (_activeSelections.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() {
            _updateSelectionPreview();
          });
        });
      }
    } else if (oldWidget.enableSelectionPreview &&
        !widget.enableSelectionPreview) {
      if (_selectedTextPreview.isNotEmpty) {
        setState(() {
          _selectedTextPreview = '';
        });
      }
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
      _selectedTextPreview = '';
      _pendingDoubleTapScenePoint = null;
      _activeHandle = null;
      _activeHandleTouchOffset = null;
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
        if (widget.enableSelectionPreview && _selectedTextPreview.isNotEmpty)
          _buildSelectionPreview(),
      ],
    );
  }

  Widget _buildInteractiveImage() {
    return LayoutBuilder(
      builder: (context, constraints) {
        _scheduleMetricsRebuild(constraints);
        final Widget? copyButton = _buildCopyHandleButton(constraints);

        return Listener(
          onPointerDown: (_) => _activePointerCount += 1,
          onPointerUp: (_) =>
              _activePointerCount = max(0, _activePointerCount - 1),
          onPointerCancel: (_) =>
              _activePointerCount = max(0, _activePointerCount - 1),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: _handleTapDown,
            onDoubleTapDown: _handleDoubleTapDown,
            onDoubleTap: _handleDoubleTap,
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
            onPanCancel: () {
              if (_isSelecting) {
                _onPanCancel();
              }
            },
            onLongPressStart: (details) {
              if (_activePointerCount > 1) {
                return;
              }
              _onLongPressStart(details);
            },
            child: InteractiveViewer(
              key: _interactiveViewerKey,
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
                  ..._buildSelectionHandles(),
                  if (copyButton != null) copyButton,
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Offset? _sceneFromViewport(Offset viewportPoint) {
    return _transformController.toScene(viewportPoint);
  }

  Offset? _sceneFromGlobal(Offset globalPoint) {
    final renderBox =
        _interactiveViewerKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) {
      return null;
    }
    final local = renderBox.globalToLocal(globalPoint);
    return _transformController.toScene(local);
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

  Rect? _selectedRegionBounds() {
    if (_activeSelections.isEmpty) {
      return null;
    }

    Rect? bounds;
    for (final entry in _activeSelections.entries) {
      final _BlockVisual? visual = _blockVisuals[entry.key];
      if (visual == null || visual.characterCount == 0) {
        continue;
      }

      final selection = entry.value;
      final int start = selection.start.clamp(0, visual.characterCount);
      final int end = selection.end.clamp(start, visual.characterCount);
      if (start >= end) {
        continue;
      }

      for (int i = start; i < end && i < visual.characters.length; i++) {
        final Rect charRect = visual.characters[i].bounds;
        if (charRect.isEmpty) {
          continue;
        }
        final Rect expanded = Rect.fromLTRB(
          charRect.left - _kHighlightHorizontalPadding,
          charRect.top - _kHighlightVerticalPadding,
          charRect.right + _kHighlightHorizontalPadding,
          charRect.bottom + _kHighlightVerticalPadding,
        );
        final Rect globalRect = expanded.shift(visual.bounds.topLeft);
        bounds = bounds == null
            ? globalRect
            : bounds.expandToInclude(globalRect);
      }
    }

    if (bounds == null) {
      final _SelectionAnchor? baseAnchor = _baseAnchor;
      if (baseAnchor != null) {
        final Rect? startRect = _caretRectForAnchor(baseAnchor, isStart: true);
        if (startRect != null) {
          bounds = startRect;
        }
      }
      final _SelectionAnchor? extentAnchor = _extentAnchor;
      if (extentAnchor != null) {
        final Rect? endRect = _caretRectForAnchor(extentAnchor, isStart: false);
        if (endRect != null) {
          bounds = bounds == null ? endRect : bounds.expandToInclude(endRect);
        }
      }
    }

    return bounds;
  }

  List<Widget> _buildSelectionHandles() {
    if (_activeSelections.isEmpty ||
        _baseAnchor == null ||
        _extentAnchor == null) {
      return const [];
    }

    final List<Widget> handles = <Widget>[];

    final _SelectionAnchor baseAnchor = _baseAnchor!;
    final Offset? startPoint = _handleAnchorPoint(baseAnchor, isStart: true);
    if (startPoint != null) {
      handles.add(_buildHandleWidget(anchorPoint: startPoint, isStart: true));
    }

    final _SelectionAnchor extentAnchor = _extentAnchor!;
    final Offset? endPoint = _handleAnchorPoint(extentAnchor, isStart: false);
    if (endPoint != null) {
      handles.add(_buildHandleWidget(anchorPoint: endPoint, isStart: false));
    }

    return handles;
  }

  Widget? _buildCopyHandleButton(BoxConstraints constraints) {
    if (_activeSelections.isEmpty || _activeHandle != null || _isSelecting) {
      return null;
    }

    final Rect? selectionBounds = _selectedRegionBounds();
    if (selectionBounds == null) {
      return null;
    }

    const double spacing = _copyButtonSpacing;
    const double totalHeight = _copyButtonHeight + _copyPointerHeight;

    double left = selectionBounds.center.dx - (_copyButtonWidth / 2);
    if (constraints.hasBoundedWidth) {
      final double minLeft = 8.0;
      final double maxLeft = max(
        minLeft,
        constraints.maxWidth - _copyButtonWidth - 8.0,
      );
      left = left.clamp(minLeft, maxLeft);
    }

    bool anchorAbove = true;
    double anchorY = selectionBounds.top - spacing;
    double top = anchorY - totalHeight;
    if (constraints.hasBoundedHeight) {
      final double minTop = 8.0;
      final double maxTop = max(
        minTop,
        constraints.maxHeight - totalHeight - 8.0,
      );
      if (top < minTop) {
        anchorAbove = false;
        anchorY = selectionBounds.bottom + spacing + (_handleHeadDiameter / 2);
        top = anchorY;
      }
      top = top.clamp(minTop, maxTop);
    }

    return Positioned(
      left: left,
      top: top,
      width: _copyButtonWidth,
      height: totalHeight,
      child: _CopyActionButton(
        onPressed: _copySelectedText,
        accentColor: _handleStrokeColor,
        width: _copyButtonWidth,
        height: _copyButtonHeight,
        anchorAboveSelection: anchorAbove,
        pointerHeight: _copyPointerHeight,
      ),
    );
  }

  Widget _buildHandleWidget({
    required Offset anchorPoint,
    required bool isStart,
  }) {
    final double left = anchorPoint.dx - (_handleHitboxExtent / 2);
    final double top = isStart
        ? anchorPoint.dy - _handleHitboxExtent
        : anchorPoint.dy;

    return Positioned(
      left: left,
      top: top,
      width: _handleHitboxExtent,
      height: _handleHitboxExtent,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: (details) => _onHandlePanStart(
          details,
          isStart ? _HandleType.base : _HandleType.extent,
        ),
        onPanUpdate: _onHandlePanUpdate,
        onPanEnd: (_) => _onHandlePanEnd(),
        onPanCancel: _onHandlePanCancel,
        child: Align(
          alignment: isStart ? Alignment.bottomCenter : Alignment.topCenter,
          child: _SelectionHandleVisual(
            fillColor: _handleFillColor,
            borderColor: _handleStrokeColor,
            isStart: isStart,
            headDiameter: _handleHeadDiameter,
            pointerHeight: _handlePointerHeight,
            pointerWidth: _handlePointerWidth,
          ),
        ),
      ),
    );
  }

  Offset? _handleAnchorPoint(_SelectionAnchor anchor, {required bool isStart}) {
    final Rect? caretRect = _caretRectForAnchor(anchor, isStart: isStart);
    if (caretRect == null) {
      return null;
    }
    return isStart ? caretRect.topLeft : caretRect.bottomRight;
  }

  bool _isScenePointOnHandle(Offset scenePoint) {
    if (_activeSelections.isEmpty ||
        _baseAnchor == null ||
        _extentAnchor == null) {
      return false;
    }

    final Offset? startPoint = _handleAnchorPoint(_baseAnchor!, isStart: true);
    if (startPoint != null) {
      final Rect startRect = Rect.fromLTWH(
        startPoint.dx - (_handleHitboxExtent / 2),
        startPoint.dy - _handleHitboxExtent,
        _handleHitboxExtent,
        _handleHitboxExtent,
      );
      if (startRect.contains(scenePoint)) {
        return true;
      }
    }

    final Offset? endPoint = _handleAnchorPoint(_extentAnchor!, isStart: false);
    if (endPoint != null) {
      final Rect endRect = Rect.fromLTWH(
        endPoint.dx - (_handleHitboxExtent / 2),
        endPoint.dy,
        _handleHitboxExtent,
        _handleHitboxExtent,
      );
      if (endRect.contains(scenePoint)) {
        return true;
      }
    }

    return false;
  }

  Rect? _caretRectForAnchor(_SelectionAnchor anchor, {required bool isStart}) {
    final _BlockVisual? visual = _blockVisuals[anchor.blockIndex];
    if (visual == null || visual.characterCount == 0) {
      return null;
    }

    final int count = visual.characterCount;
    int referenceIndex;
    if (isStart) {
      referenceIndex = _clampIndex(anchor.position.offset, 0, count - 1);
    } else {
      referenceIndex = _clampIndex(anchor.position.offset - 1, 0, count - 1);
    }

    final Rect? baseRect = _visibleRectNearIndex(
      visual,
      referenceIndex,
      preferForward: isStart,
    );
    if (baseRect == null) {
      return null;
    }

    final Rect inflated = Rect.fromLTRB(
      baseRect.left - _kHighlightHorizontalPadding,
      baseRect.top - _kHighlightVerticalPadding,
      baseRect.right + _kHighlightHorizontalPadding,
      baseRect.bottom + _kHighlightVerticalPadding,
    );

    return inflated.shift(visual.bounds.topLeft);
  }

  Rect? _visibleRectNearIndex(
    _BlockVisual visual,
    int index, {
    required bool preferForward,
  }) {
    if (visual.characterCount == 0) {
      return null;
    }

    final List<_CharacterVisual> characters = visual.characters;
    final int clamped = _clampIndex(index, 0, characters.length - 1);

    Rect candidate = characters[clamped].bounds;
    if (_isRenderableRect(candidate)) {
      return candidate;
    }

    if (preferForward) {
      for (int i = clamped + 1; i < characters.length; i++) {
        final Rect next = characters[i].bounds;
        if (_isRenderableRect(next)) {
          return next;
        }
      }
      for (int i = clamped - 1; i >= 0; i--) {
        final Rect prev = characters[i].bounds;
        if (_isRenderableRect(prev)) {
          return prev;
        }
      }
    } else {
      for (int i = clamped - 1; i >= 0; i--) {
        final Rect prev = characters[i].bounds;
        if (_isRenderableRect(prev)) {
          return prev;
        }
      }
      for (int i = clamped + 1; i < characters.length; i++) {
        final Rect next = characters[i].bounds;
        if (_isRenderableRect(next)) {
          return next;
        }
      }
    }

    return null;
  }

  void _onHandlePanStart(DragStartDetails details, _HandleType type) {
    final bool isStart = type == _HandleType.base;
    final _SelectionAnchor? activeAnchor = isStart
        ? _baseAnchor
        : _extentAnchor;
    final Offset? anchorPoint = activeAnchor == null
        ? null
        : _handleAnchorPoint(activeAnchor, isStart: isStart);
    final Offset? fingerScene = _sceneFromGlobal(details.globalPosition);
    _activeHandleTouchOffset = anchorPoint != null && fingerScene != null
        ? anchorPoint - fingerScene
        : null;

    widget.onSelectionStart?.call();
    setState(() {
      _activeHandle = type;
      _isSelecting = true;
      final Offset? targetPoint = fingerScene == null
          ? anchorPoint
          : fingerScene + (_activeHandleTouchOffset ?? Offset.zero);
      if (targetPoint != null) {
        final int? blockIndex =
            _hitTestBlock(targetPoint) ?? _nearestBlockIndex(targetPoint);
        if (blockIndex != null) {
          final _SelectionAnchor anchor = _anchorForPoint(
            blockIndex,
            targetPoint,
          );
          if (isStart) {
            _baseAnchor = anchor;
          } else {
            _extentAnchor = anchor;
          }
          _recomputeSelections();
        }
      }
    });
    if (_activeSelections.isNotEmpty) {
      HapticFeedback.selectionClick();
    }
  }

  void _onHandlePanUpdate(DragUpdateDetails details) {
    if (_activeHandle == null) {
      return;
    }

    final Offset? fingerScene = _sceneFromGlobal(details.globalPosition);
    if (fingerScene == null) {
      return;
    }

    final Offset targetPoint =
        fingerScene + (_activeHandleTouchOffset ?? Offset.zero);
    final int? blockIndex =
        _hitTestBlock(targetPoint) ?? _nearestBlockIndex(targetPoint);
    if (blockIndex == null) {
      return;
    }

    final _SelectionAnchor anchor = _anchorForPoint(blockIndex, targetPoint);
    setState(() {
      if (_activeHandle == _HandleType.base) {
        _baseAnchor = anchor;
      } else {
        _extentAnchor = anchor;
      }
      _recomputeSelections();
    });
  }

  void _onHandlePanEnd() {
    if (_activeHandle == null) {
      return;
    }

    setState(() {
      _isSelecting = false;
      _activeHandle = null;
      _activeHandleTouchOffset = null;
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

  void _onHandlePanCancel() {
    if (_activeHandle == null) {
      return;
    }

    setState(() {
      _isSelecting = false;
      _activeHandle = null;
      _activeHandleTouchOffset = null;
      if (_activeSelections.isEmpty) {
        _selectedTextPreview = '';
      }
    });

    if (_activeSelections.isNotEmpty) {
      _notifySelection();
    } else {
      _baseAnchor = null;
      _extentAnchor = null;
    }
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
              borderRadius: BorderRadius.circular(18),
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

  void _onPanStart(DragStartDetails details) {
    final scenePoint = _sceneFromViewport(details.localPosition);
    if (scenePoint == null) {
      return;
    }

    final blockIndex = _hitTestBlock(scenePoint);
    if (blockIndex == null) {
      if (_activeSelections.isNotEmpty) {
        _clearSelection();
      }
      return;
    }

    final anchor = _anchorForPoint(blockIndex, scenePoint);
    widget.onSelectionStart?.call();
    setState(() {
      _isSelecting = true;
      _baseAnchor = anchor;
      _extentAnchor = anchor;
      _recomputeSelections();
    });
    if (_activeSelections.isNotEmpty) {
      HapticFeedback.selectionClick();
    }
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (!_isSelecting) {
      return;
    }

    final scenePoint = _sceneFromViewport(details.localPosition);
    if (scenePoint == null) {
      return;
    }

    final blockIndex =
        _hitTestBlock(scenePoint) ?? _nearestBlockIndex(scenePoint);
    if (blockIndex == null) {
      return;
    }

    final anchor = _anchorForPoint(blockIndex, scenePoint);
    setState(() {
      _extentAnchor = anchor;
      _recomputeSelections();
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

  void _onPanCancel() {
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
      _notifySelection();
    } else {
      _baseAnchor = null;
      _extentAnchor = null;
    }
  }

  void _onLongPressStart(LongPressStartDetails details) {
    final scenePoint = _sceneFromGlobal(details.globalPosition);
    if (scenePoint == null) {
      return;
    }

    final blockIndex = _hitTestBlock(scenePoint);
    if (blockIndex == null) {
      return;
    }

    final anchor = _anchorForPoint(blockIndex, scenePoint);
    widget.onSelectionStart?.call();
    setState(() {
      _isSelecting = true;
      _baseAnchor = anchor;
      _extentAnchor = anchor;
      _recomputeSelections();
    });
    HapticFeedback.mediumImpact();
  }

  void _handleTapDown(TapDownDetails details) {
    final scenePoint = _sceneFromGlobal(details.globalPosition);
    if (scenePoint == null) {
      return;
    }

    if (_activeSelections.isNotEmpty && _isScenePointOnHandle(scenePoint)) {
      return;
    }

    if (_hitTestBlock(scenePoint) == null && _activeSelections.isNotEmpty) {
      _clearSelection();
    }
  }

  void _handleDoubleTapDown(TapDownDetails details) {
    _pendingDoubleTapScenePoint = _sceneFromGlobal(details.globalPosition);
  }

  void _handleDoubleTap() {
    final Offset? point = _pendingDoubleTapScenePoint;
    _pendingDoubleTapScenePoint = null;
    if (point == null) {
      return;
    }

    final int? blockIndex = _hitTestBlock(point);
    if (blockIndex == null) {
      if (_activeSelections.isNotEmpty) {
        _clearSelection();
      }
      return;
    }

    _performWordSelection(blockIndex, point);
  }

  void _performWordSelection(int blockIndex, Offset scenePoint) {
    final _BlockVisual? visual = _blockVisuals[blockIndex];
    if (visual == null || visual.characterCount == 0) {
      return;
    }

    final _SelectionAnchor anchor = _anchorForPoint(blockIndex, scenePoint);
    int characterIndex = anchor.position.offset;
    if (characterIndex >= visual.characterCount) {
      characterIndex = visual.characterCount - 1;
    }
    if (characterIndex < 0) {
      characterIndex = 0;
    }

    final TextRange? range = _wordBoundaryAt(visual, characterIndex);
    if (range == null || range.isCollapsed) {
      return;
    }

    widget.onSelectionStart?.call();
    setState(() {
      _baseAnchor = _SelectionAnchor(
        blockIndex,
        TextPosition(offset: range.start),
      );
      _extentAnchor = _SelectionAnchor(
        blockIndex,
        TextPosition(offset: range.end),
      );
      _isSelecting = false;
      _recomputeSelections();
    });
    if (_activeSelections.isNotEmpty) {
      HapticFeedback.selectionClick();
      _notifySelection();
    }
  }

  TextRange? _wordBoundaryAt(_BlockVisual visual, int index) {
    final String text = visual.block.text;
    final int charCount = visual.characterCount;
    if (text.isEmpty || charCount == 0) {
      return null;
    }

    final int maxIndex = min(text.length - 1, charCount - 1);
    if (maxIndex < 0) {
      return null;
    }

    final int clampedIndex = _clampIndex(index, 0, maxIndex);
    final _GlyphCategory category = _glyphCategory(text[clampedIndex]);
    if (category == _GlyphCategory.whitespace) {
      return null;
    }

    int start = clampedIndex;
    while (start > 0 && _glyphCategory(text[start - 1]) == category) {
      start -= 1;
    }

    int end = clampedIndex + 1;
    while (end < text.length &&
        end < charCount &&
        _glyphCategory(text[end]) == category) {
      end += 1;
    }

    start = _clampIndex(start, 0, charCount);
    end = _clampIndex(end, 0, charCount);

    if (start == end) {
      if (end < charCount) {
        end = _clampIndex(end + 1, 0, charCount);
      } else if (start > 0) {
        start = _clampIndex(start - 1, 0, charCount);
      }
    }

    if (start >= end) {
      return null;
    }

    return TextRange(start: start, end: end);
  }

  _GlyphCategory _glyphCategory(String character) {
    if (character.trim().isEmpty) {
      return _GlyphCategory.whitespace;
    }
    if (_wordCharacterPattern.hasMatch(character)) {
      return _GlyphCategory.word;
    }
    return _GlyphCategory.symbol;
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

    final localPoint = globalPoint - bounds.topLeft;

    for (int i = 0; i < visual.characters.length; i++) {
      final character = visual.characters[i];
      final rect = character.bounds;
      if (!rect.isEmpty) {
        final paddedRect = rect.inflate(_characterHitPadding);
        if (paddedRect.contains(localPoint)) {
          return _SelectionAnchor(blockIndex, TextPosition(offset: i));
        }
      }
      if (character.polygon.length >= 3 &&
          _pointInPolygon(character.polygon, localPoint)) {
        return _SelectionAnchor(blockIndex, TextPosition(offset: i));
      }
    }

    int? bestIndex;
    double bestDistance = double.infinity;
    for (int i = 0; i < visual.characters.length; i++) {
      final rect = visual.characters[i].bounds;
      if (rect.isEmpty) {
        continue;
      }
      final paddedRect = rect.inflate(_characterHitPadding);
      final dx = _distanceToRange(
        localPoint.dx,
        paddedRect.left,
        paddedRect.right,
      );
      final dy = _distanceToRange(
        localPoint.dy,
        paddedRect.top,
        paddedRect.bottom,
      );
      final distance = sqrt(dx * dx + dy * dy);
      if (distance < bestDistance) {
        bestDistance = distance;
        bestIndex = i;
      }
    }

    final fallbackIndex = bestIndex ?? 0;
    return _SelectionAnchor(blockIndex, TextPosition(offset: fallbackIndex));
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

  void _recomputeSelections() {
    _clampAnchorsToVisuals();
    _normalizeAnchors();
    _activeSelections = _computeSelections(_baseAnchor, _extentAnchor);
    _updateSelectionPreview();
  }

  void _normalizeAnchors() {
    if (_baseAnchor == null || _extentAnchor == null) {
      return;
    }

    final int baseOrder = _blockOrder.indexOf(_baseAnchor!.blockIndex);
    final int extentOrder = _blockOrder.indexOf(_extentAnchor!.blockIndex);
    if (baseOrder == -1 || extentOrder == -1) {
      return;
    }

    final bool shouldSwap =
        baseOrder > extentOrder ||
        (baseOrder == extentOrder &&
            _extentAnchor!.position.offset < _baseAnchor!.position.offset);

    if (shouldSwap) {
      final temp = _baseAnchor;
      _baseAnchor = _extentAnchor;
      _extentAnchor = temp;
    }
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
    _recomputeSelections();
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

  void _clearSelection() {
    setState(() {
      _activeSelections = <int, TextSelection>{};
      _baseAnchor = null;
      _extentAnchor = null;
      _isSelecting = false;
      _selectedTextPreview = '';
      _pendingDoubleTapScenePoint = null;
      _activeHandle = null;
      _activeHandleTouchOffset = null;
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

  void _updateSelectionPreview() {
    if (!widget.enableSelectionPreview) {
      if (_selectedTextPreview.isNotEmpty) {
        _selectedTextPreview = '';
      }
      return;
    }
    _selectedTextPreview = _selectionPreviewText();
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

  bool _isRenderableRect(Rect rect) {
    return !rect.isEmpty && rect.width > _epsilon && rect.height > _epsilon;
  }

  int _clampIndex(int value, int minValue, int maxValue) {
    if (value < minValue) {
      return minValue;
    }
    if (value > maxValue) {
      return maxValue;
    }
    return value;
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
}

class _SelectionAnchor {
  const _SelectionAnchor(this.blockIndex, this.position);

  final int blockIndex;
  final TextPosition position;
}

enum _HandleType { base, extent }

enum _GlyphCategory { whitespace, word, symbol }

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

class _CopyActionButton extends StatelessWidget {
  const _CopyActionButton({
    required this.onPressed,
    required this.accentColor,
    required this.width,
    required this.height,
    required this.anchorAboveSelection,
    required this.pointerHeight,
  });

  final VoidCallback onPressed;
  final Color accentColor;
  final double width;
  final double height;
  final bool anchorAboveSelection;
  final double pointerHeight;

  @override
  Widget build(BuildContext context) {
    final Widget body = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onPressed,
        child: Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: const Color(0xFF1F2937),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: accentColor.withValues(alpha: 0.24),
              width: 1.0,
            ),
            boxShadow: const [
              BoxShadow(
                color: Colors.black12,
                blurRadius: 6,
                offset: Offset(0, 3),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(CupertinoIcons.doc_on_doc, size: 15, color: Colors.white),
              const SizedBox(width: 4),
              const Text(
                'Copy',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (pointerHeight <= 0) {
      return Semantics(
        button: true,
        label: 'Copy selected text',
        child: SizedBox(width: width, height: height, child: body),
      );
    }

    final Widget pointer = SizedBox(
      width: 20,
      height: pointerHeight,
      child: CustomPaint(
        painter: _CopyPointerPainter(
          color: const Color(0xFF1F2937),
          borderColor: accentColor.withValues(alpha: 0.24),
          pointingDown: anchorAboveSelection,
        ),
      ),
    );

    final List<Widget> children = anchorAboveSelection
        ? <Widget>[body, Align(alignment: Alignment.center, child: pointer)]
        : <Widget>[Align(alignment: Alignment.center, child: pointer), body];

    return Semantics(
      button: true,
      label: 'Copy selected text',
      child: SizedBox(
        width: width,
        height: height + pointerHeight,
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

class _CopyPointerPainter extends CustomPainter {
  const _CopyPointerPainter({
    required this.color,
    required this.borderColor,
    required this.pointingDown,
  });

  final Color color;
  final Color borderColor;
  final bool pointingDown;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) {
      return;
    }

    final Path path = Path();
    if (pointingDown) {
      path.moveTo(0, 0);
      path.lineTo(size.width / 2, size.height);
      path.lineTo(size.width, 0);
    } else {
      path.moveTo(0, size.height);
      path.lineTo(size.width / 2, 0);
      path.lineTo(size.width, size.height);
    }
    path.close();

    final Paint fillPaint = Paint()..color = color;
    canvas.drawPath(path, fillPaint);

    final Paint borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawPath(path, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _CopyPointerPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.borderColor != borderColor ||
        oldDelegate.pointingDown != pointingDown;
  }
}

class _SelectionHandleVisual extends StatelessWidget {
  const _SelectionHandleVisual({
    required this.fillColor,
    required this.borderColor,
    required this.isStart,
    required this.headDiameter,
    required this.pointerHeight,
    required this.pointerWidth,
  });

  final Color fillColor;
  final Color borderColor;
  final bool isStart;
  final double headDiameter;
  final double pointerHeight;
  final double pointerWidth;

  @override
  Widget build(BuildContext context) {
    final double visualWidth = max(headDiameter, pointerWidth);
    final double visualHeight = headDiameter + pointerHeight;

    return SizedBox(
      width: visualWidth,
      height: visualHeight,
      child: CustomPaint(
        painter: _SelectionHandlePainter(
          fillColor: fillColor,
          borderColor: borderColor,
          isStart: isStart,
          headDiameter: headDiameter,
          pointerHeight: pointerHeight,
          pointerWidth: pointerWidth,
        ),
      ),
    );
  }
}

class _SelectionHandlePainter extends CustomPainter {
  const _SelectionHandlePainter({
    required this.fillColor,
    required this.borderColor,
    required this.isStart,
    required this.headDiameter,
    required this.pointerHeight,
    required this.pointerWidth,
  });

  final Color fillColor;
  final Color borderColor;
  final bool isStart;
  final double headDiameter;
  final double pointerHeight;
  final double pointerWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final double radius = headDiameter / 2;
    final double usableRadius = radius <= 0.1 ? 0.1 : radius;
    final double extent = pointerHeight < 0 ? 0 : pointerHeight;

    double pointerHalfWidth = pointerWidth <= 0
        ? usableRadius * 0.6
        : pointerWidth / 2;
    final double minHalfWidth = usableRadius * 0.5;
    final double maxHalfWidth = usableRadius * 0.95;
    pointerHalfWidth = pointerHalfWidth.clamp(minHalfWidth, maxHalfWidth);

    final double angleOffset = pointerHalfWidth >= usableRadius
        ? pi / 2 - 0.01
        : asin(pointerHalfWidth / usableRadius);

    final double centerY = isStart ? usableRadius : size.height - usableRadius;
    final Offset circleCenter = Offset(size.width / 2, centerY);

    final double baseAngle = isStart ? pi / 2 : 3 * pi / 2;
    final Offset baseA = Offset(
      circleCenter.dx + usableRadius * cos(baseAngle - angleOffset),
      circleCenter.dy + usableRadius * sin(baseAngle - angleOffset),
    );
    final Offset baseB = Offset(
      circleCenter.dx + usableRadius * cos(baseAngle + angleOffset),
      circleCenter.dy + usableRadius * sin(baseAngle + angleOffset),
    );

    final List<Offset> basePoints = <Offset>[baseA, baseB]
      ..sort((a, b) => a.dx.compareTo(b.dx));
    final Offset leftBase = basePoints.first;
    final Offset rightBase = basePoints.last;

    final Offset pointerTip = isStart
        ? Offset(circleCenter.dx, circleCenter.dy + usableRadius + extent)
        : Offset(circleCenter.dx, circleCenter.dy - usableRadius - extent);

    final Path circlePath = Path()
      ..addOval(Rect.fromCircle(center: circleCenter, radius: usableRadius));
    final double pointerDirection = isStart ? 1.0 : -1.0;
    final double controlYOffset = usableRadius + extent * 0.45;
    final Offset controlPoint = Offset(
      circleCenter.dx,
      circleCenter.dy + pointerDirection * controlYOffset,
    );

    final Path pointerPath = Path()
      ..moveTo(leftBase.dx, leftBase.dy)
      ..quadraticBezierTo(
        controlPoint.dx,
        controlPoint.dy,
        pointerTip.dx,
        pointerTip.dy,
      )
      ..quadraticBezierTo(
        controlPoint.dx,
        controlPoint.dy,
        rightBase.dx,
        rightBase.dy,
      )
      ..close();
    final Path handlePath = Path.combine(
      PathOperation.union,
      circlePath,
      pointerPath,
    );

    final Paint fillPaint = Paint()..color = fillColor;
    canvas.drawPath(handlePath, fillPaint);
  }

  @override
  bool shouldRepaint(covariant _SelectionHandlePainter oldDelegate) {
    return oldDelegate.fillColor != fillColor ||
        oldDelegate.borderColor != borderColor ||
        oldDelegate.isStart != isStart ||
        oldDelegate.headDiameter != headDiameter ||
        oldDelegate.pointerHeight != pointerHeight ||
        oldDelegate.pointerWidth != pointerWidth;
  }
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
          ..color = CupertinoColors.activeBlue.withValues(alpha: 0.32);
        final selected = <_CharacterVisual>[];
        for (int index = start; index < end; index++) {
          if (index >= visual.characters.length) break;
          final character = visual.characters[index];
          if (character.bounds.isEmpty) {
            continue;
          }
          selected.add(character);
        }
        for (final rrect in _buildHighlightRegions(selected)) {
          canvas.drawRRect(rrect, highlightPaint);
        }
      }
    }
  }

  List<RRect> _buildHighlightRegions(List<_CharacterVisual> characters) {
    if (characters.isEmpty) {
      return const [];
    }

    final mergedRects = <Rect>[];
    Rect? current;

    for (final character in characters) {
      final rect = _inflateRect(character.bounds);
      if (rect.isEmpty) {
        continue;
      }
      if (current == null) {
        current = rect;
        continue;
      }

      if (_isSameLine(current, rect)) {
        current = _mergeRects(current, rect);
      } else {
        mergedRects.add(current);
        current = rect;
      }
    }

    if (current != null) {
      mergedRects.add(current);
    }

    return mergedRects
        .map(
          (rect) => RRect.fromRectAndRadius(
            rect,
            Radius.circular(_kHighlightCornerRadius),
          ),
        )
        .toList(growable: false);
  }

  Rect _inflateRect(Rect rect) {
    return Rect.fromLTRB(
      rect.left - _kHighlightHorizontalPadding,
      rect.top - _kHighlightVerticalPadding,
      rect.right + _kHighlightHorizontalPadding,
      rect.bottom + _kHighlightVerticalPadding,
    );
  }

  Rect _mergeRects(Rect a, Rect b) {
    return Rect.fromLTRB(
      min(a.left, b.left),
      min(a.top, b.top),
      max(a.right, b.right),
      max(a.bottom, b.bottom),
    );
  }

  bool _isSameLine(Rect a, Rect b) {
    final double verticalDiff = (a.center.dy - b.center.dy).abs();
    final double maxHeight = max(a.height, b.height);
    final double effectiveHeight = max(maxHeight, 1.0);
    return verticalDiff <= effectiveHeight * _kHighlightLineToleranceFactor;
  }

  @override
  bool shouldRepaint(covariant _EditableBlockPainter oldDelegate) {
    return oldDelegate.visual != visual ||
        oldDelegate.selection != selection ||
        oldDelegate.showBoundary != showBoundary;
  }
}
