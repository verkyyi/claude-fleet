package api

import (
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// The door lets jumps through (claude-fleet#4193, design #4181 A2).
//
// The door's sshd has one fixed account, doorJumpUser: no shell, no session,
// and each key it knows may open ONE tunnel — to its owner's own pod, port 22
// (bin/fleet-door-keys.py). The real login happens once, on the pod's own sshd,
// with the person's own key: the door holds no key into any pod on this road.
//
// Both ends say they are ready on the pull they already make, and the hub
// offers the road only while both said so lately:
//   - the door: GET EntryRoutesNodePath?jump=1&ns=<namespace> — its jump
//     account is configured, and the pods are <svc>.<ns>.svc.cluster.local;
//   - the pod: GET EntryKeysNodePath?jump=1 — its sshd takes the keys it pulls.
// Then a pod's entry routes carry Jump / Target / TargetHostKeys (the pod's
// own host keys, never TOFU) and a new client goes `ssh -J`; an older client
// reads the route as before. Neither said so = byte for byte as before.

// doorJumpUser is the door's one jump account (baked into the door image).
const doorJumpUser = "fleet-jump"

// jumpFresh is how long a door's or a pod's word lasts (a var for tests): the
// door pulls every 15 s, a pod every minute, and on a hub with replicas each
// replica hears a share of them.
var jumpFresh = 10 * time.Minute

var jumpNamespaceRE = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)

type jumpWord struct {
	at time.Time
	ns string // the door's: its pods' namespace
}

// noteJump keeps host's word from a pull that asked ?jump=1.
func (s *Server) noteJump(r *http.Request, host string, door bool, now time.Time) {
	q := r.URL.Query()
	if q.Get("jump") != "1" {
		return
	}
	w := jumpWord{at: now}
	if door {
		ns := q.Get("ns")
		if !jumpNamespaceRE.MatchString(ns) {
			return
		}
		w.ns = ns
	}
	s.jumpSeen.Store(strings.ToLower(host), w)
}

func (s *Server) jumpWordOf(host string, now time.Time) (jumpWord, bool) {
	v, ok := s.jumpSeen.Load(strings.ToLower(host))
	if !ok {
		return jumpWord{}, false
	}
	w := v.(jumpWord)
	return w, now.Sub(w.at) < jumpFresh
}

// jumpTarget is the pod's sshd inside the cluster when the door and the pod
// both said lately they are ready for the jump, else "".
func (s *Server) jumpTarget(pod, door string, now time.Time) string {
	dw, ok := s.jumpWordOf(door, now)
	if !ok || dw.ns == "" || !isUserPodName(pod) {
		return ""
	}
	if _, ok := s.jumpWordOf(pod, now); !ok {
		return ""
	}
	return strings.ToLower(firstLabel(pod)) + "." + dw.ns + ".svc.cluster.local"
}

// withJump fills a pod's entry routes for the jump: door is the machine whose
// address they are, own the pod's own host keys. Unchanged unless the door
// and the pod both said they are ready and the pod's keys are known.
func (s *Server) withJump(routes []FleetRoute, pod, door string, own []string, now time.Time) []FleetRoute {
	target := s.jumpTarget(pod, door, now)
	if len(own) == 0 || target == "" {
		return routes
	}
	out := make([]FleetRoute, len(routes))
	for i, r := range routes {
		if r.Name == "entry" || strings.HasPrefix(r.Name, "entry-") {
			r.Jump, r.Target, r.TargetPort = doorJumpUser, target, 22
			r.TargetHostKeys = append([]string(nil), own...)
		}
		out[i] = r
	}
	return out
}

// entryJumpLine is the one line a phone or a bare ssh copies (the keys page):
// through the door's jump account at host:port to target, as login.
func entryJumpLine(host string, port int, login, target string) string {
	if host == "" || login == "" || target == "" {
		return ""
	}
	if strings.Contains(host, ":") {
		host = "[" + host + "]"
	}
	if port != 0 && port != 22 {
		host += ":" + strconv.Itoa(port)
	}
	return "ssh -J " + doorJumpUser + "@" + host + " " + login + "@" + target
}
