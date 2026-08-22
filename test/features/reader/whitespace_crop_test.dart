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
      final value = isBlank
          ? 255
          : (col % 3 == 0 ? 0 : 255);
      bytes[i] = value;
      bytes[i + 1] = value;
      bytes[i + 2] = value;
      bytes[i + 3] = 255;
    }
  }
  return ByteData.view(bytes.buffer);
}

void main() {
  group('whitespace margin detection', () {
    test('trims blank rows from the top and bottom only', () {
      final pixels = _buildPixels(
        width: 128,
        height: 20,
        blankRows: {0, 1, 2, 3, 4, 17, 18, 19},
      );

      final margins = computeWhitespaceMargins(pixels, 128, 20);

      expect(margins.top, 5);
      expect(margins.bottom, 3);
    });

    test('ignores blank rows in the middle of the image', () {
      final pixels = _buildPixels(
        width: 128,
        height: 20,
        blankRows: {8, 9, 10},
      );

      final margins = computeWhitespaceMargins(pixels, 128, 20);

      expect(margins, EdgeInsets.zero);
    });

    test('caps trimming so a fully blank image is not collapsed', () {
      final pixels = _buildPixels(
        width: 128,
        height: 20,
        blankRows: {for (var i = 0; i < 20; i++) i},
      );

      final margins = computeWhitespaceMargins(pixels, 128, 20);

      expect(margins.top, 8);
      expect(margins.bottom, 8);
    });

    test('returns zero insets for an empty image', () {
      final pixels = ByteData(0);

      expect(computeWhitespaceMargins(pixels, 0, 0), EdgeInsets.zero);
    });
  });
}
