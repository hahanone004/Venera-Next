import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/night_mode.dart';

void main() {
  group('nightModeInvertPixel at the default threshold', () {
    test('turns a white background into black', () {
      expect(nightModeInvertPixel(255, 255, 255), (0, 0, 0));
    });

    test('leaves black content untouched instead of flipping it bright', () {
      expect(nightModeInvertPixel(0, 0, 0), (0, 0, 0));
    });

    test('leaves already-dark gray untouched', () {
      expect(nightModeInvertPixel(50, 50, 50), (50, 50, 50));
    });

    test('folds a light gray down to a dark gray', () {
      // L = 200/255 = 0.7843 -> 1 - L = 0.2157 -> 55.
      expect(nightModeInvertPixel(200, 200, 200), (55, 55, 55));
    });

    test('leaves a fully saturated primary untouched (its L is exactly 0.5)', () {
      expect(nightModeInvertPixel(255, 0, 0), (255, 0, 0));
    });

    test('preserves hue when folding a light color', () {
      // Light cyan should become dark cyan, not a complementary hue.
      expect(nightModeInvertPixel(200, 255, 255), (0, 55, 55));
    });
  });

  group('threshold', () {
    test('raising it lets mid-tones pass through unchanged', () {
      // L = 170/255 = 0.667: folded at 0.5, passed through at 0.7.
      expect(nightModeInvertPixel(170, 170, 170), (85, 85, 85));
      expect(
        nightModeInvertPixel(170, 170, 170, threshold: 0.7),
        (170, 170, 170),
      );
    });

    test('still sends white to black at a raised threshold', () {
      expect(nightModeInvertPixel(255, 255, 255, threshold: 0.7), (0, 0, 0));
    });

    test('is continuous across the threshold', () {
      // 178/255 = 0.698 sits just under the threshold and passes through;
      // 179/255 = 0.702 sits just over it and folds. The outputs stay
      // adjacent, so the fold introduces no visible seam.
      expect(
        nightModeInvertPixel(178, 178, 178, threshold: 0.7),
        (178, 178, 178),
      );
      expect(
        nightModeInvertPixel(179, 179, 179, threshold: 0.7),
        (177, 177, 177),
      );
    });

    test('a threshold of 1 disables the transform entirely', () {
      expect(nightModeInvertPixel(255, 255, 255, threshold: 1.0), (255, 255, 255));
    });
  });
}
