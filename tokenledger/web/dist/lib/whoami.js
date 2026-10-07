// web/dist/lib/whoami.js — what the page header says about the viewer
// (claude-fleet#1467), as a decision over /v1/me. No DOM: whoami.js draws it.
//
// One decision for every human page, so the header is the same header on
// the dashboard, 连接, 我的会话, 机器节点 and 凭据发放. The shape: the name,
// with how they got in under it; a popover with 姓名 / 登录方式; 退出 only when
// there is a cookie of this hub's to clear.
//
// `me` is the /v1/me body, or null when it could not be read -- which draws
// nothing. A header that guesses who you are is worse than none.

/** STRINGS are the header's words, by the page's lang. The standalone pages
 *  are zh-CN; the dashboard switches with its own toggle (lib/i18n.js). */
export const STRINGS = Object.freeze({
  'zh-CN': Object.freeze({
    admin: '管理员', token: '令牌',
    github: 'GitHub', roleAdmin: '管理员', roleUser: '使用者',
    name: '姓名', via: '登录方式', logout: '退出', title: '当前用户 / 退出',
  }),
  en: Object.freeze({
    admin: 'Operator', token: 'token',
    github: 'GitHub', roleAdmin: 'Admin', roleUser: 'User',
    name: 'Name', via: 'Signed in via', logout: 'Sign out', title: 'Who am I / sign out',
  }),
});

/** strings picks the dictionary for a lang, zh-CN when unknown. */
export const strings = (lang) => STRINGS[lang] || STRINGS['zh-CN'];

/** whoami decides the header:
 *    null                                      → draw nothing
 *    { name, sub, person, via, logout }        → the name (bold), what goes
 *                                                under it, the popover rows,
 *                                                whether 退出 is offered
 *
 *  - no answer / an open hub (--no-auth)       → nothing: there is no one
 *  - a GitHub person (claude-fleet#1984)       → their username, Admin/User ·
 *                                                GitHub under it, 退出
 *  - the viewer token                          → 管理员 · 令牌, 退出 when the
 *                                                token is parked in a cookie */
export function whoami(me, lang = 'zh-CN') {
  if (!me || typeof me !== 'object') return null;
  const s = strings(lang);
  switch (me.via) {
    case 'github': {
      const name = String(me.name || '').trim();
      if (!name) return null;
      const role = me.role === 'admin' ? s.roleAdmin : s.roleUser;
      return { name, sub: `${role} · ${s.github}`, person: '', via: s.github, logout: !!me.can_logout };
    }
    case 'token':
      return { name: s.admin, sub: s.token, person: '', via: s.token, logout: !!me.can_logout };
    default:
      return null;
  }
}
