import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/night_mode.dart';

void main() {
  group('nightModeDimPixel', () {
    test('dims a white page background without making it pure black', () {
      expect(nightModeDimPixel(245, 245, 245), (61, 61, 61));
    });

    test('leaves black black instead of flipping it to white', () {
      expect(nightModeDimPixel(0, 0, 0), (0, 0, 0));
    });

    test('keeps paper and ink clearly apart', () {
      // The regression this guards: an earlier fold-based transform sent
      // both a light background and dark ink to near-black, leaving about
      // 10/255 between them and making pages unreadable.
      final (paper, _, _) = nightModeDimPixel(245, 245, 245);
      final (ink, _, _) = nightModeDimPixel(20, 20, 20);
      expect(paper - ink, greaterThan(40));
    });

    test('preserves the ordering of tones', () {
      var previous = -1;
      for (var value = 0; value <= 255; value++) {
        final (out, _, _) = nightModeDimPixel(value, value, value);
        expect(out, greaterThanOrEqualTo(previous));
        previous = out;
      }
    });

    test('scales channels evenly so hue is untouched', () {
      // A 3:2:1 channel ratio stays 3:2:1 after dimming.
      expect(nightModeDimPixel(240, 160, 80), (60, 40, 20));
    });

    test('a brightness of 1 leaves the page untouched', () {
      expect(nightModeDimPixel(200, 100, 50, brightness: 1.0), (200, 100, 50));
    });

    test('a lower brightness dims further', () {
      expect(nightModeDimPixel(200, 200, 200, brightness: 0.1), (20, 20, 20));
      expect(nightModeDimPixel(200, 200, 200, brightness: 0.6), (120, 120, 120));
    });
  });

  group('nightModeColorMatrix', () {
    test('is a plain channel scale that passes alpha through', () {
      expect(nightModeColorMatrix(0.25), [
        0.25, 0, 0, 0, 0, //
        0, 0.25, 0, 0, 0, //
        0, 0, 0.25, 0, 0, //
        0, 0, 0, 1, 0, //
      ]);
    });

    test('agrees with the per-pixel reference implementation', () {
      const brightness = 0.25;
      final matrix = nightModeColorMatrix(brightness);
      for (final value in [0, 20, 128, 200, 245, 255]) {
        final viaMatrix = (value * matrix[0]).round();
        final (viaPixel, _, _) = nightModeDimPixel(
          value,
          value,
          value,
          brightness: brightness,
        );
        expect(viaMatrix, viaPixel);
      }
    });
  });
}
