// Unit tests for the pure scoring functions behind AI-assisted reschedule
// suggestions. No server, no database — these are plain functions.
'use strict';

const assert = require('node:assert');
const { urgencyTag, patientFit, clinicFit, rankCandidates } = require('../reschedule');

function check(condition, message) {
  assert.ok(condition, message);
  console.log(`ok - ${message}`);
}

// --- urgencyTag ---
check(urgencyTag('Severe allergic reaction', false) === 'urgent',
  'a "severe" reason is tagged urgent');
check(urgencyTag('Routine checkup', false) === 'routine',
  'a plain checkup is tagged routine');
check(urgencyTag('Routine checkup', true) === 'elevated',
  'a chronic condition bumps an otherwise-routine reason to elevated');
check(urgencyTag(null, false) === 'routine',
  'a missing reason defaults to routine, not a crash');

// --- patientFit ---
const now = new Date('2026-09-18T00:00:00');
const sameTimeNextWeek = patientFit({
  originalStartsAt: '2026-09-18 10:00',
  candidateStartsAt: '2026-09-25 10:00',
  tag: 'routine',
  now,
});
const differentTimeNextWeek = patientFit({
  originalStartsAt: '2026-09-18 10:00',
  candidateStartsAt: '2026-09-25 16:00',
  tag: 'routine',
  now,
});
check(sameTimeNextWeek > differentTimeNextWeek,
  'a candidate at the same time-of-day scores higher than one at a different time');

const urgentCase = patientFit({
  originalStartsAt: '2026-09-18 10:00',
  candidateStartsAt: '2026-09-25 10:00',
  tag: 'urgent',
  now,
});
check(urgentCase > sameTimeNextWeek,
  'an urgent tag scores the same slot higher than a routine one');

// --- clinicFit ---
const fillsGap = clinicFit({
  candidateStartsAt: '2026-09-25 10:30',
  sameDayBookedTimes: ['10:00', '11:00'],
  slotMinutes: 30,
  typicalDailyLoad: 0,
});
const fragmentsDay = clinicFit({
  candidateStartsAt: '2026-09-25 15:00',
  sameDayBookedTimes: ['10:00', '11:00'],
  slotMinutes: 30,
  typicalDailyLoad: 0,
});
check(fillsGap > fragmentsDay,
  'a slot adjacent to an existing booking scores higher than an isolated one');

const overloadedDay = clinicFit({
  candidateStartsAt: '2026-09-25 15:00',
  sameDayBookedTimes: ['09:00', '10:00', '11:00', '13:00', '14:00'],
  slotMinutes: 30,
  typicalDailyLoad: 3,
});
check(overloadedDay < fragmentsDay,
  'piling onto a day already above its typical load scores lower');

// --- rankCandidates ---
const ranked = rankCandidates({
  originalStartsAt: '2026-09-18 10:00',
  candidates: ['2026-09-25 10:00', '2026-09-25 15:00', '2026-10-02 10:00'],
  tag: 'routine',
  sameDayBookedTimesByDate: { '2026-09-25': ['10:30'], '2026-10-02': [] },
  slotMinutes: 30,
  typicalDailyLoad: 0,
  now,
  limit: 5,
});
check(ranked.length === 3, 'rankCandidates returns every candidate when under the limit');
check(ranked[0].startsAt === '2026-09-25 10:00',
  'the closest-time, soonest, gap-adjacent candidate ranks first');
check(ranked.every((r) => typeof r.total === 'number'), 'every ranked candidate carries a total score');
check(ranked[0].total >= ranked[1].total && ranked[1].total >= ranked[2].total,
  'results are sorted best-first');

const limited = rankCandidates({
  originalStartsAt: '2026-09-18 10:00',
  candidates: ['2026-09-25 10:00', '2026-09-25 15:00', '2026-10-02 10:00'],
  tag: 'routine',
  sameDayBookedTimesByDate: {},
  slotMinutes: 30,
  typicalDailyLoad: 0,
  now,
  limit: 2,
});
check(limited.length === 2, 'rankCandidates respects the limit');

console.log('All reschedule-scoring tests passed.');
