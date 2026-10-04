// Package spottest is a fake Kubernetes pods API for tests: an httptest
// server that keeps pods in memory and lets a test play the cluster — mark a
// pod running, kill it the way a SPOT reclaim does, or make the API refuse.
package spottest

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
)

// Server is the fake API server.
type Server struct {
	*httptest.Server
	mu   sync.Mutex
	pods map[string]map[string]any // name → object
	// Created counts pod creates; Deleted the names deleted, in order.
	Created int
	Deleted []string
	// Refuse, when set, is the HTTP status every request gets (503: the API
	// is down).
	Refuse int
	// Phase is the phase a newly created pod reports (default Pending).
	Phase string
	// LastCreate is the newest object a create carried, as the hub sent it.
	LastCreate map[string]any
}

// New starts the fake on 127.0.0.1.
func New() *Server {
	s := &Server{pods: map[string]map[string]any{}}
	s.Server = httptest.NewServer(http.HandlerFunc(s.serve))
	return s
}

// Pod reads one pod object (nil when absent).
func (s *Server) Pod(name string) map[string]any {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.pods[name]
}

// Names lists the pods present.
func (s *Server) Names() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []string{}
	for n := range s.pods {
		out = append(out, n)
	}
	return out
}

// SetPhase moves a pod to a phase (Running, Failed, Succeeded).
func (s *Server) SetPhase(name, phase string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if p, ok := s.pods[name]; ok {
		p["status"] = map[string]any{"phase": phase}
	}
}

// Vanish removes a pod outright, the way a reclaimed SPOT machine takes its
// pods with it without anyone deleting them.
func (s *Server) Vanish(name string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.pods, name)
}

func (s *Server) serve(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if r.Header.Get("Authorization") == "" {
		http.Error(w, `{"reason":"Unauthorized","message":"no token"}`, http.StatusUnauthorized)
		return
	}
	if s.Refuse != 0 {
		http.Error(w, `{"reason":"ServiceUnavailable","message":"fake refusal"}`, s.Refuse)
		return
	}
	const prefix = "/api/v1/namespaces/"
	if !strings.HasPrefix(r.URL.Path, prefix) {
		http.NotFound(w, r)
		return
	}
	rest := strings.TrimPrefix(r.URL.Path, prefix)
	parts := strings.SplitN(rest, "/", 3) // ns, "pods", name
	if len(parts) < 2 || parts[1] != "pods" {
		http.NotFound(w, r)
		return
	}
	name := ""
	if len(parts) == 3 {
		name = parts[2]
	}
	w.Header().Set("Content-Type", "application/json")
	switch {
	case r.Method == http.MethodPost && name == "":
		var obj map[string]any
		if err := json.NewDecoder(r.Body).Decode(&obj); err != nil {
			http.Error(w, `{"reason":"BadRequest","message":"bad json"}`, http.StatusBadRequest)
			return
		}
		meta, _ := obj["metadata"].(map[string]any)
		n, _ := meta["name"].(string)
		if n == "" {
			http.Error(w, `{"reason":"Invalid","message":"metadata.name required"}`, http.StatusUnprocessableEntity)
			return
		}
		if _, dup := s.pods[n]; dup {
			http.Error(w, `{"reason":"AlreadyExists","message":"pod exists"}`, http.StatusConflict)
			return
		}
		phase := s.Phase
		if phase == "" {
			phase = "Pending"
		}
		obj["status"] = map[string]any{"phase": phase}
		s.pods[n] = obj
		s.Created++
		s.LastCreate = obj
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(obj)
	case r.Method == http.MethodGet && name == "":
		items := []any{}
		sel := r.URL.Query().Get("labelSelector")
		for _, p := range s.pods {
			if sel == "" || matches(p, sel) {
				items = append(items, p)
			}
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"items": items})
	case r.Method == http.MethodGet:
		p, ok := s.pods[name]
		if !ok {
			http.Error(w, `{"reason":"NotFound","message":"pods \"`+name+`\" not found"}`, http.StatusNotFound)
			return
		}
		_ = json.NewEncoder(w).Encode(p)
	case r.Method == http.MethodDelete:
		if _, ok := s.pods[name]; !ok {
			http.Error(w, `{"reason":"NotFound","message":"pods \"`+name+`\" not found"}`, http.StatusNotFound)
			return
		}
		// A real API server keeps the pod (with deletionTimestamp) until
		// the kubelet is done; the fake removes it at once — the controller
		// must cope with either, and the tests exercise both through
		// SetPhase / Vanish.
		delete(s.pods, name)
		s.Deleted = append(s.Deleted, name)
		_ = json.NewEncoder(w).Encode(map[string]any{"status": "Success"})
	default:
		http.Error(w, `{"reason":"MethodNotAllowed","message":""}`, http.StatusMethodNotAllowed)
	}
}

func matches(pod map[string]any, sel string) bool {
	meta, _ := pod["metadata"].(map[string]any)
	labels, _ := meta["labels"].(map[string]any)
	for _, kv := range strings.Split(sel, ",") {
		k, v, _ := strings.Cut(kv, "=")
		if got, _ := labels[k].(string); got != v {
			return false
		}
	}
	return true
}
