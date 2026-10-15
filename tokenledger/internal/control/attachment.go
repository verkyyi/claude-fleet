package control

import (
	"encoding/json"
	"errors"
	"strings"
	"time"
)

// Attachments carry one service's framed data. Signaling and renewable authority
// stay on the existing authenticated hub/node link; the grant never goes to JS.
const (
	CapAttachment       = "attachment-v1"
	TypeAttachmentOpen  = "attachment_open"
	AttachmentDataPath  = "/v1/node/attachment"
	AttachmentLease     = 15 * time.Second
	AttachmentNegotiate = 8 * time.Second
	AttachmentSignalMax = 32 << 10
)

type AttachmentOpen struct {
	RelayID string `json:"relay_id"`
	Secret  string `json:"secret"`
	Login   string `json:"login"`
	Service string `json:"service,omitempty"`
}

// Conn identifies the request, Epoch fences its one selected data path. A fresh
// authorization is required to select relay after negotiation; ready is final.
type AttachmentGrant struct {
	TermResume  string                `json:"term_resume,omitempty"`
	TermTake    bool                  `json:"term_take,omitempty"`
	Chat        ChatAttachmentRequest `json:"chat,omitempty"`
	V           int                   `json:"v"`
	Person      string                `json:"person"`
	Home        string                `json:"home"`
	Login       string                `json:"login"`
	Node        string                `json:"node"`
	Service     string                `json:"service"`
	Target      string                `json:"target"`
	Conn        string                `json:"conn"`
	Previous    string                `json:"previous,omitempty"`
	Generation  string                `json:"generation"`
	Fingerprint string                `json:"fingerprint"`
	Mode        string                `json:"mode"`
	Epoch       uint64                `json:"epoch"`
	Iat         int64                 `json:"iat"`
	Exp         int64                 `json:"exp"`
}

func SignAttachment(g AttachmentGrant, key string) string {
	return signStatement("fba1", g, key)
}

// VerifyAttachment checks the lane and request BEFORE ICE or any target access.
// The generation is minted by the agent for this control-link lifetime, so a
// replacement pod or a reconnected agent cannot accept an old attachment.
func VerifyAttachment(s, key, login, conn, generation string, now time.Time) (AttachmentGrant, error) {
	var g AttachmentGrant
	bad := errors.New("attachment grant refused")
	if len(s) > 8192 {
		return g, bad
	}
	b, err := verifyStatement("fba1", s, key)
	if err != nil {
		return g, bad
	}
	if json.Unmarshal(b, &g) != nil || g.V != 1 || g.Person == "" || g.Home == "" || g.Node == "" ||
		g.Login != login || g.Conn != conn || g.Generation == "" || g.Generation != generation ||
		g.Epoch == 0 || !ValidAttachmentTarget(g.Service, g.Target) ||
		statementWindow(g.Iat, g.Exp, AttachmentLease, now) != "" {
		return g, bad
	}
	if g.Service == "chat" && !g.Chat.Valid(g.Target) {
		return g, bad
	}
	if g.Service != "term" && (g.TermResume != "" || g.TermTake) {
		return g, bad
	}
	if g.Service != "chat" && g.Chat != (ChatAttachmentRequest{}) {
		return g, bad
	}
	if g.Mode != "negotiate" && g.Mode != "direct" && g.Mode != "relay" {
		return g, bad
	}
	if g.Mode != "relay" && !ValidPeerFingerprint(g.Fingerprint) {
		return g, bad
	}
	return g, nil
}

// Chat's fixed route set is shared with its HTTP adapter. It grants one request,
// never an arbitrary URL, socket, port, header or executable. C6 supplies its
// admission and request adapter; the transport itself does not launch chat.
func ValidAttachmentTarget(service, target string) bool {
	switch service {
	case "term":
		return ValidTermTarget(target)
	case "chat":
		switch target {
		case "conversation", "turn", "stop", "answer":
			return true
		}
	}
	return false
}

func ValidPeerFingerprint(s string) bool {
	p := strings.Split(s, ":")
	if len(p) != 32 {
		return false
	}
	for _, b := range p {
		if len(b) != 2 {
			return false
		}
		for _, c := range b {
			if !strings.ContainsRune("0123456789ABCDEF", c) {
				return false
			}
		}
	}
	return true
}

// SameAttachment forbids a lease from changing who, what or which incarnation
// an attachment reaches. Selection may change only mode/epoch (once).
func SameAttachment(a, b AttachmentGrant) bool {
	a.Mode, b.Mode = "", ""
	a.Epoch, b.Epoch = 0, 0
	a.Iat, b.Iat, a.Exp, b.Exp = 0, 0, 0, 0
	return a == b
}

type AttachmentSignal struct {
	Status     int      `json:"status,omitempty"`
	Message    string   `json:"message,omitempty"`
	TrialLeft  string   `json:"trial_left,omitempty"`
	T          string   `json:"t"`
	Grant      string   `json:"grant,omitempty"`
	SDP        string   `json:"sdp,omitempty"`
	STUN       []string `json:"stun,omitempty"`
	Mode       string   `json:"mode,omitempty"`
	Refund     bool     `json:"refund,omitempty"`
	Conn       string   `json:"conn,omitempty"`
	Generation string   `json:"generation,omitempty"`
	Target     string   `json:"target,omitempty"`
	Pair       string   `json:"pair,omitempty"`
	Error      string   `json:"error,omitempty"`
}
