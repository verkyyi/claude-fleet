package api

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/fleetid"
)

// A DeepSeek session from the web (task J7BN): /v1/chat/open with a model.
//
// Without one, a web session opens on the person's HOME (the home's
// /api/open, fleet_chat.go) — and a home is overseas, where DeepSeek's
// sessions must not run: they belong to the mainland region (fleet_region.go).
// So an open naming deepseek | deepseek-pro is never relayed home: the hub
// places it itself, through the client's own place (clientPlace — pickNode
// with provider deepseek, which only a cn machine takes, then worker_start to
// that node) as a no-repo scratch of agent claude, model fixed, the person's
// first words its seed, the reap the node's default for a new session (as a
// web session's). The answer is /v1/chat/open's own shape — fid, worker,
// state — so the page lands on the session as it does on one from home; the
// unified worker road (chat_worker.go, chat_view.go, termTarget) reaches a
// session on any of the person's logins.
//
// Refusals: a model that is neither 400 model; not on fleet.region_cn.people
// 403 region_not_allowed; no cn cluster listed, or no cn machine of the
// person's that can take it, 503 no_region_machine.

// chatRegionWait is how long the open waits for the chosen node's start.
var chatRegionWait = newDurKnob(25 * time.Second)

// chatOpenModels are the models the web may ask for, as the page shows them.
var chatOpenModels = []ChatModel{{ID: "deepseek", Label: "DeepSeek"}, {ID: "deepseek-pro", Label: "DeepSeek Pro"}}

// ChatModel is one model choice the new-session page may offer.
type ChatModel struct {
	ID    string `json:"id"`
	Label string `json:"label"`
}

// chatModelsFor is what /v1/chat/home offers person: DeepSeek's models while a
// cn cluster is listed and person is on fleet.region_cn.people (or it is *);
// nil — the key absent — otherwise.
func (s *Server) chatModelsFor(person string) []ChatModel {
	if person == "" || s.Store == nil {
		return nil
	}
	settings, err := s.Store.FleetSettings()
	if err != nil || !cnListed(settings) || regionStartWhy(settings, person, credvault.DeepSeek) != "" {
		return nil
	}
	return chatOpenModels
}

// chatOpenModel peeks at an open's body for its model, leaving the body as it
// was for the relay: "" (none — byte for byte the home's open) or the model
// as written. ok false: the body was refused here.
func (s *Server) chatOpenModel(w http.ResponseWriter, r *http.Request, person string) (model string, body map[string]json.RawMessage, ok bool) {
	if r.Body == nil {
		return "", nil, true
	}
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, chatBodyMax))
	_ = r.Body.Close()
	if err != nil {
		s.chatRefuse(w, person, "open", http.StatusRequestEntityTooLarge, "too_large", "消息太大 · message too large")
		return "", nil, false
	}
	r.Body = io.NopCloser(bytes.NewReader(raw))
	r.ContentLength = int64(len(raw))
	if json.Unmarshal(raw, &body) != nil || body == nil {
		return "", nil, true // the home's open says what is wrong with it
	}
	v, has := body["model"]
	if !has || string(v) == "null" {
		return "", body, true
	}
	if json.Unmarshal(v, &model) != nil {
		s.chatRefuse(w, person, "open", http.StatusBadRequest, "model", "model must be deepseek or deepseek-pro")
		return "", nil, false
	}
	return model, body, true
}

