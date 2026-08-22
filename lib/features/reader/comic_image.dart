import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:venera_next/features/reader/gesture.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/global_state.dart';
import 'package:venera_next/foundation/translations.dart';

class ComicImage extends StatefulWidget {
  /// Modified from flutter Image
  ComicImage({
    required ImageProvider image,
    super.key,
    double scale = 1.0,
    this.semanticLabel,
    this.excludeFromSemantics = false,
    this.width,
    this.height,
    this.color,
    this.opacity,
    this.colorBlendMode,
    this.fit,
    this.alignment = Alignment.center,
    this.repeat = ImageRepeat.noRepeat,
    this.centerSlice,
    this.matchTextDirection = false,
    this.gaplessPlayback = false,
    this.filterQuality = FilterQuality.medium,
    this.isAntiAlias = false,
    this.splitWideImage = false,
    this.splitWideImageInvert = false,
    this.cropWhitespace = false,
    this.fillViewport,
    Map<String, String>? headers,
    int? cacheWidth,
    int? cacheHeight,
    this.onInit,
    this.onDispose,
  }) : image = ResizeImage.resizeIfNeeded(cacheWidth, cacheHeight, image),
       assert(cacheWidth == null || cacheWidth > 0),
       assert(cacheHeight == null || cacheHeight > 0);

  final ImageProvider image;

  final String? semanticLabel;

  final bool excludeFromSemantics;

  final double? width;

  final double? height;

  final bool gaplessPlayback;

  final bool matchTextDirection;

  final Rect? centerSlice;

  final ImageRepeat repeat;

  final AlignmentGeometry alignment;

  final BoxFit? fit;

  final BlendMode? colorBlendMode;

  final FilterQuality filterQuality;

  final Animation<double>? opacity;

  final Color? color;

  final bool isAntiAlias;

  final bool splitWideImage;

  final bool splitWideImageInvert;

  /// Detects blank margins at the top/bottom of the decoded image and trims
  /// them, and shrinks (without fully removing) oversized blank gaps found
  /// in the middle, so consecutive images in continuous scroll modes pack
  /// more tightly.
  final bool cropWhitespace;

  /// When set, ignores [width]/[height]/[fit]/[cropWhitespace]/
  /// [splitWideImage] and instead scales+crops the image to exactly fill
  /// this size with no letterboxing (a `BoxFit.cover`-style fit), biased to
  /// crop into blank margins before real content. Meant for single-page
  /// gallery mode, where the goal is "no black bars" rather than "show the
  /// whole page".
  final Size? fillViewport;

  final void Function(State<ComicImage> state)? onInit;

  final void Function(State<ComicImage> state)? onDispose;

  static void clear() => ComicImageState.clear();

  @override
  State<ComicImage> createState() => ComicImageState();
}

@visibleForTesting
bool shouldSplitWideImage(Size imageSize) => imageSize.width > imageSize.height;

@visibleForTesting
Size splitWideImageDisplaySize(Size imageSize) {
  if (!shouldSplitWideImage(imageSize)) {
    return imageSize;
  }
  return Size(imageSize.width / 2, imageSize.height * 2);
}

@visibleForTesting
List<Rect> splitWideImageSourceRects(Size imageSize, {required bool invert}) {
  final halfWidth = imageSize.width / 2;
  final left = Rect.fromLTWH(0, 0, halfWidth, imageSize.height);
  final right = Rect.fromLTWH(
    imageSize.width - halfWidth,
    0,
    halfWidth,
    imageSize.height,
  );
  return invert ? [left, right] : [right, left];
}

/// A row is considered blank when every sampled pixel's luma stays within
/// this distance of the row's first sampled pixel, i.e. the row is close to
/// a single flat color (typically the white/black margin around scanned
/// pages, or a blank gap between panels).
const _kWhitespaceRowLumaTolerance = 12;

bool _isRowBlank(ByteData pixels, int width, int row, int sampleStep) {
  final rowStart = row * width * 4;
  int? referenceLuma;
  for (var col = 0; col < width; col += sampleStep) {
    final offset = rowStart + col * 4;
    final luma =
        (pixels.getUint8(offset) * 299 +
            pixels.getUint8(offset + 1) * 587 +
            pixels.getUint8(offset + 2) * 114) ~/
        1000;
    referenceLuma ??= luma;
    if ((luma - referenceLuma).abs() > _kWhitespaceRowLumaTolerance) {
      return false;
    }
  }
  return true;
}

/// Caps how much can be trimmed from a run of blank rows touching the top or
/// bottom edge, so a genuinely blank full-page image (e.g. a section break)
/// can't collapse to near nothing. Expressed relative to the whole image
/// height so it scales with resolution.
const _kMaxEdgeTrimRatio = 0.4;

