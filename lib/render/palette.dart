import 'dart:typed_data';
import 'dart:ui' show Color;

/// A colour map sampled to 256 entries, stored as RGBA bytes packed into
/// little-endian uint32 (byte order R, G, B, A in memory).
class Palette {
  Palette._(this.name, this.rgba);

  final String name;
  final Uint32List rgba;

  static Palette fromStops(String name, List<(double, Color)> stops) {
    final Uint32List out = Uint32List(256);
    for (int i = 0; i < 256; i++) {
      final double x = i / 255.0;
      int k = 0;
      while (k < stops.length - 2 && x > stops[k + 1].$1) {
        k++;
      }
      final (double p0, Color c0) = stops[k];
      final (double p1, Color c1) = stops[k + 1];
      final double t = p1 == p0 ? 0 : ((x - p0) / (p1 - p0)).clamp(0.0, 1.0);
      final Color c = Color.lerp(c0, c1, t)!;
      final int r = (c.r * 255).round();
      final int g = (c.g * 255).round();
      final int b = (c.b * 255).round();
      out[i] = 0xFF000000 | (b << 16) | (g << 8) | r;
    }
    return Palette._(name, out);
  }

  static final Palette iron = fromStops('Iron', const <(double, Color)>[
    (0.00, Color(0xFF000000)),
    (0.15, Color(0xFF20008C)),
    (0.35, Color(0xFF8C00A0)),
    (0.55, Color(0xFFD7262E)),
    (0.75, Color(0xFFF68C0C)),
    (0.90, Color(0xFFFCD836)),
    (1.00, Color(0xFFFFFFFF)),
  ]);

  static final Palette whiteHot = fromStops('White hot', const <(double, Color)>[
    (0.0, Color(0xFF000000)),
    (1.0, Color(0xFFFFFFFF)),
  ]);

  static final Palette rainbow = fromStops('Rainbow', const <(double, Color)>[
    (0.00, Color(0xFF000080)),
    (0.20, Color(0xFF0040FF)),
    (0.40, Color(0xFF00E0E0)),
    (0.60, Color(0xFF40E000)),
    (0.80, Color(0xFFFFC000)),
    (1.00, Color(0xFFFF0000)),
  ]);

  static final List<Palette> all = <Palette>[iron, whiteHot, rainbow];
}
