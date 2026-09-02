// web/dist/lib/fold.js — hourly series → local weekday × hour grid. No DOM.
const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const zeros = () => Array.from({ length: 7 }, () => new Array(24).fill(0));

// tzOffset(ms) → minutes east of UTC at that instant. The default asks the
// runtime, so DST is handled per hour rather than assumed constant.
const localOffset = (ms) => -new Date(ms).getTimezoneOffset();

export function foldHourly(series, tzOffset = localOffset) {
  const grid = zeros(), events = zeros();
  let total = 0;
  for (const s of series || []) {
    const utc = Date.parse(s.key.length === 16 ? s.key + ':00Z' : s.key);
    if (!Number.isFinite(utc)) continue;
    const local = new Date(utc + tzOffset(utc) * 60000);
    const dow = local.getUTCDay(), hour = local.getUTCHours();
    grid[dow][hour] += s.tokens || 0;
    events[dow][hour] += s.events || 0;
    total += s.tokens || 0;
  }
  return { grid, events, total };
}

export function busiest(grid) {
  let best = { dow: 0, hour: 0, tokens: -1 };
  grid.forEach((row, dow) => row.forEach((t, hour) => { if (t > best.tokens) best = { dow, hour, tokens: t }; }));
  return best;
}

// quietest finds the lowest-token window of `hours` consecutive hours on the
// 24-hour profile summed over the week, wrapping past midnight.
export function quietest(grid, hours = 4) {
  const profile = new Array(24).fill(0);
  for (const row of grid) row.forEach((t, h) => { profile[h] += t; });
  let best = { startHour: 0, endHour: hours % 24, tokens: Infinity };
  for (let s = 0; s < 24; s++) {
    let sum = 0;
    for (let k = 0; k < hours; k++) sum += profile[(s + k) % 24];
    if (sum < best.tokens) best = { startHour: s, endHour: (s + hours) % 24, tokens: sum };
  }
  return best;
}

const hh = (h) => String(h).padStart(2, '0') + ':00';

export function sentence(grid) {
  const b = busiest(grid);
  if (b.tokens <= 0) return 'No usage in this period.';
  const q = quietest(grid, 4);
  return `busiest hour: ${DAYS[b.dow]} ${hh(b.hour)} local. Quietest 4-hour window: ${hh(q.startHour)}–${hh(q.endHour)}.`;
}