/// Caps how tall a blank run in the *middle* of the image is allowed to
/// remain: unlike edge margins (which get removed almost entirely), a big
/// gap between panels is only shrunk down to this size, never to zero, since
/// some separation may be intentional. Relative to image width, which is a
/// more stable proxy for the page's resolution/DPI than an absolute pixel
/// count.
const _kMaxInternalGapRatio = 0.06;

/// Floor for [_kMaxInternalGapRatio] so low-resolution images still keep a
/// sane-looking gap instead of one shrunk to a few pixels.
const _kMinInternalGapPx = 24;

/// One vertical slice of the source image to draw. [displayHeight] equals
/// [sourceHeight] for real content and small gaps (drawn 1:1); it is smaller
/// for oversized blank runs, which get shrunk instead of distorting art.
@immutable
@visibleForTesting
class ImageContentSegment {
  const ImageContentSegment({
    required this.sourceTop,
    required this.sourceHeight,
    required this.displayHeight,
  });

  final int sourceTop;

  final int sourceHeight;

  final double displayHeight;

  @override
  bool operator ==(Object other) =>
      other is ImageContentSegment &&
      other.sourceTop == sourceTop &&
      other.sourceHeight == sourceHeight &&
      other.displayHeight == displayHeight;

  @override
  int get hashCode => Object.hash(sourceTop, sourceHeight, displayHeight);

  @override
  String toString() =>
      'ImageContentSegment(sourceTop: $sourceTop, sourceHeight: '
      '$sourceHeight, displayHeight: $displayHeight)';
}

/// Splits decoded RGBA [pixels] into vertical segments to draw, trimming
/// blank margins at the top/bottom and shrinking (but not fully removing)
/// oversized blank gaps in the middle. Pure pixel-math, kept separate from
/// [detectWhitespaceSegments] so it can be unit tested without decoding a
/// real [ui.Image].
@visibleForTesting
List<ImageContentSegment> computeWhitespaceSegments(
  ByteData pixels,
  int width,
  int height,
) {
  if (width <= 0 || height <= 0) return const [];

  final sampleStep = math.max(1, width ~/ 64);
  bool isBlankRow(int row) =>
      _isRowBlank(pixels, width, row, sampleStep);

  // Group rows into alternating blank/content runs.
  final runs = <({int start, int length, bool isBlank})>[];
  var runStart = 0;
  var runIsBlank = isBlankRow(0);
  for (var row = 1; row < height; row++) {
    final rowIsBlank = isBlankRow(row);
    if (rowIsBlank != runIsBlank) {
      runs.add((start: runStart, length: row - runStart, isBlank: runIsBlank));
      runStart = row;
      runIsBlank = rowIsBlank;
    }
  }
  runs.add((start: runStart, length: height - runStart, isBlank: runIsBlank));

  final maxEdgeTrim = (height * _kMaxEdgeTrimRatio).floor();
  final maxInternalGap = math.max(
    _kMinInternalGapPx,
    (width * _kMaxInternalGapRatio).round(),
  );

  final segments = <ImageContentSegment>[];
  for (final run in runs) {
    if (!run.isBlank) {
      segments.add(
        ImageContentSegment(
          sourceTop: run.start,
          sourceHeight: run.length,
          displayHeight: run.length.toDouble(),
        ),
      );
      continue;
    }

    final touchesTop = run.start == 0;
    final touchesBottom = run.start + run.length == height;
    double displayHeight;
    if (touchesTop || touchesBottom) {
      var trimmed = 0;
      if (touchesTop) trimmed += maxEdgeTrim;
      if (touchesBottom) trimmed += maxEdgeTrim;
      displayHeight = math.max(0, run.length - trimmed).toDouble();
    } else {
      displayHeight = math.min(run.length, maxInternalGap).toDouble();
    }
    if (displayHeight > 0) {
      segments.add(
        ImageContentSegment(
          sourceTop: run.start,
          sourceHeight: run.length,
          displayHeight: displayHeight,
        ),
      );
    }
  }
  return segments;
}

/// Decodes [image]'s pixels off the widget tree to compute its content
/// segments. Runs once per image; callers should cache the result.
Future<List<ImageContentSegment>> detectWhitespaceSegments(
  ui.Image image,
) async {
  final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (pixels == null) return const [];
  return computeWhitespaceSegments(pixels, image.width, image.height);
}

double _totalDisplayHeight(List<ImageContentSegment> segments) {
  var total = 0.0;
  for (final segment in segments) {
    total += segment.displayHeight;
  }
  return total;
}

