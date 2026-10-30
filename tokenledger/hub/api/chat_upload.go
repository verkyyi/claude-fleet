package api

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// 附件 (task GXR5): a file the person sends with a line goes up BY ITSELF, to
// the login the line is for, before the line is said — never inside a turn's
// JSON, whose bound (chatBodyMax) is a sentence and four pictures.
//
//	browser ──POST /v1/chat/upload?worker=<id> | ?target=personal──▶ hub
//	        body: the file's bytes · X-Fleet-File-Name: its name (URI-encoded)
//	hub ──dialChatRelay──▶ that login's /api/upload → {ref, name, size}
//
// The line then names it {ref, name} in its files (say: at most chatSayFiles);
// the service hands the agent its path. worker= is a session's login (a say),
// target=personal the person's home (a new session's first line).

const (
	chatUploadRoute = "upload"
	// chatUploadMax bounds one file (the service's UPLOAD_MAX).
	chatUploadMax = 20 << 20
	// chatUploadPerPerson / chatUploadPerMinute: one person's uploads, in their own line.
	chatUploadPerPerson = 3
	chatUploadPerMinute = 30
	// chatUploadWait: 20 MiB at the relay's 1 MiB/s, with room.
	chatUploadWait = 3 * time.Minute
	// chatSayFiles is how many files one say names (the service's FILES_PER_TURN).
	chatSayFiles = 5
)

func (s *Server) handleChatUpload(w http.ResponseWriter, r *http.Request) {
	name := chatUploadRoute
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		httpError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	person, status, code, msg := s.termPerson(r)
	if code != "" {
		if status == http.StatusUnauthorized {
			w.Header().Set("WWW-Authenticate", `Bearer realm="ccquota"`)
		}
		s.chatRefuse(w, person, name, status, code, msg)
		return
	}
	if r.Header.Get("X-Fleet-Webchat") != "1" {
		s.chatRefuse(w, person, name, http.StatusForbidden, "forbidden", "X-Fleet-Webchat: 1 is required")
		return
	}
	fname := r.Header.Get("X-Fleet-File-Name")
	if strings.TrimSpace(fname) == "" || len(fname) > 1024 {
		s.chatRefuse(w, person, name, http.StatusBadRequest, "bad_name", "X-Fleet-File-Name: the file's name")
		return
	}
	if r.ContentLength > chatUploadMax {
		s.chatRefuse(w, person, name, http.StatusRequestEntityTooLarge, "too_large", "文件太大：一个最多 20 MB · at most 20 MB a file")
		return
	}
	home, ok, err := s.Store.EntryHomeOf(person)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !ok {
		home = store.EntryHome{}
	}
	home.Person = person
	wid, _, dest, status, code, msg := s.termTarget(r.URL.Query(), home)
	if code == "" && dest.Machine == "" {
		status, code, msg = http.StatusConflict, "no_home", s.noHomeWhy(person)
	}
	if code != "" {
		s.chatRefuse(w, person, name, status, code, msg)
		return
	}
	where := dest.Machine + "/" + dest.Login
	s.awaitChatLink(r, dest.Machine, dest.Login, s.chatLinkWait())
	if peer, ok := s.chatRelayPeer(r, dest.Machine, dest.Login); ok {
		s.proxyRelay(w, r, peer, "a chat upload to "+where)
		return
	}
	if settings, err := s.Store.FleetSettings(); err == nil {
		if _, flagged := maintenanceOf(dest.Machine, settings); flagged {
			s.chatRefuse(w, person, name+" "+where, http.StatusServiceUnavailable, "home_down", "这台机器在维护中，现在连不上")
			return
		}
	}
	gateKey := person + "\x00upload"
	if why := s.chatGate.admit(gateKey, chatUploadPerPerson, chatUploadPerMinute, time.Now()); why != "" {
		s.chatRefuse(w, person, name, http.StatusTooManyRequests, why, "too many uploads; wait a moment")
		return
	}
	defer s.chatGate.release(gateKey)

	one := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return s.dialChatRelay(ctx, person, dest.Machine, dest.Login)
		},
		DisableKeepAlives:  true,
		DisableCompression: true,
	}
	defer one.CloseIdleConnections()
	ctx, cancel := context.WithTimeout(r.Context(), chatUploadWait)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "http://webchat/api/upload", http.MaxBytesReader(w, r.Body, chatUploadMax))
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	req.ContentLength = r.ContentLength
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("X-Fleet-Webchat", "1")
	req.Header.Set("X-Fleet-File-Name", fname)
	req.Header.Set(control.ChatPersonHeader, person)
	resp, err := one.RoundTrip(req)
	if err != nil {
		var mbe *http.MaxBytesError
		var re *sshRelayError
		switch {
		case errors.As(err, &mbe):
			s.chatRefuse(w, person, name, http.StatusRequestEntityTooLarge, "too_large", "文件太大：一个最多 20 MB · at most 20 MB a file")
		case errors.As(err, &re) && re.code == "TOO_MANY":
			s.chatRefuse(w, person, name+" "+where, http.StatusTooManyRequests, "too_many", re.msg)
		case r.Context().Err() != nil:
			// the page went away mid-file
		default:
			s.chatRefuse(w, person, name+" "+where, http.StatusServiceUnavailable, "home_down", "这台机器现在连不上")
		}
		return
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	// a service from before this step has no such route
	if resp.StatusCode == http.StatusNotFound && !strings.Contains(string(out), `"code"`) {
		s.chatRefuse(w, person, name+" "+where, http.StatusConflict, "old_service",
			"这台机器的网页对话服务还旧，发不了文件；更新后就能")
		return
	}
	s.chatAudit(person, "chat_relay", "UPLOAD "+wid+" "+where+" "+resp.Status)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(out)
}
