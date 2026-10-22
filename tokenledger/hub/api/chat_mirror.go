package api

import (
	"bytes"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"slices"
	"strings"
	"time"
)

// The person's conversation, a copy beside the entry (task V9DJ D). The entry
// is in China, the person's home often is not: a read that has to cross to
// the home and back took seconds, and showed nothing while the home was out of
// reach. Every conversation read that reaches the home leaves a copy here —
// sealed to that person (credvault SealPerson, the key derived for them from
// the vault's, which is not in the database) — and the page shows the copy
// first (GET /v1/chat/conversation?cached=1), marked 同步中, until the home's
// answers. The home stays the record: its answer replaces the copy, every time.
//
// What the copy holds: the person's words, the reply's text and each tool
// step's one line — never a tool's output (code, secrets). An image (task
// T773) is kept as its small preview only (thumb, chatMirrorThumbMax in all,
// the newest first), never its bytes and never the name the home serves it by. Only the person
// reads it: a view-as read is refused, an admin reads only their own. Kept
// chatMirrorKeep after the last read that reached the home, then deleted.
// The person's switch (PUT /v1/chat/mirror {"on":false}) deletes it and keeps
// none. No vault ⇒ no copy, every read as before. A trial's conversation is
// never copied (it is kept apart for 24 hours, claude-fleet#4060).

const (
	chatMirrorPurpose = "chat-mirror"
	chatMirrorRoute   = "mirror"
	// chatMirrorKeep is how long a copy stays without a fresh read.
	chatMirrorKeep = 90 * 24 * time.Hour
	// chatMirrorMax bounds the conversation body the entry reads to copy.
	chatMirrorMax = 4 << 20
	// chatMirrorThumbMax bounds the image previews one copy keeps (task T773).
	chatMirrorThumbMax = 2 << 20
	// chatMirrorThumbOne bounds one preview; a larger one is not kept.
	chatMirrorThumbOne = 32 << 10
)

// chatMirrorPic keeps an image's size and its preview (when it fits *left).
func chatMirrorPic(g map[string]any, left *int) map[string]any {
	out := map[string]any{}
	for _, k := range []string{"w", "h", "big"} {
		if v, ok := g[k]; ok {
			out[k] = v
		}
	}
	if th, ok := g["thumb"].(string); ok && strings.HasPrefix(th, "data:image/jpeg;base64,") && len(th) <= chatMirrorThumbOne && len(th) <= *left {
		out["thumb"] = th
		*left -= len(th)
	}
	return out
}

// chatMirrorDoc is what a copy holds.
type chatMirrorDoc struct {
	Session string            `json:"session,omitempty"`
	Cwd     string            `json:"cwd,omitempty"`
	Models  json.RawMessage   `json:"models,omitempty"`
	Default string            `json:"default,omitempty"`
	Items   []json.RawMessage `json:"items"`
}

// chatMirrorItem keeps what a copy may hold of one item; left is what the
// copy may still spend on previews (the items are walked newest first).
func chatMirrorItem(raw json.RawMessage, left *int) (json.RawMessage, bool) {
	var it map[string]any
	if json.Unmarshal(raw, &it) != nil {
		return nil, false
	}
	switch it["t"] {
	case "user":
		if pics, ok := it["images"].([]any); ok {
			kept := []any{}
			for _, p := range pics {
				if g, ok := p.(map[string]any); ok {
					kept = append(kept, chatMirrorPic(g, left))
				}
			}
			it["images"] = kept
		}
	case "image":
		id, hasID := it["id"]
		it = chatMirrorPic(it, left)
		it["t"] = "image"
		if hasID {
			it["id"] = id
		}
	case "image_more":
		it = map[string]any{"t": "image_more", "n": it["n"]}
	case "page":
		// a web page's card (task T773 ④): its title, link and state — not its preview
		kept := map[string]any{"t": "page"}
		for _, k := range []string{"id", "title", "url", "status", "proposal", "version", "note"} {
			if v, ok := it[k]; ok {
				kept[k] = v
			}
		}
		it = kept
	case "text", "stopped", "error", "note": // note: a background task's notice, one line (claude-fleet WD8F)
	case "tool":
		delete(it, "input")
	case "tool_result":
		// the step's result is shown from the home's answer; the copy keeps
		// only that there was one, and whether it failed
		it = map[string]any{"t": "tool_result", "id": it["id"], "error": it["error"]}
	default:
		return nil, false
	}
	b, err := json.Marshal(it)
	return b, err == nil
}

// chatMirrorOn says whether person's conversation is copied.
func (s *Server) chatMirrorOn(person string) bool {
	if s.Vault == nil || s.Store == nil || s.trialPerson(person) {
		return false
	}
	off, err := s.Store.ChatMirrorOff(person)
	return err == nil && !off
}

