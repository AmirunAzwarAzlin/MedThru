import 'package:flutter/material.dart';
import '../../activity_summary.dart';
import '../../trend_chart.dart' show Sparkline;

/// A weekly recap of the patient's most active metrics — value, week-over-week
/// change, and a sparkline each. Complements (does not duplicate) the vital
/// signs snapshot: this one is about *change over the week*, not latest value.
/// Tone is neutral: a direction is never framed as good or bad.
class ActivityRecapCard extends StatelessWidget {
  const ActivityRecapCard({super.key, required this.readings});

  final List<Map<String, dynamic>> readings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final recaps = weeklyRecap(readings);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'THIS WEEK',
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 1,
              fontWeight: FontWeight.w700,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          if (recaps.isEmpty)
            Text(
              'Log a few more readings to unlock your weekly recap.',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            )
          else
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [for (final m in recaps) _RecapTile(recap: m)],
            ),
        ],
      ),
    );
  }
}

class _RecapTile extends StatelessWidget {
  const _RecapTile({required this.recap});
  final MetricRecap recap;

  @override
  Widget build(BuildContext context) {
    final spec = recap.spec;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      constraints: const BoxConstraints(minWidth: 104),
      decoration: BoxDecoration(
        color: spec.tile(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(spec.icon, size: 13, color: spec.color(context)),
              const SizedBox(width: 4),
              Text(
                spec.label,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: spec.color(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${spec.format(recap.latest)} ${spec.unit}',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 2),
          _changeLabel(scheme),
          if (recap.series.length >= 2) ...[
            const SizedBox(height: 6),
            Sparkline(
              values: recap.series,
              color: spec.color(context),
              low: spec.low,
              high: spec.high,
              width: 96,
              height: 24,
            ),
          ],
        ],
      ),
    );
  }

  Widget _changeLabel(ColorScheme scheme) {
    final pct = recap.changePct;
    if (pct == null) {
      return Text(
        'no prior week',
        style: TextStyle(fontSize: 9.5, color: scheme.onSurfaceVariant),
      );
    }
    // Neutral: the arrow shows direction only, never colored good/bad.
    final flat = pct.abs() < 0.5;
    final arrow = flat ? '→' : (pct > 0 ? '↑' : '↓');
    final weight = recap.spec.key == 'weight';
    final magnitude = weight
        ? '${recap.changeAbs!.abs().toStringAsFixed(1)} ${recap.spec.unit}'
        : '${pct.abs().toStringAsFixed(0)}%';
    return Text(
      flat ? 'about the same' : '$arrow $magnitude vs last week',
      style: TextStyle(
        fontSize: 9.5,
        fontWeight: FontWeight.w600,
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}
