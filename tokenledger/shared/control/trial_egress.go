package control

// TrialEgressNodePath is GET with a machine's token (claude-fleet WACK C3): the
// way out a trial login on that machine is held to — the hub's
// fleet.trial.egress (off | log | block) and the logins on it a trial person
// holds. The machine loads them into its pf anchor `fleet-trial`
// (bin/fleet_trial_egress.py); off ⇒ no login is named.
const TrialEgressNodePath = "/v1/node/trial-egress"

// TrialEgress is TrialEgressNodePath's answer.
type TrialEgress struct {
	Mode   string   `json:"mode"`
	Logins []string `json:"logins"`
}
