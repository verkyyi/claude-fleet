// web/dist/admin/devices.js — what All devices (/admin/devices,
// claude-fleet#2515) left behind: the page moved into 服务节点与客户端 as its
// 客户端 tab, /nodes?tab=clients (claude-fleet#3232). An old link or bookmark
// still loads this module; it only starts the shell, which moves the address
// there (lib/router.js MOVED) and draws admin/nodes.js.
import { Shell } from '../app-shell.js';

export default Shell.start();
