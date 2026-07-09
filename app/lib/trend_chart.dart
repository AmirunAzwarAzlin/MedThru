import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'readings.dart';

/// One point on a trend line.
typedef TrendPoint = ({DateTime t, double v});

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String shortDate(DateTime d) => '${d.day} ${_months[d.month - 1]}';
String longDate(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

/// A single-series line chart of one reading over time.
///
/// One series per chart on purpose: blood sugar, cholesterol and uric acid
/// have different units and magnitudes, and overlaying them would need two
/// y-scales. Small multiples instead of a dual axis.
///
/// The series name lives in the card title, so no legend box is needed. The
/// latest point is labelled directly rather than every point.
class TrendChart extends StatefulWidget {
  const TrendChart({
    super.key,
    required this.points,
    required this.spec,
    this.height = 180,
  });

  final List<TrendPoint> points;
  final ReadingType spec;
  final double height;

  @override
  State<TrendChart> createState() => _TrendChartState();
}

class _TrendChartState extends State<TrendChart> {
  int? _selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = widget.spec.color(context);

    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, widget.height);
          final geom = _Geometry(
            size: size,
            points: widget.points,
            spec: widget.spec,
          );

          void selectAt(Offset local) {
            final i = geom.nearestIndex(local.dx);
            if (i != _selected) setState(() => _selected = i);
          }

          return MouseRegion(
            onHover: (e) => selectAt(e.localPosition),
            onExit: (_) => setState(() => _selected = null),
            child: GestureDetector(
              onTapDown: (d) => selectAt(d.localPosition),
              onHorizontalDragUpdate: (d) => selectAt(d.localPosition),
              onHorizontalDragEnd: (_) => setState(() => _selected = null),
              child: CustomPaint(
                size: size,
                painter: _TrendPainter(
                  geom: geom,
                  spec: widget.spec,
                  seriesColor: color,
                  selected: _selected,
                  gridColor: scheme.outlineVariant,
                  axisTextColor: scheme.onSurfaceVariant,
                  inkColor: scheme.onSurface,
                  surfaceColor: scheme.surfaceContainerLow,
                  bandColor: scheme.onSurfaceVariant.withValues(alpha: 0.07),
                  tooltipBg: scheme.inverseSurface,
                  tooltipInk: scheme.onInverseSurface,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Maps data space to pixels. Kept separate so hit-testing and painting agree.
class _Geometry {
  _Geometry({required this.size, required this.points, required this.spec}) {
    const padLeft = 46.0, padRight = 14.0, padTop = 14.0, padBottom = 28.0;
    plot = Rect.fromLTRB(
      padLeft,
      padTop,
      size.width - padRight,
      size.height - padBottom,
    );

    final dataLo = points.map((p) => p.v).reduce(math.min);
    final dataHi = points.map((p) => p.v).reduce(math.max);

    // Pull a reference bound into view only when it is near the data. Forcing
    // the whole band into the domain (uric acid: band 200-430 vs data 383-466)
    // squashes the line into a sliver. A distant bound is simply clipped away.
    final dataSpan = dataHi - dataLo;
    final slack = dataSpan == 0 ? (dataHi.abs() * 0.2 + 1) : dataSpan * 0.5;
    bool near(double v) => v >= dataLo - slack && v <= dataHi + slack;

    var lo = dataLo;
    var hi = dataHi;
    if (spec.low != null && near(spec.low!)) lo = math.min(lo, spec.low!);
    if (spec.high != null && near(spec.high!)) hi = math.max(hi, spec.high!);

    final span = hi - lo;
    final pad = span == 0 ? (hi.abs() * 0.1 + 1) : span * 0.12;
    var lowerY = lo - pad;
    var upperY = hi + pad;

    // Widen the domain to whole ticks so gridlines land on round numbers.
    final t = _niceTicks(lowerY, upperY);
    if (t.isNotEmpty) {
      lowerY = math.min(lowerY, t.first);
      upperY = math.max(upperY, t.last);
    }
    ticks = t;
    minY = lowerY;
    maxY = upperY;

    final times = points.map((p) => p.t.millisecondsSinceEpoch).toList();
    minX = times.reduce(math.min).toDouble();
    maxX = times.reduce(math.max).toDouble();
  }

  final Size size;
  final List<TrendPoint> points;
  final ReadingType spec;

  late final Rect plot;
  late final double minY, maxY, minX, maxX;
  late final List<double> ticks;

  /// Readings taken at the same instant (or a lone point) have no time span;
  /// fall back to even spacing so the line still renders.
  bool get _degenerateX => maxX <= minX;

  double xFor(int i) {
    if (_degenerateX) {
      if (points.length == 1) return plot.center.dx;
      return plot.left + plot.width * (i / (points.length - 1));
    }
    final t = points[i].t.millisecondsSinceEpoch.toDouble();
    return plot.left + plot.width * ((t - minX) / (maxX - minX));
  }

  double yFor(double v) =>
      plot.bottom - plot.height * ((v - minY) / (maxY - minY));

  Offset pointAt(int i) => Offset(xFor(i), yFor(points[i].v));

  int nearestIndex(double dx) {
    var best = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < points.length; i++) {
      final d = (xFor(i) - dx).abs();
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return best;
  }

  static List<double> _niceTicks(double lo, double hi) {
    if (hi <= lo) return [lo];
    final raw = (hi - lo) / 4;
    final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    final norm = raw / mag;
    final step = (norm < 1.5 ? 1 : norm < 3 ? 2 : norm < 7 ? 5 : 10) * mag;
    final first = (lo / step).ceil() * step;
    final out = <double>[];
    for (var v = first; v <= hi + step * 0.001; v += step) {
      out.add(double.parse(v.toStringAsFixed(6)));
    }
    return out;
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter({
    required this.geom,
    required this.spec,
    required this.seriesColor,
    required this.selected,
    required this.gridColor,
    required this.axisTextColor,
    required this.inkColor,
    required this.surfaceColor,
    required this.bandColor,
    required this.tooltipBg,
    required this.tooltipInk,
  });

  final _Geometry geom;
  final ReadingType spec;
  final Color seriesColor;
  final int? selected;
  final Color gridColor, axisTextColor, inkColor, surfaceColor, bandColor;
  final Color tooltipBg, tooltipInk;

  @override
  void paint(Canvas canvas, Size size) {
    _paintReferenceBand(canvas);
    _paintGridAndAxis(canvas);

    // Series line: 2px, rounded joins.
    final path = Path();
    for (var i = 0; i < geom.points.length; i++) {
      final p = geom.pointAt(i);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = seriesColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );

    // Markers only when sparse enough to stay legible.
    if (geom.points.length <= 16) {
      for (var i = 0; i < geom.points.length; i++) {
        _marker(canvas, geom.pointAt(i), 4);
      }
    }

    _paintXLabels(canvas);

    final last = geom.points.length - 1;
    if (selected == null) {
      // Selective direct label: the latest value only, never every point.
      _marker(canvas, geom.pointAt(last), 5);
      _directLabel(canvas, last);
    } else {
      _paintCrosshair(canvas, selected!);
    }
  }

  void _marker(Canvas canvas, Offset c, double r) {
    // 2px surface ring keeps overlapping marks readable.
    canvas.drawCircle(c, r + 2, Paint()..color = surfaceColor);
    canvas.drawCircle(c, r, Paint()..color = seriesColor);
  }

  void _paintReferenceBand(Canvas canvas) {
    if (spec.low == null && spec.high == null) return;
    final top = geom.yFor(spec.high ?? geom.maxY);
    final bottom = geom.yFor(spec.low ?? geom.minY);
    final rect = Rect.fromLTRB(
      geom.plot.left,
      math.max(top, geom.plot.top),
      geom.plot.right,
      math.min(bottom, geom.plot.bottom),
    );
    if (rect.height <= 0) return;
    // Recessive neutral, not a status colour: this is context, not a verdict.
    // Deliberately unlabelled -- the card header states the range in words,
    // and an in-chart label collides with the direct label on the last point.
    canvas.drawRect(rect, Paint()..color = bandColor);
  }

  void _paintGridAndAxis(Canvas canvas) {
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (final t in geom.ticks) {
      final y = geom.yFor(t);
      if (y < geom.plot.top - 0.5 || y > geom.plot.bottom + 0.5) continue;
      canvas.drawLine(Offset(geom.plot.left, y), Offset(geom.plot.right, y), grid);
      final tp = _text(spec.format(t), axisTextColor, 10);
      tp.paint(canvas, Offset(geom.plot.left - tp.width - 6, y - tp.height / 2));
    }
  }

  void _paintXLabels(Canvas canvas) {
    if (geom.points.isEmpty) return;
    final y = geom.plot.bottom + 7;
    final first = _text(shortDate(geom.points.first.t), axisTextColor, 10);
    first.paint(canvas, Offset(geom.plot.left, y));
    if (geom.points.length > 1) {
      final last = _text(shortDate(geom.points.last.t), axisTextColor, 10);
      last.paint(canvas, Offset(geom.plot.right - last.width, y));
    }
  }

  /// Label only the latest point. Prefer sitting to its right; if that would
  /// overflow, go above (or below) rather than left, where it would land on
  /// the previous marker. A surface chip keeps it legible over grid and band.
  void _directLabel(Canvas canvas, int i) {
    final p = geom.pointAt(i);
    final tp = _text(spec.format(geom.points[i].v), inkColor, 11.5, bold: true);
    const padH = 4.0, padV = 2.0, gap = 9.0;
    final w = tp.width + padH * 2;
    final h = tp.height + padV * 2;

    Rect? chosen;
    for (final candidate in [
      Rect.fromLTWH(p.dx + gap, p.dy - h / 2, w, h), // right
      Rect.fromLTWH(p.dx - w / 2, p.dy - gap - h, w, h), // above
      Rect.fromLTWH(p.dx - w / 2, p.dy + gap, w, h), // below
    ]) {
      if (candidate.left >= geom.plot.left &&
          candidate.right <= geom.plot.right &&
          candidate.top >= 0 &&
          candidate.bottom <= geom.plot.bottom) {
        chosen = candidate;
        break;
      }
    }
    // Nothing fit cleanly: sit above the point, nudged inside the plot.
    chosen ??= Rect.fromLTWH(
      (p.dx - w / 2).clamp(geom.plot.left, geom.plot.right - w),
      (p.dy - gap - h).clamp(0.0, geom.plot.bottom - h),
      w,
      h,
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(chosen, const Radius.circular(5)),
      Paint()..color = surfaceColor,
    );
    tp.paint(canvas, Offset(chosen.left + padH, chosen.top + padV));
  }

  void _paintCrosshair(Canvas canvas, int i) {
    final p = geom.pointAt(i);
    canvas.drawLine(
      Offset(p.dx, geom.plot.top),
      Offset(p.dx, geom.plot.bottom),
      Paint()
        ..color = axisTextColor.withValues(alpha: 0.35)
        ..strokeWidth = 1,
    );
    _marker(canvas, p, 5);

    final pt = geom.points[i];
    final value = _text(
      '${spec.format(pt.v)} ${spec.unit}',
      tooltipInk,
      11.5,
      bold: true,
    );
    final date = _text(longDate(pt.t), tooltipInk.withValues(alpha: 0.75), 10);

    const padH = 8.0, padV = 6.0, gap = 2.0;
    final w = math.max(value.width, date.width) + padH * 2;
    final h = value.height + date.height + gap + padV * 2;

    var left = p.dx + 12;
    if (left + w > geom.plot.right) left = p.dx - w - 12;
    left = left.clamp(0.0, geom.size.width - w);
    var top = p.dy - h - 10;
    if (top < 0) top = p.dy + 12;

    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, top, w, h),
      const Radius.circular(8),
    );
    canvas.drawRRect(rect, Paint()..color = tooltipBg);
    value.paint(canvas, Offset(left + padH, top + padV));
    date.paint(canvas, Offset(left + padH, top + padV + value.height + gap));
  }

  TextPainter _text(String s, Color c, double size, {bool bold = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          color: c,
          fontSize: size,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return tp;
  }

  @override
  bool shouldRepaint(_TrendPainter old) =>
      old.selected != selected ||
      old.seriesColor != seriesColor ||
      old.geom.points != geom.points;
}
