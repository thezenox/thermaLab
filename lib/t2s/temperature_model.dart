// Radiometric model mapping 14-bit sensor counts to °C.
//
// Ported from IR-Py-Thermal (https://github.com/diminDDL/IR-Py-Thermal,
// GPL-3.0). The camera's factory constants cal00..cal05 feed a Planck-style
// inversion with atmospheric transmittance; evaluating it for every possible
// count gives a lookup table that is then applied per pixel.

import 'dart:math' as math;
import 'dart:typed_data';

import 't2s_frame.dart';

const int kTableSize = 16384;

enum HardwareRevision {
  /// The camera does non-uniformity correction itself and reports usable
  /// shutter/core temperatures.
  v1,

  /// The camera streams uncorrected sensor counts; the app has to do the
  /// shutter correction, and the shutter temperature needs an offset.
  v2,
}

enum MeasurementRange { normal, high }

/// Where the model takes the shutter temperature from.
enum ShutterSource {
  /// The camera's shutter register (decoded per [HardwareRevision]).
  register,

  /// The focal-plane-array temperature, assuming the shutter sits at
  /// sensor temperature. Candidate fix for V2 units, whose shutter
  /// register is known to be unreliable.
  fpa,
}

class ModelSettings {
  const ModelSettings({
    required this.revision,
    this.range = MeasurementRange.normal,
    this.shutterSource = ShutterSource.register,
    this.shutterOffset = 0.0,
    this.userOffset = 0.0,
  });

  final HardwareRevision revision;
  final MeasurementRange range;
  final ShutterSource shutterSource;

  /// Added to the decoded shutter temperature before it enters the model.
  /// This is the one-point calibration for V2 units.
  final double shutterOffset;

  /// Added to every resulting temperature (simple one-point offset).
  final double userOffset;

  ModelSettings copyWith({
    HardwareRevision? revision,
    MeasurementRange? range,
    ShutterSource? shutterSource,
    double? shutterOffset,
    double? userOffset,
  }) => ModelSettings(
    revision: revision ?? this.revision,
    range: range ?? this.range,
    shutterSource: shutterSource ?? this.shutterSource,
    shutterOffset: shutterOffset ?? this.shutterOffset,
    userOffset: userOffset ?? this.userOffset,
  );
}

class TemperatureTable {
  TemperatureTable._(
    this.values,
    this.shutterTemp,
    this.fpaTemp,
    this.shutterLevel,
  );

  /// °C for every count 0..16383, NaN where the model has no solution.
  final Float32List values;

  /// Shutter temperature that went into the model (after offset).
  final double shutterTemp;
  final double fpaTemp;

  /// Count at which the model returns the shutter temperature: a scene
  /// exactly as warm as the shutter reads this value. Shutter-corrected V2
  /// frames are anchored here.
  final double shutterLevel;

  double lookup(int count) => values[count.clamp(0, kTableSize - 1)];

  int get nanCount {
    int n = 0;
    for (final double v in values) {
      if (v.isNaN) n++;
    }
    return n;
  }

  /// Table for cameras that deliver temperatures directly (Tiny1-C): maps
  /// the linear counts back to °C. Only the user offset applies.
  static TemperatureTable linear(ModelSettings settings) {
    final Float32List table = Float32List(kTableSize);
    for (int i = 0; i < kTableSize; i++) {
      table[i] = i / kLinearCountsPerC - kLinearOffsetC + settings.userOffset;
    }
    return TemperatureTable._(table, double.nan, double.nan, 0);
  }