/// Finds the (uncapped) blank margin at the very top and bottom edge of the
/// image, i.e. how many rows are available to crop into before touching
/// real content. Unlike [computeWhitespaceSegments], this isn't capped: it's
/// used as a crop *budget*, not a display trim.
@visibleForTesting
({int top, int bottom}) computeEdgeMargins(
  ByteData pixels,
  int width,
  int height,
) {
  if (width <= 0 || height <= 0) return (top: 0, bottom: 0);

  final sampleStep = math.max(1, width ~/ 64);
  var top = 0;
  while (top < height && _isRowBlank(pixels, width, top, sampleStep)) {
    top++;
  }
  var bottom = 0;
  while (bottom < height - top &&
      _isRowBlank(pixels, width, height - 1 - bottom, sampleStep)) {
    bottom++;
  }
  return (top: top, bottom: bottom);
}

/// Decodes [image]'s pixels to find its top/bottom crop budget. Runs once
/// per image; callers should cache the result.
Future<({int top, int bottom})> detectEdgeMargins(ui.Image image) async {
  final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (pixels == null) return (top: 0, bottom: 0);
  return computeEdgeMargins(pixels, image.width, image.height);
}

/// Computes the source-image rect to draw (stretched to exactly fill
/// [viewportSize], i.e. a `BoxFit.cover`-style crop with no letterboxing),
/// biased so the crop eats into [topMargin]/[bottomMargin] blank rows before
/// it ever cuts into real content. If the image doesn't have enough blank
/// margin to absorb the required crop, the remaining amount is split evenly
/// between top and bottom so the crop stays as centered as possible rather
/// than favoring one edge.
///
/// Horizontal overflow (rare for the tall/narrow pages this targets) has no
/// equivalent "safe" signal to lean on, so it's always split evenly.
@visibleForTesting
Rect computeCoverCropRect({
  required Size imageSize,
  required Size viewportSize,
  required int topMargin,
  required int bottomMargin,
}) {
  if (imageSize.width <= 0 ||
      imageSize.height <= 0 ||
      viewportSize.width <= 0 ||
      viewportSize.height <= 0) {
    return Offset.zero & imageSize;
  }

  final scale = math.max(
    viewportSize.width / imageSize.width,
    viewportSize.height / imageSize.height,
  );
  final visibleWidth = math.min(imageSize.width, viewportSize.width / scale);
  final visibleHeight = math.min(
    imageSize.height,
    viewportSize.height / scale,
  );

  final overflowWidth = imageSize.width - visibleWidth;
  final overflowHeight = imageSize.height - visibleHeight;

  final left = overflowWidth / 2;

  double top;
  if (overflowHeight <= 0) {
    top = 0;
  } else {
    final topBudget = math.min(topMargin.toDouble(), overflowHeight);
    final remainingAfterTop = overflowHeight - topBudget;
    final bottomBudget = math.min(bottomMargin.toDouble(), remainingAfterTop);
    final remainder = remainingAfterTop - bottomBudget;
    top = topBudget + remainder / 2;
  }

  return Rect.fromLTWH(left, top, visibleWidth, visibleHeight);
}

class ComicImageState extends State<ComicImage> with WidgetsBindingObserver {
  ImageStream? _imageStream;
  ImageInfo? _imageInfo;
  ImageChunkEvent? _loadingProgress;
  bool _isListeningToStream = false;
  late bool _invertColors;
  int? _frameNumber;
  bool _wasSynchronouslyLoaded = false;
  late DisposableBuildContext<State<ComicImage>> _scrollAwareContext;
  Object? _lastException;
  ImageStreamCompleterHandle? _completerHandle;

  static final Map<int, Size> _cache = {};

  static final Map<int, List<ImageContentSegment>> _whitespaceSegmentCache =
      {};

  static final Set<int> _whitespaceSegmentPending = {};

  static final Map<int, ({int top, int bottom})> _edgeMarginCache = {};

  static final Set<int> _edgeMarginPending = {};

  static clear() {
    _cache.clear();
    _whitespaceSegmentCache.clear();
    _whitespaceSegmentPending.clear();
    _edgeMarginCache.clear();
    _edgeMarginPending.clear();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollAwareContext = DisposableBuildContext<State<ComicImage>>(this);
    widget.onInit?.call(this);
  }

  @override
  void dispose() {
    assert(_imageStream != null);
    WidgetsBinding.instance.removeObserver(this);
    _stopListeningToStream();
    _completerHandle?.dispose();
    _scrollAwareContext.dispose();
    _replaceImage(info: null);
    widget.onDispose?.call(this);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    _updateInvertColors();
    _resolveImage();

    if (TickerMode.valuesOf(context).enabled) {
      _listenToStream();
    } else {
      _stopListeningToStream(keepStreamAlive: true);
    }

    super.didChangeDependencies();
  }

