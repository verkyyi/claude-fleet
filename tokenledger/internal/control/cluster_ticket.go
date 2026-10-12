package control

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

// The cluster provisioner's signed ticket (claude-fleet#3558, EPIC #3500 C16).
//
// In a cluster ONE service may write to Kubernetes: fleet-provisioner, which
// never talks to the hub — fleet-ops (read-only) hands it what the hub sent.
// It runs an op only on a ticket the hub signed with its account-op key (the
// admin seat's key, C15 — one key for every account op, here and on a
// machine) under its own domain, so an account ticket can never stand in for
// a cluster one or the other way round. The fields are typed per op: a person's
// pod by its u-<nonce> name and limits, a Job by the pod it serves and one
// commit — never a manifest; the provisioner renders the fixed template and
// the cluster's admission policy holds it to that template. Single-use (the
// nonce is spent in the provisioner's book), short-lived. The verifier that
// acts is bin/fleet_cluster_ticket.py; this is its Go twin, and the test pins
// one ticket both make byte for byte.

// The provisioner's four ops.
const (
	ClusterCreateUserPod  = "create-user-pod"
	ClusterDestroyUserPod = "destroy-user-pod"
	ClusterSetLimits      = "set-limits"
	ClusterCreateJob      = "create-job"
)

// ClusterTicketTTL: an op is run within seconds of its send; a re-ask signs a
// fresh ticket under a fresh nonce.
const ClusterTicketTTL = 5 * time.Minute

const (
	clusterTicketPrefix = "c1."
	clusterTicketDomain = "fleet-cluster-ticket-v1\x00"
)

// ClusterTicket is what the hub signs for one provisioner op. The field order
// is the encoding (bin/fleet_cluster_ticket.py ORDER).
type ClusterTicket struct {
	Op      string `json:"op"`
	Cluster string `json:"cluster"`
	Pod     string `json:"pod,omitempty"`
	Limits  string `json:"limits,omitempty"`
	Repo    string `json:"repo,omitempty"`
	Ref     string `json:"ref,omitempty"`
	Nonce   string `json:"nonce"`
	Exp     int64  `json:"exp"`
}

// SignClusterTicket is `c1.<payload>.<sig>`, both base64url (no padding).
func SignClusterTicket(key ed25519.PrivateKey, t ClusterTicket) (string, error) {
	if len(key) != ed25519.PrivateKeySize {
		return "", errors.New("no account key")
	}
	switch t.Op {
	case ClusterCreateUserPod, ClusterDestroyUserPod, ClusterSetLimits, ClusterCreateJob:
	default:
		return "", errors.New("not a provisioner op: " + t.Op)
	}
	payload, err := json.Marshal(t)
	if err != nil {
		return "", err
	}
	sig := ed25519.Sign(key, append([]byte(clusterTicketDomain), payload...))
	enc := base64.RawURLEncoding
	return clusterTicketPrefix + enc.EncodeToString(payload) + "." + enc.EncodeToString(sig), nil
}

// VerifyClusterTicket checks a ticket's signature and expiry and returns it;
// the provisioner still matches the cluster, the op's exact field set and
// spends the nonce.
func VerifyClusterTicket(pub ed25519.PublicKey, s string, now time.Time) (ClusterTicket, error) {
	var t ClusterTicket
	rest, ok := strings.CutPrefix(s, clusterTicketPrefix)
	if !ok {
		return t, errors.New("not a c1 cluster ticket")
	}
	p64, s64, ok := strings.Cut(rest, ".")
	if !ok {
		return t, errors.New("malformed cluster ticket")
	}
	enc := base64.RawURLEncoding
	payload, err1 := enc.DecodeString(p64)
	sig, err2 := enc.DecodeString(s64)
	if err1 != nil || err2 != nil || len(pub) != ed25519.PublicKeySize {
		return t, errors.New("malformed cluster ticket")
	}
	if !ed25519.Verify(pub, append([]byte(clusterTicketDomain), payload...), sig) {
		return t, errors.New("cluster ticket: bad signature")
	}
	if err := json.Unmarshal(payload, &t); err != nil {
		return t, errors.New("malformed cluster ticket")
	}
	if t.Nonce == "" || t.Op == "" || t.Cluster == "" {
		return t, errors.New("cluster ticket: missing field")
	}
	if now.Unix() >= t.Exp {
		return t, errors.New("cluster ticket: expired")
	}
	return t, nil
}