  static TemperatureTable build(
    T2sMetadata meta,
    SensorProfile profile,
    ModelSettings settings,
  ) {
    final bool v2 = settings.revision == HardwareRevision.v2;
    final double fpa = meta.fpaTemp(profile);
    final double shutterReading = switch (settings.shutterSource) {
      ShutterSource.register => v2 ? meta.shutterTempV2 : meta.shutterTempV1,
      ShutterSource.fpa => fpa,
    };
    final double shutter = shutterReading + settings.shutterOffset;

    final double cal01 = meta.cal01;
    final double cal02 = meta.cal02;
    final double calA = cal02 / (cal01 + cal01);
    final double calB = cal02 * cal02 / (cal01 * cal01 * 4.0);
    final double calC = cal01 * shutter * shutter + shutter * cal02;
    final double calD = meta.cal03 * fpa * fpa + meta.cal04 * fpa + meta.cal05;

    // IR-Py-Thermal always uses its 120 °C branch here.
    final int cal00Correction =
        (profile.cal00Offset - fpa * profile.cal00FpaMultiplier).toInt();
    final double tableOffset =
        meta.cal00 - (cal00Correction > 0 ? cal00Correction : 0).toDouble();

    final double distance =
        (meta.distance >= 20 ? 20.0 : meta.distance.toDouble());
    final double air = meta.airTemp;
    final double atm = _atmosphericTransmittance(meta.humidity, air, distance);
    final double emissivity = meta.emissivity;
    final double numeratorSub =
        (1.0 - emissivity) *
            atm *
            math.pow(meta.reflectedTemp + kZeroCelsius, 4).toDouble() +
        (1.0 - atm) * math.pow(air + kZeroCelsius, 4).toDouble();
    final double denominator = emissivity * atm;

    double m = 1.0;
    double b = 0.0;
    if (settings.range == MeasurementRange.high) {
      // Unverified coefficients from IR-Py-Thermal.
      if (v2) {
        m = 0.1;
      } else {
        m = 1.17;
        b = -40.9;
      }
    }

    final Float32List table = Float32List(kTableSize);
    for (int i = 0; i < kTableSize; i++) {
      final double n = math.sqrt(
        (((i - tableOffset) * calD + calC) / cal01 + calB).abs(),
      );
      final double wtot = math.pow(n - calA + kZeroCelsius, 4).toDouble();
      final double base = (wtot - numeratorSub) / denominator;
      final double ttot = base < 0 || base.isNaN
          ? double.nan
          : math.pow(base, 0.25).toDouble() - kZeroCelsius;
      final double t =
          ttot + (distance * 0.85 - 1.125) * (ttot - air) / 100.0 +
          meta.correction;
      table[i] = m * t + b + settings.userOffset;
    }
    return TemperatureTable._(table, shutter, fpa, tableOffset);
  }

  // Water vapour coefficient from relative humidity and air temperature.
  static double _waterVapour(double h, double tAtm) {
    const double h1 = 1.5587;
    const double h2 = 0.06939;
    const double h3 = -2.7816e-4;
    const double h4 = 6.8455e-7;
    return h *
        math.exp(
          h1 + h2 * tAtm + h3 * tAtm * tAtm + h4 * tAtm * tAtm * tAtm,
        );
  }

  static double _atmosphericTransmittance(double h, double tAtm, double d) {
    const double kAtm = 1.9;
    final double nsqd = -math.sqrt(d);
    final double sqw = math.sqrt(_waterVapour(h, tAtm));
    const double a1 = 0.006569;
    const double a2 = 0.01262;
    const double b1 = -0.002276;
    const double b2 = -0.00667;
    return kAtm * math.exp(nsqd * (a1 + b1 * sqw)) +
        (1.0 - kAtm) * math.exp(nsqd * (a2 + b2 * sqw));
  }
}

/// Finds the shutter offset that makes [count] read [targetCelsius], by
/// Newton iteration on the model's own local slope (it is not 1:1).
/// Returns null if the model gives no usable reading.
double? solveShutterOffset({
  required T2sMetadata meta,
  required SensorProfile profile,
  required ModelSettings settings,
  required int count,
  required double targetCelsius,
}) {
  double offset = settings.shutterOffset;
  const double probeStep = 5.0;
  double read(double o) => TemperatureTable.build(
    meta,
    profile,
    settings.copyWith(shutterOffset: o, userOffset: 0),
  ).lookup(count);

  for (int iteration = 0; iteration < 12; iteration++) {
    final double current = read(offset);
    if (current.isNaN) return null;
    if ((current - targetCelsius).abs() < 0.05) return offset;
    final double probed = read(offset + probeStep);
    double slope = (probed - current) / probeStep;
    if (slope.isNaN || slope.abs() < 0.05) slope = 1.0;
    offset += (targetCelsius - current) / slope;
  }
  return read(offset).isNaN ? null : offset;
}