  @override
  void didUpdateWidget(ComicImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.image != oldWidget.image) {
      _resolveImage();
    }
  }

  @override
  void didChangeAccessibilityFeatures() {
    super.didChangeAccessibilityFeatures();
    setState(() {
      _updateInvertColors();
    });
  }

  @override
  void reassemble() {
    _resolveImage(); // in case the image cache was flushed
    super.reassemble();
  }

  bool containsPoint(Offset point) {
    if (!mounted) {
      return false;
    }
    var renderBox = context.findRenderObject() as RenderBox;
    var localPoint = renderBox.globalToLocal(point);
    return renderBox.paintBounds.contains(localPoint);
  }

  void _updateInvertColors() {
    _invertColors =
        MediaQuery.maybeInvertColorsOf(context) ??
        SemanticsBinding.instance.accessibilityFeatures.invertColors;
  }

  void _resolveImage() {
    final ScrollAwareImageProvider provider = ScrollAwareImageProvider<Object>(
      context: _scrollAwareContext,
      imageProvider: widget.image,
    );
    final ImageStream newStream = provider.resolve(
      createLocalImageConfiguration(
        context,
        size: widget.width != null && widget.height != null
            ? Size(widget.width!, widget.height!)
            : null,
      ),
    );
    _updateSourceStream(newStream);
  }

  ImageStreamListener? _imageStreamListener;

  ImageStreamListener _getListener({bool recreateListener = false}) {
    if (_imageStreamListener == null || recreateListener) {
      _lastException = null;
      _imageStreamListener = ImageStreamListener(
        _handleImageFrame,
        onChunk: _handleImageChunk,
        onError: (Object error, StackTrace? stackTrace) {
          setState(() {
            _lastException = error;
          });
        },
      );
    }
    return _imageStreamListener!;
  }

  void _handleImageFrame(ImageInfo imageInfo, bool synchronousCall) {
    setState(() {
      _replaceImage(info: imageInfo);
      _loadingProgress = null;
      _lastException = null;
      _frameNumber = _frameNumber == null ? 0 : _frameNumber! + 1;
      _wasSynchronouslyLoaded = _wasSynchronouslyLoaded | synchronousCall;
    });
    _maybeDetectWhitespaceSegments(imageInfo.image);
    _maybeDetectEdgeMargins(imageInfo.image);
  }

  void _maybeDetectWhitespaceSegments(ui.Image image) {
    if (!widget.cropWhitespace) return;
    final key = widget.image.hashCode;
    if (_whitespaceSegmentCache.containsKey(key) ||
        _whitespaceSegmentPending.contains(key)) {
      return;
    }
    _whitespaceSegmentPending.add(key);
    detectWhitespaceSegments(image).then((segments) {
      _whitespaceSegmentPending.remove(key);
      _whitespaceSegmentCache[key] = segments;
      if (mounted) setState(() {});
    });
  }

  bool _shouldBuildTrimmedImage() {
    if (!widget.cropWhitespace || _imageInfo == null) return false;
    final segments = _whitespaceSegmentCache[widget.image.hashCode];
    if (segments == null) return false;
    return _totalDisplayHeight(segments) < _imageInfo!.image.height;
  }

  void _maybeDetectEdgeMargins(ui.Image image) {
    if (widget.fillViewport == null) return;
    final key = widget.image.hashCode;
    if (_edgeMarginCache.containsKey(key) || _edgeMarginPending.contains(key)) {
      return;
    }
    _edgeMarginPending.add(key);
    detectEdgeMargins(image).then((margins) {
      _edgeMarginPending.remove(key);
      _edgeMarginCache[key] = margins;
      if (mounted) setState(() {});
    });
  }

  void _handleImageChunk(ImageChunkEvent event) {
    setState(() {
      _loadingProgress = event;
      _lastException = null;
    });
  }

  void _replaceImage({required ImageInfo? info}) {
    final ImageInfo? oldImageInfo = _imageInfo;
    SchedulerBinding.instance.addPostFrameCallback(
      (_) => oldImageInfo?.dispose(),
    );
    _imageInfo = info;
  }

  // Updates _imageStream to newStream, and moves the stream listener
  // registration from the old stream to the new stream (if a listener was
  // registered).
  void _updateSourceStream(ImageStream newStream) {
    if (_imageStream?.key == newStream.key) {
      return;
    }

    if (_isListeningToStream) {
      _imageStream!.removeListener(_getListener());
    }

    if (!widget.gaplessPlayback) {
      setState(() {
        _replaceImage(info: null);
      });
    }

    setState(() {
      _loadingProgress = null;
      _frameNumber = null;
      _wasSynchronouslyLoaded = false;
    });

    _imageStream = newStream;
    if (_isListeningToStream) {
      _imageStream!.addListener(_getListener());
    }
  }

  void _listenToStream() {
    if (_isListeningToStream) {
      return;
    }

    _imageStream!.addListener(_getListener());
    _completerHandle?.dispose();
    _completerHandle = null;

    _isListeningToStream = true;
  }

  /// Stops listening to the image stream, if this state object has attached a
  /// listener.
  ///
  /// If the listener from this state is the last listener on the stream, the
  /// stream will be disposed. To keep the stream alive, set `keepStreamAlive`
  /// to true, which create [ImageStreamCompleterHandle] to keep the completer
  /// alive and is compatible with the [TickerMode] being off.
  void _stopListeningToStream({bool keepStreamAlive = false}) {
    if (!_isListeningToStream) {
      return;
    }

    if (keepStreamAlive &&
        _completerHandle == null &&
        _imageStream?.completer != null) {
      _completerHandle = _imageStream!.completer!.keepAlive();
    }

    _imageStream!.removeListener(_getListener());
    _isListeningToStream = false;
  }

  @override
  Widget build(BuildContext context) {
    if (_lastException != null) {
      // display error and retry button on screen
      return SizedBox(
        height: widget.height == null ? 300 : null,
        width: widget.width == null ? 300 : null,
        child: Center(
          child: SizedBox(
            height: 300,
            child: Column(
              children: [
                Expanded(
                  child: Center(
                    child: Text(_lastException.toString(), maxLines: 3),
                  ),
                ),
                const SizedBox(height: 4),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Listener(
                    onPointerDown: (details) {
                      GlobalState.find<ReaderGestureDetectorState>()
                          .ignoreNextTap();
                      setState(() {
                        _loadingProgress = null;
                        _lastException = null;
                      });
                      _resolveImage();
                    },
                    child: SizedBox(
                      width: 84,
                      height: 36,
                      child: Center(
                        child: Text(
                          "Retry".tl,
                          style: TextStyle(color: Colors.blue),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constrains) {
        var width = widget.width;
        var height = widget.height;

        if (_imageInfo != null) {
          // Record the height and the width of the image
          _cache[widget.image.hashCode] = Size(
            _imageInfo!.image.width.toDouble(),
            _imageInfo!.image.height.toDouble(),
          );
        }

        if (widget.fillViewport != null) {
          width = widget.fillViewport!.width;
          height = widget.fillViewport!.height;
        } else {
          Size? cacheSize = _cache[widget.image.hashCode];
          if (cacheSize != null) {
            final segments = widget.cropWhitespace
                ? _whitespaceSegmentCache[widget.image.hashCode]
                : null;
            final totalDisplayHeight = segments == null
                ? null
                : _totalDisplayHeight(segments);
            // Cropping wins over the dual-page split: both reshape the same
            // display size and combining them isn't a supported combination.
            Size displaySize;
            if (totalDisplayHeight != null &&
                totalDisplayHeight < cacheSize.height) {
              displaySize = Size(cacheSize.width, totalDisplayHeight);
            } else if (widget.splitWideImage) {
              displaySize = splitWideImageDisplaySize(cacheSize);
            } else {
              displaySize = cacheSize;
            }
            if (width == double.infinity) {
              width = constrains.maxWidth;
              height = width * displaySize.height / displaySize.width;
            } else if (height == double.infinity) {
              height = constrains.maxHeight;
              width = height * displaySize.width / displaySize.height;
            }
          } else {
            if (width == double.infinity) {
              width = constrains.maxWidth;
              height = 300;
            } else if (height == double.infinity) {
              height = constrains.maxHeight;
              width = 300;
            }
          }
        }

        if (_imageInfo != null) {
          // build image
          Widget result;
          if (widget.fillViewport != null) {
            final margins =
                _edgeMarginCache[widget.image.hashCode] ??
                (top: 0, bottom: 0);
            result = _CoverImage(
              image: _imageInfo!.image,
              viewportSize: widget.fillViewport!,
              topMargin: margins.top,
              bottomMargin: margins.bottom,
              color: widget.color,
              opacity: widget.opacity,
              colorBlendMode: widget.colorBlendMode,
              invertColors: _invertColors,
              isAntiAlias: widget.isAntiAlias,
              filterQuality: widget.filterQuality,
            );
          } else if (_shouldBuildTrimmedImage()) {
            result = _TrimmedImage(
              image: _imageInfo!.image,
              width: width,
              height: height,
              segments: _whitespaceSegmentCache[widget.image.hashCode]!,
              color: widget.color,
              opacity: widget.opacity,
              colorBlendMode: widget.colorBlendMode,
              fit: widget.fit,
              alignment: widget.alignment,
              matchTextDirection: widget.matchTextDirection,
              invertColors: _invertColors,
              isAntiAlias: widget.isAntiAlias,
              filterQuality: widget.filterQuality,
            );
          } else if (widget.splitWideImage &&
              shouldSplitWideImage(
                Size(
                  _imageInfo!.image.width.toDouble(),
                  _imageInfo!.image.height.toDouble(),
                ),
              )) {
            result = _SplitWideImage(
              image: _imageInfo!.image,
              width: width,
              height: height,
              color: widget.color,
              opacity: widget.opacity,
              colorBlendMode: widget.colorBlendMode,
              fit: widget.fit,
              alignment: widget.alignment,
              matchTextDirection: widget.matchTextDirection,
              invertColors: _invertColors,
              isAntiAlias: widget.isAntiAlias,
              filterQuality: widget.filterQuality,
              splitInvert: widget.splitWideImageInvert,
            );
          } else {
            result = RawImage(
              // Do not clone the image, because RawImage is a stateless wrapper.
              // The image will be disposed by this state object when it is not needed
              // anymore, such as when it is unmounted or when the image stream pushes
              // a new image.
              image: _imageInfo?.image,
              debugImageLabel: _imageInfo?.debugLabel,
              width: width,
              height: height,
              scale: _imageInfo?.scale ?? 1.0,
              color: widget.color,
              opacity: widget.opacity,
              colorBlendMode: widget.colorBlendMode,
              fit: widget.fit,
              alignment: widget.alignment,
              repeat: widget.repeat,
              centerSlice: widget.centerSlice,
              matchTextDirection: widget.matchTextDirection,
              invertColors: _invertColors,
              isAntiAlias: widget.isAntiAlias,
              filterQuality: widget.filterQuality,
            );
          }

          if (!widget.excludeFromSemantics) {
            result = Semantics(
              container: widget.semanticLabel != null,
              image: true,
              label: widget.semanticLabel ?? '',
              child: result,
            );
          }
          result = SizedBox(
            width: width,
            height: height,
            child: Center(child: result),
          );
          return result;
        } else {
          // build progress
          return SizedBox(
            width: width,
            height: height,
            child: Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  backgroundColor: context.colorScheme.surfaceContainer,
                  value:
                      (_loadingProgress != null &&
                          _loadingProgress!.expectedTotalBytes != null &&
                          _loadingProgress!.expectedTotalBytes! != 0)
                      ? _loadingProgress!.cumulativeBytesLoaded /
                            _loadingProgress!.expectedTotalBytes!
                      : 0,
                ),
              ),
            ),
          );
        }
      },
    );
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(DiagnosticsProperty<ImageStream>('stream', _imageStream));
    properties.add(DiagnosticsProperty<ImageInfo>('pixels', _imageInfo));
    properties.add(
      DiagnosticsProperty<ImageChunkEvent>('loadingProgress', _loadingProgress),
    );
    properties.add(DiagnosticsProperty<int>('frameNumber', _frameNumber));
    properties.add(
      DiagnosticsProperty<bool>(
        'wasSynchronouslyLoaded',
        _wasSynchronouslyLoaded,
      ),
    );
  }
}

class _SplitWideImage extends StatelessWidget {
  const _SplitWideImage({
    required this.image,
    required this.width,
    required this.height,
    required this.color,
    required this.opacity,
    required this.colorBlendMode,
    required this.fit,
    required this.alignment,
    required this.matchTextDirection,
    required this.invertColors,
    required this.isAntiAlias,
    required this.filterQuality,
    required this.splitInvert,
  });

  final ui.Image image;

  final double? width;

  final double? height;

  final Color? color;

  final Animation<double>? opacity;

  final BlendMode? colorBlendMode;

  final BoxFit? fit;

  final AlignmentGeometry alignment;

  final bool matchTextDirection;

  final bool invertColors;

  final bool isAntiAlias;

  final FilterQuality filterQuality;

  final bool splitInvert;

  @override
  Widget build(BuildContext context) {
    Widget result = CustomPaint(
      size: Size(
        width ?? image.width.toDouble() / 2,
        height ?? image.height * 2,
      ),
      painter: _SplitWideImagePainter(
        image: image,
        color: color,
        colorBlendMode: colorBlendMode,
        fit: fit,
        alignment: alignment.resolve(Directionality.maybeOf(context)),
        matchTextDirection: matchTextDirection,
        textDirection: Directionality.maybeOf(context),
        invertColors: invertColors,
        isAntiAlias: isAntiAlias,
        filterQuality: filterQuality,
        splitInvert: splitInvert,
      ),
    );
    if (opacity != null) {
      result = FadeTransition(opacity: opacity!, child: result);
    }
    return SizedBox(width: width, height: height, child: result);
  }
}

class _SplitWideImagePainter extends CustomPainter {
  const _SplitWideImagePainter({
    required this.image,
    required this.color,
    required this.colorBlendMode,
    required this.fit,
    required this.alignment,
    required this.matchTextDirection,
    required this.textDirection,
    required this.invertColors,
    required this.isAntiAlias,
    required this.filterQuality,
    required this.splitInvert,
  });

  final ui.Image image;

  final Color? color;

  final BlendMode? colorBlendMode;

  final BoxFit? fit;

  final Alignment alignment;

  final bool matchTextDirection;

  final TextDirection? textDirection;

  final bool invertColors;

  final bool isAntiAlias;

  final FilterQuality filterQuality;

  final bool splitInvert;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final imageSize = Size(image.width.toDouble(), image.height.toDouble());
    final displaySize = splitWideImageDisplaySize(imageSize);
    final fitted = applyBoxFit(fit ?? BoxFit.scaleDown, displaySize, size);
    final destination = alignment.inscribe(
      fitted.destination,
      Offset.zero & size,
    );
    final halfHeight = destination.height / 2;
    final topDestination = Rect.fromLTWH(
      destination.left,
      destination.top,
      destination.width,
      halfHeight,
    );
    final bottomDestination = Rect.fromLTWH(
      destination.left,
      destination.top + halfHeight,
      destination.width,
      halfHeight,
    );
    final sources = splitWideImageSourceRects(
      imageSize,
      invert:
          splitInvert ^
          (matchTextDirection && textDirection == TextDirection.rtl),
    );
    final paint = Paint()
      ..isAntiAlias = isAntiAlias
      ..filterQuality = filterQuality
      ..invertColors = invertColors;
    if (color != null) {
      paint.colorFilter = ColorFilter.mode(
        color!,
        colorBlendMode ?? BlendMode.srcIn,
      );
    }

    canvas.drawImageRect(image, sources[0], topDestination, paint);
    canvas.drawImageRect(image, sources[1], bottomDestination, paint);
  }

  @override
  bool shouldRepaint(covariant _SplitWideImagePainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.color != color ||
        oldDelegate.colorBlendMode != colorBlendMode ||
        oldDelegate.fit != fit ||
        oldDelegate.alignment != alignment ||
        oldDelegate.matchTextDirection != matchTextDirection ||
        oldDelegate.textDirection != textDirection ||
        oldDelegate.invertColors != invertColors ||
        oldDelegate.isAntiAlias != isAntiAlias ||
        oldDelegate.filterQuality != filterQuality ||
        oldDelegate.splitInvert != splitInvert;
  }
}

class _TrimmedImage extends StatelessWidget {
  const _TrimmedImage({
    required this.image,
    required this.width,
    required this.height,
    required this.segments,
    required this.color,
    required this.opacity,
    required this.colorBlendMode,
    required this.fit,
    required this.alignment,
    required this.matchTextDirection,
    required this.invertColors,
    required this.isAntiAlias,
    required this.filterQuality,
  });

  final ui.Image image;

  final double? width;

  final double? height;

  final List<ImageContentSegment> segments;

  final Color? color;

  final Animation<double>? opacity;

  final BlendMode? colorBlendMode;

  final BoxFit? fit;

  final AlignmentGeometry alignment;

  final bool matchTextDirection;

  final bool invertColors;

  final bool isAntiAlias;

  final FilterQuality filterQuality;

  @override
  Widget build(BuildContext context) {
    Widget result = CustomPaint(
      size: Size(
        width ?? image.width.toDouble(),
        height ?? _totalDisplayHeight(segments),
      ),
      painter: _TrimmedImagePainter(
        image: image,
        segments: segments,
        color: color,
        colorBlendMode: colorBlendMode,
        fit: fit,
        alignment: alignment.resolve(Directionality.maybeOf(context)),
        matchTextDirection: matchTextDirection,
        textDirection: Directionality.maybeOf(context),
        invertColors: invertColors,
        isAntiAlias: isAntiAlias,
        filterQuality: filterQuality,
      ),
    );
    if (opacity != null) {
      result = FadeTransition(opacity: opacity!, child: result);
    }
    return SizedBox(width: width, height: height, child: result);
  }
}

class _TrimmedImagePainter extends CustomPainter {
  const _TrimmedImagePainter({
    required this.image,
    required this.segments,
    required this.color,
    required this.colorBlendMode,
    required this.fit,
    required this.alignment,
    required this.matchTextDirection,
    required this.textDirection,
    required this.invertColors,
    required this.isAntiAlias,
    required this.filterQuality,
  });

  final ui.Image image;

  final List<ImageContentSegment> segments;

  final Color? color;

  final BlendMode? colorBlendMode;

  final BoxFit? fit;

  final Alignment alignment;

  final bool matchTextDirection;

  final TextDirection? textDirection;

  final bool invertColors;

  final bool isAntiAlias;

  final FilterQuality filterQuality;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || segments.isEmpty) return;

    final totalDisplayHeight = _totalDisplayHeight(segments);
    if (totalDisplayHeight <= 0) return;

    final displaySize = Size(image.width.toDouble(), totalDisplayHeight);
    final fitted = applyBoxFit(fit ?? BoxFit.scaleDown, displaySize, size);
    final destination = alignment.inscribe(
      fitted.destination,
      Offset.zero & size,
    );
    // Both dimensions of `fitted.destination` are scaled from `displaySize`
    // by the same factor (that's what BoxFit.contain/scaleDown guarantee),
    // so this one scale applies to every segment's height in turn below.
    final scale = destination.width / displaySize.width;

    final paint = Paint()
      ..isAntiAlias = isAntiAlias
      ..filterQuality = filterQuality
      ..invertColors = invertColors;
    if (color != null) {
      paint.colorFilter = ColorFilter.mode(
        color!,
        colorBlendMode ?? BlendMode.srcIn,
      );
    }

    var destTop = destination.top;
    for (final segment in segments) {
      if (segment.displayHeight <= 0) continue;
      final sourceRect = Rect.fromLTWH(
        0,
        segment.sourceTop.toDouble(),
        image.width.toDouble(),
        segment.sourceHeight.toDouble(),
      );
      final destHeight = segment.displayHeight * scale;
      final destRect = Rect.fromLTWH(
        destination.left,
        destTop,
        destination.width,
        destHeight,
      );
      canvas.drawImageRect(image, sourceRect, destRect, paint);
      destTop += destHeight;
    }
  }

  @override
  bool shouldRepaint(covariant _TrimmedImagePainter oldDelegate) {
    return oldDelegate.image != image ||
        !listEquals(oldDelegate.segments, segments) ||
        oldDelegate.color != color ||
        oldDelegate.colorBlendMode != colorBlendMode ||
        oldDelegate.fit != fit ||
        oldDelegate.alignment != alignment ||
        oldDelegate.matchTextDirection != matchTextDirection ||
        oldDelegate.textDirection != textDirection ||
        oldDelegate.invertColors != invertColors ||
        oldDelegate.isAntiAlias != isAntiAlias ||
        oldDelegate.filterQuality != filterQuality;
  }
}

/// Draws [image] scaled+cropped to exactly fill [viewportSize] with no
/// letterboxing, via [computeCoverCropRect].
class _CoverImage extends StatelessWidget {
  const _CoverImage({
    required this.image,
    required this.viewportSize,
    required this.topMargin,
    required this.bottomMargin,
    required this.color,
    required this.opacity,
    required this.colorBlendMode,
    required this.invertColors,
    required this.isAntiAlias,
    required this.filterQuality,
  });

  final ui.Image image;

  final Size viewportSize;

  final int topMargin;

  final int bottomMargin;

  final Color? color;

  final Animation<double>? opacity;

  final BlendMode? colorBlendMode;

  final bool invertColors;

  final bool isAntiAlias;

  final FilterQuality filterQuality;

  @override
  Widget build(BuildContext context) {
    Widget result = CustomPaint(
      size: viewportSize,
      painter: _CoverImagePainter(
        image: image,
        viewportSize: viewportSize,
        topMargin: topMargin,
        bottomMargin: bottomMargin,
        color: color,
        colorBlendMode: colorBlendMode,
        invertColors: invertColors,
        isAntiAlias: isAntiAlias,
        filterQuality: filterQuality,
      ),
    );
    if (opacity != null) {
      result = FadeTransition(opacity: opacity!, child: result);
    }
    return SizedBox(
      width: viewportSize.width,
      height: viewportSize.height,
      child: result,
    );
  }
}

class _CoverImagePainter extends CustomPainter {
  const _CoverImagePainter({
    required this.image,
    required this.viewportSize,
    required this.topMargin,
    required this.bottomMargin,
    required this.color,
    required this.colorBlendMode,
    required this.invertColors,
    required this.isAntiAlias,
    required this.filterQuality,
  });

  final ui.Image image;

  final Size viewportSize;

  final int topMargin;

  final int bottomMargin;

  final Color? color;

  final BlendMode? colorBlendMode;

  final bool invertColors;

  final bool isAntiAlias;

  final FilterQuality filterQuality;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final imageSize = Size(image.width.toDouble(), image.height.toDouble());
    final sourceRect = computeCoverCropRect(
      imageSize: imageSize,
      viewportSize: viewportSize,
      topMargin: topMargin,
      bottomMargin: bottomMargin,
    );

    final paint = Paint()
      ..isAntiAlias = isAntiAlias
      ..filterQuality = filterQuality
      ..invertColors = invertColors;
    if (color != null) {
      paint.colorFilter = ColorFilter.mode(
        color!,
        colorBlendMode ?? BlendMode.srcIn,
      );
    }

    canvas.drawImageRect(image, sourceRect, Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant _CoverImagePainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.viewportSize != viewportSize ||
        oldDelegate.topMargin != topMargin ||
        oldDelegate.bottomMargin != bottomMargin ||
        oldDelegate.color != color ||
        oldDelegate.colorBlendMode != colorBlendMode ||
        oldDelegate.invertColors != invertColors ||
        oldDelegate.isAntiAlias != isAntiAlias ||
        oldDelegate.filterQuality != filterQuality;
  }
}