// chatOpenRegion places a model's open (see above) and answers it.
func (s *Server) chatOpenRegion(w http.ResponseWriter, r *http.Request, person, model string, body map[string]json.RawMessage) {
	agent := ""
	if v := body["agent"]; len(v) != 0 && string(v) != "null" {
		_ = json.Unmarshal(v, &agent)
	}
	if agent == "" {
		agent = credvault.Claude // a DeepSeek model is a Claude Code session
	}
	m, why := checkStartModel(model, agent)
	if why != "" || m == "" || (agent != credvault.Claude) {
		if why == "" {
			why = "model must be deepseek or deepseek-pro"
		}
		s.chatRefuse(w, person, "open", http.StatusBadRequest, "model", why)
		return
	}
	if v := body["images"]; len(v) != 0 && string(v) != "null" && string(v) != "[]" {
		s.chatRefuse(w, person, "open", http.StatusBadRequest, "images", "图片还不能随 DeepSeek 会话的第一句一起发 · images cannot go with a DeepSeek session's first line yet")
		return
	}
	text := ""
	if v := body["text"]; len(v) != 0 && string(v) != "null" {
		if json.Unmarshal(v, &text) != nil {
			s.chatRefuse(w, person, "open", http.StatusBadRequest, "bad_body", "text is a string")
			return
		}
	}
	text = strings.TrimSpace(text)
	settings, err := s.Store.FleetSettings()
	if err != nil {
		s.chatRefuse(w, person, "open", http.StatusServiceUnavailable, "no_region_machine", "暂时无法开始会话，请稍后再试。")
		return
	}
	if !cnListed(settings) {
		s.chatRefuse(w, person, "open "+m, http.StatusServiceUnavailable, "no_region_machine", "DeepSeek 会话只在大陆区开，现在没有大陆区 · DeepSeek runs in the mainland region, and none is listed")
		return
	}
	if why := regionStartWhy(settings, person, credvault.DeepSeek); why != "" {
		s.chatRefuse(w, person, "open "+m, http.StatusForbidden, "region_not_allowed", "DeepSeek 会话还在试用，你不在名单上 · "+why)
		return
	}
	// The person's chat bounds, as on the home's road.
	max, perMin := s.ChatMaxPerPerson, s.ChatPerMinute
	if max == 0 {
		max = defaultChatPerPerson
	}
	if perMin == 0 {
		perMin = defaultChatPerMinute
	}
	if why := s.chatGate.admit(person, max, perMin, time.Now()); why != "" {
		s.chatRefuse(w, person, "open", http.StatusTooManyRequests, why, "too many chat requests; wait a moment")
		return
	}
	defer s.chatGate.release(person)
	// A trial's lines (claude-fleet#4059) count here as on the home's road.
	code, msg, counted := s.trialTurn(w, person, time.Now())
	if code != "" {
		s.chatRefuse(w, person, "open", http.StatusForbidden, code, msg)
		return
	}
	var once sync.Once
	refund := func(why string) {
		if counted {
			once.Do(func() { s.trialRefund(person, why) })
		}
	}
	scope, err := s.scopeFor(person)
	if err != nil {
		refund("scope: " + err.Error())
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	p := fleetPrincipal{Actor: person, Person: person, scope: scope}
	idem := "web-open-" + randomTag()
	req := clientPlaceRequest{Kind: "scratch", NoRepo: true, Agent: credvault.Claude, Model: m, Body: text, Idem: idem, Node: "auto"}
	rec := httptest.NewRecorder()
	now := time.Now()
	s.clientPlace(rec, r, p, "web:"+person, idem, req, chatRegionWait.Get(), now)
	var out ClientPlaceResponse
	if rec.Code != http.StatusOK || json.Unmarshal(rec.Body.Bytes(), &out) != nil {
		refund("the place was refused")
		msg := strings.TrimSpace(rec.Body.String())
		var e struct {
			Error struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		if json.Unmarshal(rec.Body.Bytes(), &e) == nil && e.Error.Message != "" {
			msg = e.Error.Message
		}
		st := rec.Code
		if st == http.StatusOK {
			st = http.StatusBadGateway
		}
		s.chatRefuse(w, person, "open "+m, st, "open_failed", msg)
		return
	}
	_, line, _ := strings.Cut(out.Line, "\t")
	switch out.State {
	case "done", "pending":
	case "refused":
		refund("no region machine")
		if out.Exit == 4 {
			s.chatRefuse(w, person, "open "+m, http.StatusServiceUnavailable, "no_region_machine",
				"现在没有能开 DeepSeek 会话的大陆区机器 · no mainland machine can take a DeepSeek session now: "+line)
			return
		}
		fallthrough
	default:
		refund("the start did not open")
		s.chatAudit(person, "chat_open_region", "REFUSED "+m+" "+out.Machine+" "+out.OperationID)
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"state": "refused", "reason": "open_failed",
			"code": "open_failed", "error": "没能开一个新会话 · " + line})
		return
	}
	ans := map[string]any{"agent": credvault.Claude, "model": m, "delivery": randomUUIDish(), "state": "sent",
		"machine": out.Machine, "login": out.Login, "operation_id": out.OperationID}
	if out.State == "done" {
		if out.WorkerID != "" {
			ans["worker"] = out.WorkerID
		}
		if fid := s.openedFID(out); fid != "" {
			ans["fid"] = fid
		}
	} else {
		ans["state"] = "pending" // the node has it and has not answered yet
	}
	s.trialNextDayLine(person, time.Now())
	s.chatAudit(person, "chat_open_region", "OPENED "+m+" "+out.Machine+"/"+out.Login+" "+out.OperationID)
	writeJSON(w, http.StatusOK, ans)
}

// openedFID is the opened window's identity (@fleet_id): the node's result
// row's "identity", else the worker id's second half when that is one.
func (s *Server) openedFID(out ClientPlaceResponse) string {
	if o, err := s.Store.FleetOperation(out.OperationID); err == nil && o.Result != "" {
		var res struct {
			Workers []struct {
				Identity string `json:"identity"`
				FleetID  string `json:"fleet_id"`
			} `json:"workers"`
		}
		if json.Unmarshal([]byte(o.Result), &res) == nil && len(res.Workers) > 0 {
			for _, id := range []string{res.Workers[0].FleetID, res.Workers[0].Identity} {
				if fleetid.IsUUID(id) {
					return id
				}
			}
		}
	}
	if _, second, err := fleetid.ParseWorkerID(out.WorkerID); err == nil && fleetid.IsUUID(second) {
		return second
	}
	return ""
}

// randomTag is 16 random hex digits.
func randomTag() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// randomUUIDish is a random v4-shaped id (the home's delivery id's form).
func randomUUIDish() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	b[6], b[8] = b[6]&0x0f|0x40, b[8]&0x3f|0x80
	h := hex.EncodeToString(b)
	return h[:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:]
}
