import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'theme.dart';

/// Shows a freshly issued card token. This is the only time the raw token is
/// ever visible — the server stores just a hash — so it must be written to the
/// card now. Blocking dialog, deliberately: dismissing it loses the token.
Future<void> showCardTokenDialog(
  BuildContext context, {
  required String token,
  required String patientName,
  bool isReissue = false,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return AlertDialog(
        icon: Icon(Icons.nfc, color: scheme.primary, size: 32),
        title: Text(isReissue ? 'New card issued' : 'Card issued'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isReissue
                  ? 'The old card for $patientName no longer works. Write this '
                      'token to the replacement card now.'
                  : 'Write this token to $patientName\'s blank card now.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: SelectableText(
                token,
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 13, height: 1.4),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.warning_amber_outlined,
                    size: 16, color: scheme.error),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'This token is shown only once and cannot be recovered.',
                    style: TextStyle(fontSize: 12, color: scheme.error),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: token));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Token copied')),
              );
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            style: FilledButton.styleFrom(
                minimumSize: const Size(100, 42)),
            child: const Text('Done'),
          ),
        ],
      );
    },
  );
}

/// How an appointment status should read and colour across the app, so the
/// patient's list, the doctor's queue and confirmation snackbars all agree.
class AppointmentStatusStyle {
  const AppointmentStatusStyle(this.label, this.color, this.icon);
  final String label;
  final Color color;
  final IconData icon;

  static AppointmentStatusStyle of(String status) {
    switch (status) {
      case 'requested':
        return const AppointmentStatusStyle(
            'Awaiting approval', Color(0xFFB88407), Icons.hourglass_top);
      case 'confirmed':
        return const AppointmentStatusStyle(
            'Confirmed', Color(0xFF19A05B), Icons.check_circle_outline);
      case 'completed':
        return const AppointmentStatusStyle(
            'Completed', Color(0xFF1D7FD4), Icons.event_available_outlined);
      case 'rejected':
        return const AppointmentStatusStyle(
            'Rejected', Color(0xFFE0384E), Icons.cancel_outlined);
      case 'cancelled':
        return const AppointmentStatusStyle(
            'Cancelled', Color(0xFF5B6B7F), Icons.event_busy_outlined);
      case 'reschedule_requested':
        return const AppointmentStatusStyle(
            'Reschedule pending', Color(0xFF9C6ADE), Icons.sync_alt);
      default:
        return AppointmentStatusStyle(status, const Color(0xFF5B6B7F), Icons.event);
    }
  }
}

/// A small coloured status pill.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final s = AppointmentStatusStyle.of(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: s.color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(s.icon, size: 14, color: s.color),
          const SizedBox(width: 5),
          Text(s.label,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: s.color)),
        ],
      ),
    );
  }
}

/// A wrap of choice chips for the bookable "HH:MM" times on one day, shared
/// by the booking flow and the reschedule flow.
class SlotGrid extends StatelessWidget {
  const SlotGrid({
    super.key,
    required this.slots,
    required this.selected,
    required this.onSelect,
  });

  final Future<List<String>> slots;
  final String? selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<List<String>>(
      future: slots,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError) {
          return Text(snap.error.toString().replaceFirst('Exception: ', ''),
              style: TextStyle(color: scheme.error));
        }
        final times = snap.data ?? const [];
        if (times.isEmpty) {
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              'No open slots on this day. Try another date.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          );
        }
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final t in times)
              ChoiceChip(
                label: Text(t),
                selected: selected == t,
                onSelected: (_) => onSelect(t),
              ),
          ],
        );
      },
    );
  }
}

/// Formats a stored "YYYY-MM-DD HH:MM" wall-clock string for display, e.g.
/// "Mon 14 Jul 2026, 8:20 AM". Returns the raw value if it can't be parsed.
String formatAppointmentTime(String startsAt) {
  final parsed = DateTime.tryParse(startsAt.replaceFirst(' ', 'T'));
  if (parsed == null) return startsAt;
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final h24 = parsed.hour;
  final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
  final ampm = h24 < 12 ? 'AM' : 'PM';
  final min = parsed.minute.toString().padLeft(2, '0');
  return '${days[parsed.weekday - 1]} ${parsed.day} ${months[parsed.month - 1]} '
      '${parsed.year}, $h12:$min $ampm';
}

