// web/dist/lib/sessions.js — 我的会话 (claude-fleet#1429), as data.
//
// The phone page answers two questions away from the desk: where is each of
// my sessions, and is any of them waiting for me. Everything comes from
// /v1/fleet/fleet_sessions (every window of every fleet the hub lets this
// viewer see) and /v1/fleet/me (who the viewer is). Pure — no DOM, no fetch;
// sessions.html draws what this returns.
//
// Two rules this file exists to hold:
//
//   - Only the viewer's own. The hub already scopes fleet_sessions (a WeCom
//     person sees only their ACTIVE (machine, login) accounts — claude-fleet
//     #1411), and the page filters again by the same accounts from
//     /v1/fleet/me. Belt and braces: a page that showed a colleague's session
//     because one server-side scope regressed is the failure this guards.
//     The operator's doors (no principal) are scoped by the hub alone.
//   - A lost machine is 失联, never idle. Its windows are the last heartbeat's
//     list: the session may well still be running, so the row keeps its last
//     known state, greyed, with how long ago it was seen.

/** STATES maps the fleet's @claude_state to the label a person reads. */
export const STATES = {
  working: '工作中',
  idle: '空闲',
  waiting: '等你回答',
  blocked: '被卡住',
  done: '已完成',
  unknown: '未知',
};

/** NEEDS_YOU are the states where the session cannot go on without a person. */
export const NEEDS_YOU = new Set(['waiting', 'blocked']);

/** ageText says how long ago, in the page's language. */
export function ageText(secs) {
  if (secs == null || !Number.isFinite(secs) || secs < 0) return '';
  if (secs < 90) return `${Math.max(1, Math.round(secs))} 秒前`;
  if (secs < 5400) return `${Math.round(secs / 60)} 分钟前`;
  if (secs < 129600) return `${Math.round(secs / 3600)} 小时前`;
  return `${Math.round(secs / 86400)} 天前`;
}

/** mine keeps the sessions on the viewer's own (machine, login) accounts.
 *  me is /v1/fleet/me's body: principal null = the operator's door, which the
 *  hub has already scoped; a person keeps only their ACTIVE accounts. A person
 *  with no active account sees nothing — never everything. */
export function mine(sessions, me) {
  const list = Array.isArray(sessions) ? sessions : [];
  if (!me || !me.principal) return list;
  const own = new Set((me.accounts || [])
    .filter((a) => a.state === 'active')
    .map((a) => `${a.hostname}\u0000${a.login}`));
  return list.filter((s) => own.has(`${s.machine_name}\u0000${s.os_user}`));
}

/** sessionView turns one fleet_sessions row into what a card shows. */
export function sessionView(s) {
  const w = s.worker || {};
  const state = w.state || 'unknown';
  // 维护中 (#1427) is still heard — its sessions are live, only new work
  // stays away. Everything else that is not online is 失联: the hub's `lost`,
  // and any word this page does not know (a newer hub, an empty field).
  const maint = s.availability === 'maintenance';
  const lost = !maint && s.availability !== 'online';
  const title = w.name
    || (w.issue ? `#${w.issue}` : (w.scratch ? '临时会话' : (w.key || '会话')));
  const meta = [];
  if (w.issue && w.name) meta.push(`#${w.issue}`);
  if (w.repo) meta.push(w.repo);
  if (w.agent) meta.push(w.agent);
  return {
    key: s.worker_id || `${s.fleet_id}/${w.key || w.window_id || ''}`,
    title,
    meta: meta.join(' · '),
    machine: s.machine_name,
    login: s.os_user,
    fleet: s.fleet_name,
    state,
    stateText: STATES[state] || state,
    // A lost machine's "waiting" is the last thing it said, not a live ask:
    // the badge stays, the card does not claim the top of the list.
    needsYou: !lost && NEEDS_YOU.has(state),
    lost,
    lostText: lost ? `失联${s.age_sec != null ? ' · 最后见到 ' + ageText(s.age_sec) : ''}` : (maint ? '维护中' : ''),
    maint,
    asleep: w.lifecycle && w.lifecycle !== 'awake' ? w.lifecycle : '',
  };
}

const RANK = { waiting: 0, blocked: 1, working: 2, idle: 3, unknown: 4, done: 5 };

/** byMachine groups the viewer's sessions per machine: machines in name order,
 *  a lost machine flagged once on its heading; inside one, the sessions that
 *  need the viewer first, then by state, then by title. */
export function byMachine(sessions, me) {
  const groups = new Map();
  for (const s of mine(sessions, me)) {
    const v = sessionView(s);
    if (!groups.has(v.machine)) groups.set(v.machine, { machine: v.machine, lost: true, lostText: '', sessions: [] });
    const g = groups.get(v.machine);
    g.sessions.push(v);
    // One online login makes the machine reachable; the heading only says
    // 失联 when every login on it is.
    if (!v.lost) { g.lost = false; g.lostText = v.maint ? v.lostText : ''; } else if (g.lost && !g.lostText) g.lostText = v.lostText;
  }
  const out = [...groups.values()].sort((a, b) => a.machine.localeCompare(b.machine));
  for (const g of out) {
    g.sessions.sort((a, b) => (b.needsYou - a.needsYou)
      || ((RANK[a.state] ?? 9) - (RANK[b.state] ?? 9))
      || a.title.localeCompare(b.title));
  }
  return out;
}

/** summary is the one line on top: how many, how many need you, how many lost. */
export function summary(groups) {
  let total = 0, needs = 0, lost = 0;
  for (const g of groups) {
    for (const v of g.sessions) {
      total++;
      if (v.needsYou) needs++;
      if (v.lost) lost++;
    }
  }
  return { total, needs, lost, machines: groups.length };
}
