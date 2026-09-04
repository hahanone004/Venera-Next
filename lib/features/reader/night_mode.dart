import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Default multiplier applied to each channel in night mode.
const kDefaultNightModeBrightness = 0.5;

/// Bounds offered by the brightness slider. The floor stays well clear of
/// zero: below roughly a third of the original brightness a typical page's
/// paper drops under the ambient glow of the screen itself and the artwork
/// stops being readable rather than merely dim.
const kMinNightModeBrightness = 0.3;
const kMaxNightModeBrightness = 0.9;

/// Reference implementation of the night-mode transform, in plain Dart, so
/// the math has unit-test coverage independent of how it is rendered.
///
/// Every channel is scaled by [brightness]. That is deliberately a plain
/// multiplication rather than anything cleverer:
///
///  * It is monotonic, so the ordering of tones is preserved and distinct
///    shades can never collapse onto each other. An earlier attempt folded
///    bright tones downward instead, which mapped both the paper and the
///    ink of a typical page to near-black and destroyed the contrast the
///    page is read by.
///  * Scaling all three channels by the same factor leaves hue untouched
///    and scales chroma in step with lightness, so the result reads as the
///    same artwork under dimmer light rather than as recolored artwork.
///  * Black stays black, so panels that are already dark are not flipped
///    to glaring white.
///
/// Being affine, it is expressible as a [ColorFilter.matrix], which is what
/// [NightModeFilter] uses -- no fragment shader required.
@visibleForTesting
(int r, int g, int b) nightModeDimPixel(
  int r,
  int g,
  int b, {
  double brightness = kDefaultNightModeBrightness,
}) {
  int channel(int c) => (c * brightness).clamp(0.0, 255.0).round();
  return (channel(r), channel(g), channel(b));
}

/// The color matrix form of [nightModeDimPixel], in the row-major 4x5
/// layout [ColorFilter.matrix] expects. Alpha is passed through untouched.
@visibleForTesting
List<double> nightModeColorMatrix(double brightness) => <double>[
  brightness, 0, 0, 0, 0, //
  0, brightness, 0, 0, 0, //
  0, 0, brightness, 0, 0, //
  0, 0, 0, 1, 0, //
];

/// Dims [child] for night reading when [enabled].
///
/// The filter runs over the child's rendered output, so it composes with
/// whatever the reader already painted (whitespace cropping, dual-page
/// splits, cover crops) instead of having to be threaded through each
/// painter.
class NightModeFilter extends StatelessWidget {
  const NightModeFilter({
    super.key,
    required this.enabled,
    required this.brightness,
    required this.child,
  });

  final bool enabled;

  /// Per-channel multiplier; 1.0 leaves the page untouched.
  final double brightness;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled || brightness >= 1.0) {
      return child;
    }
    return ColorFiltered(
      colorFilter: ColorFilter.matrix(nightModeColorMatrix(brightness)),
      child: child,
    );
  }
}
