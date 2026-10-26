package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/release"
)

var healthAddress = regexp.MustCompile(`[A-Za-z0-9][.][A-Za-z0-9]`)

const HealthPath = "/v1/health"

// Only fixed display identifiers cross the API. URLs and upstream responses
// never enter the status tables, including the administrator's response.
var healthComponents = []string{"claudefleet", "ccquota", "tokenman", "core", "wechat", "workbench", "notify", "releases"}

func healthKnown(k string) bool {
	for _, v := range healthComponents {
		if k == v {
			return true
		}
	}
	return false
}
func healthAdmin(r *http.Request) bool {
	x := roleOf(r.Context())
	return x == roleAdmin || x == roleOperator
}

func (s *Server) RunHealth(ctx context.Context) {
	tick := time.NewTicker(time.Minute)
	defer tick.Stop()
	for {
		if s.Elector == nil || s.Elector.Leader(ctx, "health") {
			s.probeHealth(ctx, time.Now())
		}
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}
func healthHTTP(ctx context.Context, target string) error {
	req, e := http.NewRequestWithContext(ctx, "GET", target, nil)
	if e != nil {
		return errors.New("request")
	}
	// Redirects must not turn an auth wall or another service into a green check.
	client := &http.Client{Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	r, e := client.Do(req)
	if e != nil {
		return errors.New("unreachable")
	}
	defer r.Body.Close()
	if r.StatusCode != 200 {
		return errors.New("status")
	}
	return nil
}

// Reuse the deployment's registered entry hosts and notifier. Overrides
// are useful for self-hosters and tests; no environment address enters JSON.
func (s *Server) healthTargets() map[string]string {
	targets := map[string]string{}
	hosts := map[string]bool{}
	for h := range s.PublicHosts {
		hosts[h] = true
	}
	for h := range s.SiteHosts {
		hosts[h] = true
	}
	for _, h := range s.ForwardedHosts {
		if !strings.Contains(h, "*") {
			hosts[h] = true
		}
	}
	ordered := []string{}
	for h := range hosts {
		ordered = append(ordered, h)
	}
	sort.Strings(ordered)
	for _, h := range ordered {
		switch {
		case strings.HasPrefix(h, "claudefleet."):
			targets["claudefleet"] = "https://" + h + "/healthz"
		case strings.HasPrefix(h, "ccquota."):
			targets["ccquota"] = "https://" + h + "/healthz"
		case h == "tokenman.io":
			targets["tokenman"] = "https://" + h + "/healthz"
		}
	}
	if u, e := url.Parse(s.FleetPublicURL); e == nil && u.Host != "" {
		targets["core"] = u.Scheme + "://" + u.Host + "/healthz"
	}
	if base := strings.TrimRight(os.Getenv("FLEET_NOTIFY_KF_URL"), "/"); base != "" {
		targets["notify"] = base + "/healthz"
	}
	overrides := map[string]string{}
	if json.Unmarshal([]byte(os.Getenv("CCQUOTA_HEALTH_TARGETS")), &overrides) == nil {
		for k, v := range overrides {
			if healthKnown(k) {
				targets[k] = v
			}
		}
	}
	return targets
}

func (s *Server) probeHealth(ctx context.Context, now time.Time) {
	targets := s.healthTargets()
	for _, k := range healthComponents {
		state := "unconfigured"
		start := time.Now()
		var err error
		c, cancel := context.WithTimeout(ctx, 8*time.Second)
		switch k {
		case "wechat":
			if s.WxGW.ready() {
				state = "ok"
				// Unpublished temporary QR: no browser cookie, scene row, scan, account
				// or notification. Use the same token and signing path as real login.
				_, err = s.WxGW.qrCreate(c, wxHealthScene, time.Minute)
			}
		case "workbench":
			if s.WxGW.ready() {
				state = "ok"
				var out map[string]any
				var code int
				code, err = s.WxGW.internal(c, "/token?appid="+s.WxGW.appID(), &out)
				if code != 200 || out["access_token"] == nil {
					err = errors.New("unavailable")
				}
			}
		case "releases":
			if s.Releases != nil {
				state = "ok"
				sha := s.Releases.StableSHA()
				if sha == "" {
					err = errors.New("empty")
				} else {
					dir := s.Releases.dir(sha)
					if dir == "" {
						err = errors.New("missing")
					} else {
						_, err = os.ReadFile(filepath.Join(dir, release.ManifestName))
					}
				}
			}
		default:
			if target := targets[k]; target != "" {
				state = "ok"
				err = healthHTTP(c, target)
			}
		}
		cancel()
		if err != nil {
			state = "failed"
		}
		p := store.HealthProbe{Component: k, At: now.Truncate(time.Minute).UnixMilli(), State: state, MS: time.Since(start).Milliseconds()}
		created, e := s.Store.RecordHealthProbe(p, 3)
		if e == nil && created {
			s.notify("Service health: " + k + " failed 3 consecutive probes. /app/health")
		}
	}
	_ = s.Store.PruneHealth(now.Add(-8 * 24 * time.Hour))
}

type healthLink struct {
	Label  string  `json:"label"`
	N      int64   `json:"n"`
	Fails  int64   `json:"fails"`
	MeanMS float64 `json:"mean_ms"`
	MaxMS  int64   `json:"max_ms"`
	At     int64   `json:"at"`
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method == http.MethodPost {
		s.annotateHealth(w, r)
		return
	}
	if r.Method != http.MethodGet {
		httpError(w, 405, "GET or POST only")
		return
	}
	now := time.Now()
	admin := healthAdmin(r)
	probes, err := s.Store.HealthProbes(now.Add(-15 * time.Minute))
	if err != nil {
		httpError(w, 503, "Health data unavailable")
		return
	}
	latest := map[string]store.HealthProbe{}
	for _, p := range probes {
		if _, ok := latest[p.Component]; !ok && healthKnown(p.Component) {
			latest[p.Component] = p
		}
	}
	state := "ok"
	failed, entries := 0, 0
	for _, k := range healthComponents {
		p, ok := latest[k]
		if !ok || now.UnixMilli()-p.At > 180000 {
			p = store.HealthProbe{Component: k, State: "unknown"}
			latest[k] = p
		}
		if p.State != "ok" {
			state = "degraded"
		}
		if k == "claudefleet" || k == "ccquota" || k == "tokenman" {
			entries++
			if p.State == "failed" {
				failed++
			}
		}
	}
	if failed == entries {
		state = "outage"
	}
	events, err := s.Store.HealthEvents(now.Add(-7 * 24 * time.Hour))
	if err != nil {
		httpError(w, 503, "Health data unavailable")
		return
	}
	ts, err := s.Store.ChatTimings(now.Add(-7 * 24 * time.Hour))
	if err != nil {
		httpError(w, 503, "Timing data unavailable")
		return
	}
	day := []store.ChatTiming{}
	for _, t := range ts {
		if t.At.After(now.Add(-24 * time.Hour)) {
			day = append(day, t)
		}
	}
	rtts, err := s.Store.LinkRTTs(now.Add(-24 * time.Hour))
	if err != nil {
		httpError(w, 503, "Link data unavailable")
		return
	}
	home, hasHome, err := s.Store.EntryHomeOf(principalOf(r.Context()))
	if err != nil {
		httpError(w, 503, "Home data unavailable")
		return
	}
	links := map[string]*healthLink{}
	order := []string{}
	for _, x := range rtts {
		if !admin && (!hasHome || x.Host != home.Machine) {
			continue
		}
		y := links[x.Host]
		if y == nil {
			label := "home"
			if admin {
				label = "machine-" + strconv.Itoa(len(order)+1)
			}
			y = &healthLink{Label: label}
			links[x.Host] = y
			order = append(order, x.Host)
		}
		y.N += x.N
		y.Fails += x.Fails
		y.MeanMS += float64(x.SumMS)
		if x.MaxMS > y.MaxMS {
			y.MaxMS = x.MaxMS
		}
		if x.Hour*3600000 > y.At {
			y.At = x.Hour * 3600000
		}
	}
	ls := []*healthLink{}
	for _, k := range order {
		y := links[k]
		if y.N > y.Fails {
			y.MeanMS /= float64(y.N - y.Fails)
		}
		ls = append(ls, y)
	}
	language := "zh"
	if s.siteSandbox(r) {
		language = "en"
	}
	out := map[string]any{"language": language, "state": state, "at": now.UnixMilli(), "components": latest, "events": events, "reply_24h": chatSpread(day).Reply, "reply_7d": chatSpread(ts).Reply, "links": ls}
	if admin {
		total, errs := s.httpStats.since(now.Add(-time.Hour))
		db := s.Store.HealthDBStats()
		release := ""
		if s.Releases != nil {
			release = s.Releases.StableSHA()
		}
		trains, e := s.Store.ReleaseTrainsSince(now.Add(-7 * 24 * time.Hour))
		if e != nil {
			httpError(w, 503, "Release data unavailable")
			return
		}
		recent := []map[string]any{}
		for _, v := range trains {
			recent = append(recent, map[string]any{"sha": v.SHA, "at": v.PublishedAt.UnixMilli()})
		}
		stats := chatTimingStatsOf(7, ts)
		out["admin"] = map[string]any{"daily": stats.Daily, "agents": stats.Agents, "probes": probes, "requests_1h_replica": total, "errors_1h_replica": errs, "db_open_replica": db.OpenConnections, "db_in_use_replica": db.InUse, "db_wait_count_replica": db.WaitCount, "rds_cpu": nil, "rds_quota": nil, "release": release, "recent_releases": recent}
	}
	writeJSON(w, 200, out)
}
func (s *Server) annotateHealth(w http.ResponseWriter, r *http.Request) {
	if !healthAdmin(r) {
		httpError(w, 403, "Admin only")
		return
	}
	if r.Header.Get("X-Fleet-Webchat") != "1" || !sameOrigin(r) {
		httpError(w, 403, "Same origin required")
		return
	}
	var in struct {
		ID string `json:"id"`
		ZH string `json:"note_zh"`
		EN string `json:"note_en"`
	}
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&in) != nil || len(in.ZH) > 1000 || len(in.EN) > 1000 {
		httpError(w, 400, "Invalid note")
		return
	}
	// Public incident notes are plain explanatory text, never diagnostic dumps.
	for _, v := range []string{in.ZH, in.EN} {
		if strings.ContainsAny(v, "<>@/\\=") || strings.Contains(strings.ToLower(v), "token") || healthAddress.MatchString(v) {
			httpError(w, 400, "Public explanation only; no addresses or credentials")
			return
		}
	}
	ok, err := s.Store.AnnotateHealthEvent(in.ID, in.ZH, in.EN)
	if err != nil {
		httpError(w, 500, "Could not save note")
		return
	}
	if !ok {
		httpError(w, 404, "Event not found")
		return
	}
	_ = s.Store.HubAudit(viewerOf(r.Context()), "health.note", in.ID, "updated", "public explanation", time.Now())
	writeJSON(w, 200, map[string]bool{"saved": true})
}
