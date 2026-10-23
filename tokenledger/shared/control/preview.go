package control

import (
	"encoding/json"
	"errors"
	"regexp"
	"time"
)

const (
	CapPreview      = "preview-uds-v1"
	TypePreviewOpen = "preview_open"
	PreviewDataPath = "/v1/node/preview-data"
)

var previewSocketRE = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_-]{0,39}\.sock$`)

func PreviewSocketName(s string) bool { return previewSocketRE.MatchString(s) }

// The signed first-frame statement binds the target to this relay, login and
// node connection generation. No URL, IP, port or arbitrary pathname exists.
type PreviewHello struct {
	Grant string `json:"grant"`
}

type PreviewGrant struct {
	V          int    `json:"v"`
	Person     string `json:"person"`
	Login      string `json:"login"`
	Node       string `json:"node"`
	Generation string `json:"generation"`
	Relay      string `json:"relay"`
	Preview    string `json:"preview"`
	Socket     string `json:"socket"`
	Iat        int64  `json:"iat"`
	Exp        int64  `json:"exp"`
}

func SignPreview(g PreviewGrant, key string) string { return signStatement("fpv1", g, key) }
func VerifyPreview(s, key, login, relay, generation string, now time.Time) (PreviewGrant, error) {
	var g PreviewGrant
	bad := errors.New("preview grant refused")
	if len(s) > 4096 {
		return g, bad
	}
	b, e := verifyStatement("fpv1", s, key)
	if e != nil {
		return g, bad
	}
	if json.Unmarshal(b, &g) != nil || g.V != 1 || g.Person == "" || g.Node == "" || g.Preview == "" || g.Login != login || g.Relay != relay || g.Generation == "" || g.Generation != generation || !PreviewSocketName(g.Socket) || statementWindow(g.Iat, g.Exp, 30*time.Second, now) != "" {
		return g, bad
	}
	return g, nil
}