/// A labelled read-only field shown on the patient record.
class FieldCard extends StatelessWidget {
  const FieldCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: scheme.primary),
        title: Text(
          label,
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
        subtitle: Text(
          value,
          style: TextStyle(
            fontSize: 16,
            color: scheme.onSurface,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// Full-screen centered state used for empty / error / loading screens.
class CenteredMessage extends StatelessWidget {
  const CenteredMessage({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: 20),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// A colored icon tile for a grid of quick actions — the patient Home tab's
/// visual language (Emergency Info, Health Records, ...), shared here so the
/// doctor/admin side of the app can use the same look for its own actions.
class ActionTile extends StatelessWidget {
  const ActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.tile,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final Color tile;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          height: 124,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isDark ? color.withValues(alpha: 0.18) : tile,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: isDark ? tile : color, size: 24),
              ),
              const SizedBox(height: 10),
              // Long labels wrap to two lines; keep them from overflowing.
              Flexible(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The "who is this" hero header shared by the patient and doctor
/// profile-style screens, so both sides of the app read as one design.
/// A calm dark card with a faint green top-glow and a green-ringed avatar —
/// the quiet resting surface of the "quiet dark" direction. [child], if given,
/// renders below the name/subtitle row — e.g. the patient's blood-type stat,
/// or a doctor's admin badge.
class GradientHeroCard extends StatelessWidget {
  const GradientHeroCard({
    super.key,
    required this.name,
    required this.subtitle,
    this.trailing,
    this.child,
  });

  final String name;
  final String subtitle;
  final Widget? trailing;
  final Widget? child;

  String get _initial => name.isNotEmpty ? name[0].toUpperCase() : '?';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 22),
      decoration: BoxDecoration(
        // A soft green halo at the top fades into the card surface — presence
        // without shouting.
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.alphaBlend(
                MedThruTheme.blue.withValues(alpha: 0.16), scheme.surfaceContainerLow),
            scheme.surfaceContainerLow,
          ],
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(2.5),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: MedThruTheme.blue.withValues(alpha: 0.6), width: 2),
                ),
                child: CircleAvatar(
                  radius: 22,
                  backgroundColor: MedThruTheme.blue.withValues(alpha: 0.18),
                  child: Text(
                    _initial,
                    style: const TextStyle(
                      color: MedThruTheme.blueBright,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          if (child != null) ...[
            const SizedBox(height: 18),
            child!,
          ],
        ],
      ),
    );
  }
}

/// The signature element: an emergency-call band, modelled on the reference
/// design's red action bar. A muted brick-red gradient carrying a single
/// bright-red circular badge and a forward chevron — the one loud thing on an
/// otherwise quiet screen. Tapping it jumps to the emergency essentials.
class EmergencyBand extends StatelessWidget {
  const EmergencyBand({
    super.key,
    required this.onTap,
    this.label = 'Emergency info',
    this.sublabel = 'Blood type, allergies & contacts',
  });

  final VoidCallback onTap;
  final String label;
  final String sublabel;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Ink(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [MedThruTheme.bandRed1, MedThruTheme.bandRed2],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: MedThruTheme.danger.withValues(alpha: 0.45)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                height: 44,
                width: 44,
                decoration: const BoxDecoration(
                  color: MedThruTheme.danger,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.emergency_share_outlined,
                    color: Colors.white, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      sublabel,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.78),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white70),
            ],
          ),
        ),
      ),
    );
  }
}

/// Constrains form/content width so it looks right on wide desktop windows.
class BoundedBody extends StatelessWidget {
  const BoundedBody({super.key, required this.child, this.maxWidth = 460});
  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