// chatMirrorKeepBody copies a home's conversation answer for person.
func (s *Server) chatMirrorKeepBody(person, provider string, body []byte, now time.Time) {
	var in struct {
		Session string            `json:"session"`
		Cwd     string            `json:"cwd"`
		Models  json.RawMessage   `json:"models"`
		Default string            `json:"default"`
		Items   []json.RawMessage `json:"items"`
	}
	if json.Unmarshal(body, &in) != nil {
		return
	}
	doc := chatMirrorDoc{Session: in.Session, Cwd: in.Cwd, Models: in.Models, Default: in.Default, Items: []json.RawMessage{}}
	left := chatMirrorThumbMax
	for i := len(in.Items) - 1; i >= 0; i-- {
		if it, ok := chatMirrorItem(in.Items[i], &left); ok {
			doc.Items = append(doc.Items, it)
		}
	}
	slices.Reverse(doc.Items)
	sealed, err := s.Vault.SealPerson(doc, person, chatMirrorPurpose)
	if err != nil {
		log.Printf("fleet: chat copy of %s: seal: %v", person, err)
		return
	}
	if err := s.Store.PutChatMirrorOf(person, provider, sealed, now.Add(chatMirrorKeep), now); err != nil {
		log.Printf("fleet: chat copy of %s: keep: %v", person, err)
	}
}

// chatMirrorTee reads a conversation answer through to the page and, once it
// is whole, copies it.
type chatMirrorTee struct {
	io.ReadCloser
	buf  bytes.Buffer
	over bool
	done func([]byte)
}

func (t *chatMirrorTee) Read(p []byte) (int, error) {
	n, err := t.ReadCloser.Read(p)
	if n > 0 && !t.over {
		if t.buf.Len()+n > chatMirrorMax {
			t.over = true
			t.buf.Reset()
		} else {
			t.buf.Write(p[:n])
		}
	}
	if err == io.EOF && !t.over && t.done != nil {
		d := t.done
		t.done = nil
		d(t.buf.Bytes())
	}
	return n, err
}

// handleChatCached answers GET /v1/chat/conversation?cached=1: the person's
// copy, marked as one — or, with none to give (the copy off, not written yet,
// or sealed under a key that moved on), 200 with no items and "mirror": null
// (task J091): a first visit is no error, the page just waits for the home.
func (s *Server) handleChatCached(w http.ResponseWriter, r *http.Request, person, provider string) {
	if viewAsAsked(r) != "" {
		s.chatRefuse(w, person, "conversation cached", http.StatusForbidden, "not_yours", "only your own conversation")
		return
	}
	if !s.chatMirrorOn(person) {
		chatNoCopy(w)
		return
	}
	c, err := s.Store.ChatMirrorOf(person, provider, time.Now())
	if err != nil || c == nil {
		chatNoCopy(w)
		return
	}
	var doc chatMirrorDoc
	if err := s.Vault.OpenPerson(c.Sealed, &doc, person, chatMirrorPurpose); err != nil {
		// a vault key that moved on: the next read from the home writes it again
		chatNoCopy(w)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"session": doc.Session, "cwd": doc.Cwd, "models": doc.Models, "default": doc.Default,
		"items": doc.Items, "busy": false, "asks": []any{},
		"mirror": map[string]any{"at": c.UpdatedAt.UTC().Format(time.RFC3339)},
	})
}

// chatNoCopy is the cached read with no copy to give.
func chatNoCopy(w http.ResponseWriter) {
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"items": []any{}, "mirror": nil})
}

// ChatMirrorState is GET /v1/chat/mirror's answer.
type ChatMirrorState struct {
	Available bool   `json:"available"`
	On        bool   `json:"on"`
	At        string `json:"at,omitempty"`
}

// handleChatMirror serves the person's switch: GET its state, PUT {"on":bool}.
func (s *Server) handleChatMirror(w http.ResponseWriter, r *http.Request) {
	person, status, code, msg := s.chatPerson(r)
	if code != "" {
		s.chatRefuse(w, person, chatMirrorRoute, status, code, msg)
		return
	}
	if viewAsAsked(r) != "" {
		s.chatRefuse(w, person, chatMirrorRoute, http.StatusForbidden, "not_yours", "only your own conversation")
		return
	}
	switch r.Method {
	case http.MethodGet:
	case http.MethodPut:
		if r.Header.Get("X-Fleet-Webchat") != "1" {
			s.chatRefuse(w, person, chatMirrorRoute, http.StatusForbidden, "forbidden", "X-Fleet-Webchat: 1 is required")
			return
		}
		var in struct {
			On *bool `json:"on"`
		}
		if err := json.NewDecoder(io.LimitReader(r.Body, 1024)).Decode(&in); err != nil || in.On == nil {
			httpError(w, http.StatusBadRequest, `{"on": true|false} expected`)
			return
		}
		if err := s.Store.SetChatMirrorOff(person, !*in.On, time.Now()); err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		s.chatAudit(person, "chat_mirror", map[bool]string{true: "ON", false: "OFF (copy deleted)"}[*in.On])
	default:
		w.Header().Set("Allow", "GET, PUT")
		httpError(w, http.StatusMethodNotAllowed, "GET or PUT")
		return
	}
	out := ChatMirrorState{Available: s.Vault != nil && !s.trialPerson(person)}
	if out.Available {
		out.On = s.chatMirrorOn(person)
		if c, err := s.Store.ChatMirror(person, time.Now()); err == nil && c != nil && out.On {
			out.At = c.UpdatedAt.UTC().Format(time.RFC3339)
		}
	}
	writeJSON(w, http.StatusOK, out)
}
