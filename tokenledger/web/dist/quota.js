// web/dist/quota.js — what 我的额度 (/quota, claude-fleet#2517) left behind:
// the page moved into 我的用量 (/usage, claude-fleet#3229) — a person sees
// their own limit there, never the pool's windows. An old link or bookmark
// still loads this module; it only starts the shell, which moves the address
// there (lib/router.js MOVED) and draws usage.js.
import { Shell } from './app-shell.js';

export default Shell.start();
