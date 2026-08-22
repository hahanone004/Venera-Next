import 'dart:typed_data';

import 'package:flutter/material.dart';
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

  group('edge margin detection (uncapped, for cover-crop budget)', () {
    test('reports the full blank run length with no cap', () {
      // height=20 -> the 40% edge-trim cap used by computeWhitespaceSegments
      // would be floor(20*0.4)=8, but this function must ignore that cap.
      final pixels = _buildPixels(
        width: 128,
        height: 20,
        blankRows: {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 17, 18, 19},
      );

      final margins = computeEdgeMargins(pixels, 128, 20);

      expect(margins, (top: 10, bottom: 3));
    });

    test('treats a fully blank image as all-top margin', () {
      final pixels = _buildPixels(
        width: 128,
        height: 20,
        blankRows: {for (var i = 0; i < 20; i++) i},
      );

      expect(computeEdgeMargins(pixels, 128, 20), (top: 20, bottom: 0));
    });

    test('returns zero margins for an empty image', () {
      expect(computeEdgeMargins(ByteData(0), 0, 0), (top: 0, bottom: 0));
    });
  });

  group('cover crop rect', () {
    test('crops symmetrically when there is no margin to prefer', () {
      final rect = computeCoverCropRect(
        imageSize: const Size(400, 1000),
        viewportSize: const Size(400, 600),
        topMargin: 0,
        bottomMargin: 0,
      );

      expect(rect, const Rect.fromLTWH(0, 200, 400, 600));
    });

    test('prefers cropping into the top margin before real content', () {
      final rect = computeCoverCropRect(
        imageSize: const Size(400, 1000),
        viewportSize: const Size(400, 600),
        topMargin: 500,
        bottomMargin: 0,
      );

      // Margin alone covers the whole 400px overflow, so nothing is taken
      // from the bottom (crop window ends exactly at the source bottom).
      expect(rect, const Rect.fromLTWH(0, 400, 400, 600));
    });

    test('uses up both margins, then splits the remainder evenly', () {
      final rect = computeCoverCropRect(
        imageSize: const Size(400, 1000),
        viewportSize: const Size(400, 600),
        topMargin: 100,
        bottomMargin: 50,
      );

      // overflow=400; margins cover 150; remaining 250 split 125/125.
      expect(rect, const Rect.fromLTWH(0, 225, 400, 600));
    });

    test('splits horizontal overflow symmetrically (no margin signal)', () {
      final rect = computeCoverCropRect(
        imageSize: const Size(1200, 800),
        viewportSize: const Size(400, 800),
        topMargin: 0,
        bottomMargin: 0,
      );

      expect(rect, const Rect.fromLTWH(400, 0, 400, 800));
    });

    test('returns the full image when the aspect ratio already matches', () {
      final rect = computeCoverCropRect(
        imageSize: const Size(400, 600),
        viewportSize: const Size(400, 600),
        topMargin: 0,
        bottomMargin: 0,
      );

      expect(rect, const Rect.fromLTWH(0, 0, 400, 600));
    });
  });
}
