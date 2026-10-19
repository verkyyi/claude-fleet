package api

import (
	"log"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
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
	if err := s.Store.SetEntryJump(host, w.ns, w.at); err != nil {
		log.Printf("fleet: record jump readiness for %s: %v", host, err)
	}
}

func (s *Server) jumpWordOf(host string, now time.Time) (jumpWord, bool) {
	namespace, at, err := s.Store.EntryJump(host)
	if err != nil {
		log.Printf("fleet: read jump readiness for %s: %v", host, err)
		return jumpWord{}, false
	}
	word := jumpWord{at: at, ns: namespace}
	return word, !at.IsZero() && now.Sub(at) < jumpFresh
}

// jumpTarget is the pod's sshd inside the cluster when the door and the pod
// both said lately they are ready for the jump, else "".
func (s *Server) jumpTarget(pod, door string, now time.Time) string {
	target, _ := s.jumpTargetWhy(pod, door, now)
	return target
}

// jumpTargetWhy is jumpTarget with the one condition that is missing when
// there is no target (claude-fleet#4317: a probe that saw no jump could not
// tell which end had not said so).
func (s *Server) jumpTargetWhy(pod, door string, now time.Time) (string, string) {
	if !isUserPodName(pod) {
		return "", "not a person's pod"
	}
	dw, ok := s.jumpWordOf(door, now)
	switch {
	case dw.at.IsZero():
		return "", "the door " + door + " never said it is ready (GET entry-routes?jump=1&ns=…)"
	case !ok:
		return "", "the door " + door + " last said it is ready at " + dw.at.UTC().Format(time.RFC3339)
	case dw.ns == "":
		return "", "the door " + door + " named no namespace"
	}
	pw, ok := s.jumpWordOf(pod, now)
	switch {
	case pw.at.IsZero():
		return "", "the pod never said it is ready (GET entry-keys?jump=1)"
	case !ok:
		return "", "the pod last said it is ready at " + pw.at.UTC().Format(time.RFC3339)
	}
	return strings.ToLower(firstLabel(pod)) + "." + dw.ns + ".svc.cluster.local", ""
}

// jumpWhy is each pod's last reason for no jump, so a route list read every
// few seconds logs a pod only when its reason changes.
var jumpWhy sync.Map // pod → string ("" = the jump is offered)

// noteJumpWhy logs pod's reason for no jump (why "" = offered, to target)
// when it differs from the last one this replica logged.
func noteJumpWhy(pod, door, target, why string) {
	if prev, loaded := jumpWhy.Swap(pod, why); loaded && prev == why {
		return
	}
	if why == "" {
		log.Printf("fleet: door jump to %s offered via %s (%s)", pod, door, target)
	} else {
		log.Printf("fleet: door jump to %s not offered: %s", pod, why)
	}
}

// withJump fills a pod's entry routes for the jump, and the pod's own host
// keys beside them: door is the machine whose address they are, own the pod's
// own host keys. Unchanged unless the door and the pod both said they are
// ready and the pod's keys are known.
func (s *Server) withJump(m FleetMachine, door string, own []string, now time.Time) FleetMachine {
	target, why := s.jumpTargetWhy(m.Hostname, door, now)
	if why == "" && len(own) == 0 {
		why = "the pod's own host keys are not known (no heartbeat with host_keys)"
	}
	noteJumpWhy(m.Hostname, door, target, why)
	if why != "" {
		return m
	}
	out := make([]FleetRoute, len(m.Routes))
	for i, r := range m.Routes {
		if r.Name == "entry" || strings.HasPrefix(r.Name, "entry-") {
			r.Jump, r.Target, r.TargetPort = doorJumpUser, target, 22
		}
		out[i] = r
	}
	m.Routes = out
	m.TargetHostKeys = append([]string(nil), own...)
	return m
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
