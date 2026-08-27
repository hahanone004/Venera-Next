#version 460 core

// Night mode: threshold lightness-fold. Pixels at or below uThreshold are
// left untouched (so content that's already dark isn't flipped to bright);
// pixels above it are folded down into [0, uThreshold] with hue and
// saturation preserved, so a light page background becomes dark.
//
// This mirrors nightModeInvertPixel() in
// lib/features/reader/night_mode.dart, which is the version actually
// covered by unit tests -- this shader's own visual output can only be
// checked by running the app, so the Dart twin is where the math is
// verified. Keep the two in sync.

#include <flutter/runtime_effect.glsl>

// uSize and uTexture are populated automatically by ImageFilter.shader:
// the vec2 receives the filtered layer's size and the first sampler2D
// receives its rendered content. Only uThreshold is set from Dart, at
// float index 2 (uSize occupies 0 and 1; samplers are indexed separately).
uniform vec2 uSize;
uniform sampler2D uTexture;
uniform float uThreshold;

out vec4 fragColor;

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  vec4 srcColor = texture(uTexture, uv);

  vec3 c = srcColor.rgb;
  float maxC = max(c.r, max(c.g, c.b));
  float minC = min(c.r, min(c.g, c.b));
  float l = (maxC + minC) * 0.5;

  if (l <= uThreshold || uThreshold >= 1.0) {
    fragColor = srcColor;
    return;
  }

  // Continuous at uThreshold (maps to itself) and sends L=1 to 0.
  float folded = uThreshold * (1.0 - l) / (1.0 - uThreshold);

  // HSL keeps *relative* saturation, so chroma scales by the ratio of the
  // two lightnesses' chroma ceilings. Rescaling each channel around the
  // new lightness by that factor is algebraically identical to a full
  // RGB->HSL->RGB round trip, but needs no hue math and no branching.
  float ceiling = 1.0 - abs(2.0 * l - 1.0);
  float k = ceiling == 0.0 ? 0.0 : (1.0 - abs(2.0 * folded - 1.0)) / ceiling;

  vec3 result = clamp(vec3(folded) + (c - vec3(l)) * k, 0.0, 1.0);
  fragColor = vec4(result, srcColor.a);
}
