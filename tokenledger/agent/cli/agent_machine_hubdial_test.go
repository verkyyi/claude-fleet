package cli

import "testing"

// FLEET_HUB_INTERNAL_URL (claude-fleet#4175): only a Service's cluster-local
// name is dialled in the hub's place; anything else is the hub URL, as before.
func TestHubDialURL(t *testing.T) {
	for in, want := range map[string]string{
		"": "",
		"http://ccquota-hub.new-deploy.svc.cluster.local":      "http://ccquota-hub.new-deploy.svc.cluster.local",
		"http://ccquota-hub.new-deploy.svc.cluster.local/":     "http://ccquota-hub.new-deploy.svc.cluster.local",
		"https://ccquota-hub.new-deploy.svc.cluster.local:443": "https://ccquota-hub.new-deploy.svc.cluster.local:443",
		"http://hub.example":                        "",
		"http://ccquota-hub.svc.cluster.local":      "",
		"http://a.b.svc.cluster.local.evil.example": "",
		"http://a.b.svc.cluster.local/v1":           "",
		"ftp://a.b.svc.cluster.local":               "",
	} {
		if got := hubDialURL(in); got != want {
			t.Errorf("hubDialURL(%q) = %q, want %q", in, got, want)
		}
	}
}
