// web/dist/lib/whoami.js — what the page header says about the viewer
// (claude-fleet#1467), as a decision over /v1/me. No DOM: whoami.js draws it.
//
// One decision for every human page, so the header is the same header on
// the dashboard, 连接, 我的会话, 机器节点 and 凭据发放. The shape follows OPS
// (24haowan-monorepo core/ops): the name, with how they got in under it; a
// popover with 姓名 / 企微账号; 退出 only when there is a cookie of this hub's
// to clear.
//
// `me` is the /v1/me body, or null when it could not be read -- which draws
// nothing. A header that guesses who you are is worse than none.

/** STRINGS are the header's words, by the page's lang. The standalone pages
 *  are zh-CN; the dashboard switches with its own toggle (lib/i18n.js). */
export const STRINGS = Object.freeze({
  'zh-CN': Object.freeze({
    wecom: '企业微信', admin: '管理员', token: '令牌', tailnet: '内网',
    name: '姓名', userid: '企微账号', via: '登录方式', logout: '退出', title: '当前用户 / 退出',
  }),
  en: Object.freeze({
    wecom: 'WeCom', admin: 'Operator', token: 'token', tailnet: 'tailnet',
    name: 'Name', userid: 'WeCom userid', via: 'Signed in via', logout: 'Sign out', title: 'Who am I / sign out',
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
 *  - a WeCom person                            → their name, else their userid
 *  - the viewer token                          → 管理员 · 令牌, 退出 when the
 *                                                token is parked in a cookie
 *  - a named tailnet peer                      → their login · 内网, no 退出:
 *                                                there is no cookie to clear */
export function whoami(me, lang = 'zh-CN') {
  if (!me || typeof me !== 'object') return null;
  const s = strings(lang);
  switch (me.via) {
    case 'wecom': {
      const person = String(me.person || '').trim();
      const name = String(me.name || '').trim() || person;
      if (!name) return null;
      return { name, sub: s.wecom, person, via: s.wecom, logout: !!me.can_logout };
    }
    case 'token':
      return { name: s.admin, sub: s.token, person: '', via: s.token, logout: !!me.can_logout };
    case 'tailnet':
      return { name: String(me.login || '').trim() || s.admin, sub: s.tailnet, person: '', via: s.tailnet, logout: false };
    default:
      return null;
  }
}
