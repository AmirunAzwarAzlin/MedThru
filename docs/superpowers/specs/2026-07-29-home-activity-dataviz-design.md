# Home "Your Activity" data-viz block — design

**Date:** 2026-07-29
**Status:** Approved for planning
**Area:** Patient app — Home tab (`app/lib/screens/patient/`)

## Goal

Make the patient app feel more lively and engaging by turning the health data
it already collects into something worth coming back to look at. The engagement
comes from data visualization, not from streaks, gamification pressure, or a
character/mascot.

Two new widgets on the patient Home tab, grouped as a single "Your activity"
block placed near the top (right after the identity card, above the vitals
snapshot and appointment calendar):

1. A **weekly recap stat card** — a compact mini-dashboard of the patient's most
   active metrics, each with a value, a week-over-week change, and a sparkline.
2. A **consistency heatmap** — a GitHub-style contribution grid of daily logging
   activity over the last ~12–16 weeks.

## Non-goals

- No streaks, streak counters, or "you broke it" messaging (explicitly rejected:
  too punishing for irregular health logging).
- No mascot / character reactions (the existing `cat.png` is untouched and plays
  no part here).
- No new backend endpoints or server-side aggregation. Everything is computed
  client-side from data the Home tab already fetches.
- Not a replacement for the existing single-series `TrendChart` on the Health
  Records screens; this is a glanceable summary, those remain the detail view.

## Data source

Both widgets derive entirely from the patient's readings list, already loaded on
the Home tab as `_readings` (`MedThruApi.instance.getReadings(patientId)`), where
each reading carries a `taken_at` timestamp and a `type` key. No additional fetch
is introduced; the widgets consume the same `Future<List<Map<String,dynamic>>>`.

Reading types available (from `readings.dart`): `blood_sugar`, `cholesterol`,
`uric_acid`, `blood_pressure_systolic`, `blood_pressure_diastolic`, `heart_rate`,
`temperature`, `weight`, `height`. Each `ReadingType` already provides unit,
per-mode colors, decimals, and a typical reference range (`low`/`high`).

## Component 1 — Weekly recap stat card

A card summarizing the last 7 days of readings as up to **3 stat tiles**.

**Tile selection.** Rank the patient's reading types by recent activity (number
of readings in the last ~14 days, tie-broken by most recent). Take the top 3 that
have enough data to compute a value. `height` is excluded (not a tracked trend);
if `weight` and `height` both exist, weight is the anthropometry representative.

**Each tile shows:**
- Metric label (e.g. "Blood sugar") and latest value with unit, using the
  `ReadingType`'s existing formatting (decimals, unit, per-mode color).
- Week-over-week change: this week's mean vs. the previous 7 days' mean, shown as
  a direction arrow + magnitude (percentage for most, absolute delta for weight).
  Omitted when the previous week has no data to compare against.
- A **sparkline**: an axis-free, label-free line of the metric's recent points
  (reuse the daily-aggregation math already in `trend_chart.dart` /
  `aggregateDaily`, rendered small — roughly 40–56px wide, no gridlines, no
  labels). Shows shape and direction, not exact values.

**Tone and color.** Neutral and factual — "Blood sugar ↓ 6%", never "Great job!".
A change direction is not framed as good/bad (a drop in glucose is not
universally good). Coloring follows the app's existing in/out-of-range convention
(is the latest value inside the `ReadingType` range?), not green-up/red-down. This
matches how `readings.dart` already frames ranges as informational, not a
diagnosis.

**Insufficient-data fallback.** If no metric has at least 2 readings in the last
14 days (nothing to draw a value or a sparkline from), the card collapses to a
single friendly line: "Log a few more readings to unlock your weekly recap." A
tile renders for a metric with ≥2 readings even when the prior week is empty — in
that case the value and sparkline show and only the change indicator is omitted.
No empty tiles or "N/A" values are shown.

**"Moments" (optional, low priority).** When trivially true from the same data, a
single one-line highlight may appear under the tiles, e.g. "Lowest weight in 30
days" or "Most days logged in a month." Purely additive; skipped when nothing
qualifies. Can be deferred if it complicates the first cut.

## Component 2 — Consistency heatmap

A GitHub-style contribution grid of daily logging activity.

**Layout.** Columns are weeks (Monday-first, matching the appointment calendar's
week convention), rows are the 7 weekdays; ~12–16 weeks shown ending at the
current week. Small rounded cells, sized to fit the 640-wide centered column the
Home tab already uses.

**Intensity.** Each cell is colored by that day's reading count:
- 0 readings → empty (outline / faint surface).
- 1 → light accent.
- 2–3 → medium accent.
- 4+ → full accent.

Uses the app accent (`MedThruTheme.blue`) at graded opacities so it reads as one
scale. A small "less → more" legend sits beneath the grid.

**Interaction.** Tapping a populated cell reveals a single line below the grid,
"14 Jul — 3 readings", mirroring the tap-to-reveal pattern in
`appointment_calendar.dart`. Tapping again clears it. Empty cells are inert.

**Empty state.** Before meaningful history accrues, the grid still renders (mostly
empty cells) with a gentle caption: "Your logging history will fill in here."

## Data flow

```
_readings (Future<List<Map>>, already on Home tab)
  │
  ├─► group by day (taken_at → yyyy-mm-dd, count) ──► Heatmap intensities
  │
  └─► group by type + week window ──► per-metric {latest, thisWeekMean,
                                        lastWeekMean, dailyPoints} ──► Stat tiles
```

Both widgets take the readings list (or a small pre-computed summary struct) as
input and are pure given that input — no internal fetching, so they can be unit
tested against fixture lists. A shared, testable pure function turns the raw
readings list into the summary both widgets render from.

## Files (anticipated)

- New: `app/lib/screens/patient/activity_recap.dart` — the stat card + tile +
  sparkline painter.
- New: `app/lib/screens/patient/consistency_heatmap.dart` — the grid card.
- Possibly new: a small pure helper (in one of the above, or a shared file) that
  reduces `List<reading>` → the summary structs, kept separate from widgets so
  it's unit-testable.
- Edit: `app/lib/screens/patient/patient_screen.dart` — insert the "Your
  activity" block into `_HomeTab` near the top, fed by the existing `_readings`
  future via a `FutureBuilder` (same pattern as the vitals snapshot).

## Error handling

- Readings fetch already fails soft on the Home tab; the block simply renders its
  empty/insufficient-data states when readings are absent or the future errors —
  never a hard error surface for what is a supplementary glance widget.
- Malformed/unparseable `taken_at` values are skipped (same defensive parsing as
  `appointment_calendar.dart` uses for `starts_at`).

## Testing

- Pure summary function: unit tests over fixture reading lists — empty list, one
  reading, multi-type, week-over-week change math, out-of-range detection,
  day-count bucketing into intensity levels.
- Widget-level: golden/smoke tests optional; not gating given the app's
  momentum-over-verification preference.

## Reusables

- `aggregateDaily` / daily bucketing from `trend_chart.dart`.
- `ReadingType` metadata (unit, color, range, decimals) from `readings.dart`.
- Tap-to-reveal + Monday-first week layout patterns from
  `appointment_calendar.dart`.
- `MedThruTheme` accent/muted colors.
