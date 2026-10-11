package api

import (
	"os"
	"testing"
	"time"
)

func TestZZDumpEntrySteps(t *testing.T) {
	h := entryHarness(t)
	_ = h.srv.Store.SetFleetSetting(EntryDomainKey, "cf.24haowan.com", time.Now())
	save := func(name, q string) {
		_, body, _ := keysPage(t, h, pAlice, q, nil)
		_ = os.WriteFile("/tmp/keys-3199/"+name+".html", []byte(body), 0o644)
	}
	_ = h.srv.Store.SetFleetSetting(EntryKey, "off", time.Now())
	save("00-off", "")
	_ = h.srv.Store.SetFleetSetting(EntryKey, "on", time.Now())
	save("01-step1", "")
	save("02-step2", "?step=2")
	save("03-step3", "?step=3")
	save("04a-step4-name", "?step=4")
	keysPost(t, h, pAlice, "do", "name", "name", "alice")
	keysPost(t, h, pAlice, "do", "add", "key", entryKeyLine(t, "x"), "label", "iPhone")
	save("04b-step4", "?ok=added")
	save("05a-step5-opening", "?step=5")
	home, _, _ := h.srv.Store.EntryHomeOf(pAlice)
	dnsReach(t, h, home.Machine, time.Now().UTC(), true, "23.119.126.213")
	save("05b-step5-ok", "?step=5")
	save("06-step6", "?step=6")
	save("07-done", "?step=done")
}
