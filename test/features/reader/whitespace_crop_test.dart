import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/comic_image.dart';

/// Builds a synthetic RGBA buffer where [blankRows] are a flat white row and
/// every other row has enough per-column variation to be treated as content.
ByteData _buildPixels({
  required int width,
  required int height,
  required Set<int> blankRows,
}) {
  final bytes = Uint8List(width * height * 4);
  for (var row = 0; row < height; row++) {
    final isBlank = blankRows.contains(row);
    for (var col = 0; col < width; col++) {
      final i = (row * width + col) * 4;
      // Values chosen so that even with the function's column sampling
      // stride, sampled pixels within a "content" row still disagree.
      final value = isBlank ? 255 : (col % 3 == 0 ? 0 : 255);
      bytes[i] = value;
      bytes[i + 1] = value;
      bytes[i + 2] = value;
      bytes[i + 3] = 255;
    }
  }
  return ByteData.view(bytes.buffer);
}

void main() {
  group('whitespace segment detection', () {
    test('trims blank margins from the top and bottom edges', () {
      final pixels = _buildPixels(
        width: 128,
        height: 20,
        blankRows: {0, 1, 2, 3, 4, 17, 18, 19},
      );

      final segments = computeWhitespaceSegments(pixels, 128, 20);

      // The edge margins are fully trimmed (well under the 40% cap), only
      // the content run in the middle remains.
      expect(segments, [
        const ImageContentSegment(
          sourceTop: 5,
          sourceHeight: 12,
          displayHeight: 12,
        ),
      ]);
    });

    test('leaves a small gap in the middle untouched', () {
      final pixels = _buildPixels(
        width: 128,
        height: 20,
        blankRows: {8, 9, 10},
      );

      final segments = computeWhitespaceSegments(pixels, 128, 20);

      expect(segments, [
        const ImageContentSegment(
          sourceTop: 0,
          sourceHeight: 8,
          displayHeight: 8,
        ),
        const ImageContentSegment(
          sourceTop: 8,
          sourceHeight: 3,
          displayHeight: 3,
        ),
        const ImageContentSegment(
          sourceTop: 11,
          sourceHeight: 9,
          displayHeight: 9,
        ),
      ]);
    });

    test('shrinks a large gap in the middle without removing it', () {
      // width 128 -> max internal gap is round(128 * 0.06) = 8, floored up
      // to the 24px minimum, so an 80-row gap should be capped at 24.
      final pixels = _buildPixels(
        width: 128,
        height: 90,
        blankRows: {for (var i = 5; i < 85; i++) i},
      );

      final segments = computeWhitespaceSegments(pixels, 128, 90);

      expect(segments, [
        const ImageContentSegment(
          sourceTop: 0,
          sourceHeight: 5,
          displayHeight: 5,
        ),
        const ImageContentSegment(
          sourceTop: 5,
          sourceHeight: 80,
          displayHeight: 24,
        ),
        const ImageContentSegment(
          sourceTop: 85,
          sourceHeight: 5,
          displayHeight: 5,
        ),
      ]);
      // Shrunk, not eliminated: the gap is still visible between panels.
      expect(segments[1].displayHeight, greaterThan(0));
    });

    test('caps trimming so a fully blank image is not collapsed', () {
      final pixels = _buildPixels(
        width: 128,
        height: 20,
        blankRows: {for (var i = 0; i < 20; i++) i},
      );

      final segments = computeWhitespaceSegments(pixels, 128, 20);

      // Single run touches both edges, so it's trimmed from both sides:
      // 20 - floor(20*0.4)*2 = 4 rows remain.
      expect(segments, [
        const ImageContentSegment(
          sourceTop: 0,
          sourceHeight: 20,
          displayHeight: 4,
        ),
      ]);
    });

    test('returns no segments for an empty image', () {
      expect(computeWhitespaceSegments(ByteData(0), 0, 0), isEmpty);
    });
  });

  group('adjustable luma tolerance', () {
    // Row 5 isn't a pristine flat color: sampled pixels alternate between
    // luma 200 and 200+18=218, mimicking a textured/noisy "blank" margin
    // (e.g. a black background with subtle grain) rather than a perfectly
    // uniform one.
    ByteData buildNoisyRowPixels({required int width, required int height}) {
      final bytes = Uint8List(width * height * 4);
      for (var row = 0; row < height; row++) {
        for (var col = 0; col < width; col++) {
          final i = (row * width + col) * 4;
          final value = row == 5
              ? (col % 4 < 2 ? 200 : 218)
              : 255;
          bytes[i] = value;
          bytes[i + 1] = value;
          bytes[i + 2] = value;
          bytes[i + 3] = 255;
        }
      }
      return ByteData.view(bytes.buffer);
    }

    test('default tolerance treats the noisy row as content', () {
      final pixels = buildNoisyRowPixels(width: 128, height: 10);

      final segments = computeWhitespaceSegments(pixels, 128, 10);

      // The noisy row (spread 18) breaks the blank run in two: each half
      // (length 5 and 4) gets edge-trimmed independently, and the bottom
      // half's 4 rows are entirely within the trim cap and disappear.
      expect(segments, [
        const ImageContentSegment(
          sourceTop: 0,
          sourceHeight: 5,
          displayHeight: 1,
        ),
        const ImageContentSegment(
          sourceTop: 5,
          sourceHeight: 1,
          displayHeight: 1,
        ),
      ]);
    });

    test('a looser tolerance folds the same noisy row back into blank', () {
      final pixels = buildNoisyRowPixels(width: 128, height: 10);

      final segments = computeWhitespaceSegments(
        pixels,
        128,
        10,
        lumaTolerance: 20,
      );

      // Now the whole image is one blank run touching both edges:
      // 10 - floor(10*0.4)*2 = 2 rows remain.
      expect(segments, [
        const ImageContentSegment(
          sourceTop: 0,
          sourceHeight: 10,
          displayHeight: 2,
        ),
      ]);
    });
  });
}
