import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Default lightness threshold for the night-mode fold. See
/// [nightModeInvertPixel] for what it does.
const kDefaultNightModeThreshold = 0.5;

/// Reference implementation of the night-mode color transform, in plain
/// Dart. It exists so the transform's math can be unit tested: the GPU
/// shader that actually renders it (`shaders/night_mode.frag`) can't be
/// verified without a running app, so this pure function is the one place
/// the algorithm's correctness gets checked. Keep the two in sync.
///
/// Pixels at or below [threshold] lightness pass through unchanged, so
/// artwork that is already dark isn't flipped to bright. Above it,
/// lightness is folded down into `[0, threshold]` — continuous at
/// [threshold], sending pure white to pure black — while hue and
/// saturation are preserved, so a light page background goes dark without
/// colors turning into their complements.
///
/// Note this mapping is deliberately non-monotonic: with a threshold of
/// 0.5, input lightness 0.3 and 0.7 both land on 0.3. That fold is
/// unavoidable for any curve sending both 0 and 1 to black, and it means
/// some mid-tone separation is lost. Raising [threshold] narrows the band
/// of input lightnesses that fold.
@visibleForTesting
(int r, int g, int b) nightModeInvertPixel(
  int r,
  int g,
  int b, {
  double threshold = kDefaultNightModeThreshold,
}) {
  final rf = r / 255.0;
  final gf = g / 255.0;
  final bf = b / 255.0;

  final maxC = math.max(rf, math.max(gf, bf));
  final minC = math.min(rf, math.min(gf, bf));
  final l = (maxC + minC) / 2;
  if (l <= threshold || threshold >= 1.0) {
    return (r, g, b);
  }

  final folded = threshold * (1.0 - l) / (1.0 - threshold);
  // HSL keeps *relative* saturation, so chroma scales by the ratio of the
  // two lightnesses' chroma ceilings. Rescaling each channel around the
  // new lightness by that factor is algebraically identical to a full
  // RGB->HSL->RGB round trip, without computing hue at all.
  final ceiling = 1.0 - (2 * l - 1).abs();
  final k = ceiling == 0 ? 0.0 : (1.0 - (2 * folded - 1).abs()) / ceiling;

  int channel(double c) =>
      ((folded + (c - l) * k) * 255.0).clamp(0.0, 255.0).round();
  return (channel(rf), channel(gf), channel(bf));
}

/// Loads the night-mode fragment program once per process.
///
/// [ready] flips to true when the program is available so widgets can
/// rebuild themselves; without that, the first reader build would render
/// unfiltered and never re-run once the async load finished.
class NightModeShader {
  const NightModeShader._();

  static final ValueNotifier<bool> ready = ValueNotifier<bool>(false);

  static ui.FragmentProgram? _program;
  static bool _loadStarted = false;

  static ui.FragmentProgram? get program => _program;

  static void ensureLoaded() {
    if (_loadStarted) return;
    _loadStarted = true;
    ui.FragmentProgram.fromAsset('shaders/night_mode.frag')
        .then((program) {
          _program = program;
          ready.value = true;
        })
        .catchError((Object error, StackTrace stack) {
          // Rendering unfiltered is an acceptable fallback; retrying every
          // frame is not, so the failure is remembered by leaving
          // [ready] false and [_loadStarted] true.
          debugPrint('Failed to load night mode shader: $error');
        });
  }
}

/// Applies the night-mode transform to [child] when [enabled].
///
/// The filter runs over the child's rendered output, so it composes with
/// whatever the reader already painted (cropping, dual-page splits, cover
/// crops) instead of having to be threaded through each painter.
class NightModeFilter extends StatefulWidget {
  const NightModeFilter({
    super.key,
    required this.enabled,
    required this.threshold,
    required this.child,
  });

  final bool enabled;

  final double threshold;

  final Widget child;

  @override
  State<NightModeFilter> createState() => _NightModeFilterState();
}

class _NightModeFilterState extends State<NightModeFilter> {
  ui.FragmentShader? _shader;
  double? _shaderThreshold;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) {
      NightModeShader.ensureLoaded();
    }
  }

  @override
  void didUpdateWidget(NightModeFilter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && !oldWidget.enabled) {
      NightModeShader.ensureLoaded();
    }
    if (!widget.enabled) {
      _releaseShader();
    }
  }

  @override
  void dispose() {
    _releaseShader();
    super.dispose();
  }

  void _releaseShader() {
    _shader?.dispose();
    _shader = null;
    _shaderThreshold = null;
  }

  /// Reuses the existing shader unless the threshold actually changed, so
  /// an unrelated rebuild can't dispose a shader a retained layer is still
  /// painting with.
  ui.FragmentShader? _shaderFor(ui.FragmentProgram program) {
    if (_shader != null && _shaderThreshold == widget.threshold) {
      return _shader;
    }
    _shader?.dispose();
    final shader = program.fragmentShader();
    // Float index 2: uSize occupies indices 0 and 1, and samplers are
    // indexed separately. Both of those are bound by the engine for
    // ImageFilter.shader, so the threshold is the only uniform to set.
    shader.setFloat(2, widget.threshold);
    _shader = shader;
    _shaderThreshold = widget.threshold;
    return shader;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return widget.child;
    }
    return ValueListenableBuilder<bool>(
      valueListenable: NightModeShader.ready,
      builder: (context, ready, child) {
        final program = NightModeShader.program;
        if (!ready || program == null) {
          return child!;
        }
        return ImageFiltered(
          imageFilter: ui.ImageFilter.shader(_shaderFor(program)!),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}
