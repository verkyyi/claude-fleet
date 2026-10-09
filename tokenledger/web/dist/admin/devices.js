// web/dist/admin/devices.js — All devices, at /admin/devices
// (claude-fleet#2515): every person's registered devices with their owner and
// revoke — what Devices & SSH showed an admin before their own page became
// their own. /v1/admin/devices; the table is lib/devices-view.js.
import { Shell } from '../app-shell.js';
import { esc } from '../lib/shell.js';
import { devicesPanel, wireRevoke } from '../lib/devices-view.js';
import { t } from '../lib/i18n.js';

Shell.mount('all-devices', async (ctx) => {
  const devs = await ctx.api('/v1/admin/devices');
  ctx.el.innerHTML = `<div class="pagehead"><div><p>${esc(t('ui.dev.allLead'))}</p></div></div>` + devicesPanel(devs, true);
  ctx.setCount('all-devices', ((devs && devs.devices) || []).length);
  wireRevoke(ctx);
});
