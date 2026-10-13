package store

import (
	"database/sql"
	"errors"
	"time"
)

// The service account's QR codes and where a person can be reached
// (claude-fleet#4054, EPIC #4048 共同约定 4/5). The hub runs as two replicas:
// a code drawn on one is polled on the other, so both live here. Nothing
// secret is stored — the browser's nonce is a hash, the code's own address is
// what WeChat prints on it anyway.

// WxScene is one code the hub drew.
type WxScene struct {
	Scene       int64
	BrowserHash string
	Purpose     string // login | bind | reach
	Owner       string // who a bind / reach code is for; "" for login
	QRURL       string // what the code encodes (WeChat's weixin.qq.com/q/… link)
	CreatedAt   time.Time
	ExpiresAt   time.Time
	ConsumedAt  time.Time // zero until it was traded
}

// ErrWxSceneTaken: the scene number is in use (a random draw collided).
var ErrWxSceneTaken = errors.New("scene in use")

// CreateWxScene records a code drawn; ErrWxSceneTaken when its number is
// another live code's.
func (s *Store) CreateWxScene(c WxScene) error {
	// A number is free again an hour after its code expired.
	_, _ = s.write.Exec(`DELETE FROM hub_wx_scenes WHERE expires_at < ?`, c.CreatedAt.Add(-time.Hour).Unix())
	res, err := s.write.Exec(s.d.insertIgnore(`INSERT OR IGNORE INTO hub_wx_scenes
		(scene, browser_hash, purpose, owner, qr_url, created_at, expires_at, consumed_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, 0)`),
		c.Scene, c.BrowserHash, c.Purpose, c.Owner, c.QRURL, c.CreatedAt.Unix(), c.ExpiresAt.Unix())
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrWxSceneTaken
	}
	return nil
}

const wxSceneCols = `scene, browser_hash, purpose, owner, qr_url, created_at, expires_at, consumed_at`

func scanWxScene(row interface{ Scan(...any) error }) (*WxScene, error) {
	var c WxScene
	var created, expires, consumed int64
	if err := row.Scan(&c.Scene, &c.BrowserHash, &c.Purpose, &c.Owner, &c.QRURL, &created, &expires, &consumed); err != nil {
		return nil, err
	}
	c.CreatedAt, c.ExpiresAt = time.Unix(created, 0), time.Unix(expires, 0)
	if consumed > 0 {
		c.ConsumedAt = time.Unix(consumed, 0)
	}
	return &c, nil
}

// SetWxSceneQR records what a reserved number's code encodes, once WeChat
// drew it.
func (s *Store) SetWxSceneQR(scene int64, qrURL string) error {
	_, err := s.write.Exec(`UPDATE hub_wx_scenes SET qr_url = ? WHERE scene = ?`, qrURL, scene)
	return err
}

// WxSceneOf is the code numbered scene, nil when the hub drew none.
func (s *Store) WxSceneOf(scene int64) (*WxScene, error) {
	c, err := scanWxScene(s.read.QueryRow(`SELECT `+wxSceneCols+` FROM hub_wx_scenes WHERE scene = ?`, scene))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return c, err
}

// LiveWxSceneFor is the newest untraded code for this browser and purpose
// that is still good until at least until — a reload shows the same code
// instead of drawing another; nil for none.
func (s *Store) LiveWxSceneFor(browserHash, purpose, owner string, until time.Time) (*WxScene, error) {
	c, err := scanWxScene(s.read.QueryRow(`SELECT `+wxSceneCols+` FROM hub_wx_scenes
		WHERE browser_hash = ? AND purpose = ? AND owner = ? AND qr_url <> '' AND consumed_at = 0 AND expires_at > ?
		ORDER BY created_at DESC LIMIT 1`, browserHash, purpose, owner, until.Unix()))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return c, err
}

// WxScenesSince counts the codes drawn since since, across replicas: the
// hub-wide bound on how fast codes are asked of WeChat.
func (s *Store) WxScenesSince(since time.Time) (int, error) {
	var n int
	err := s.read.QueryRow(`SELECT COUNT(*) FROM hub_wx_scenes WHERE created_at >= ?`, since.Unix()).Scan(&n)
	return n, err
}

// ConsumeWxScene trades a code once: true for the one caller that did, false
// when it was already traded, expired, or drawn for another browser.
func (s *Store) ConsumeWxScene(scene int64, browserHash string, now time.Time) (bool, error) {
	res, err := s.write.Exec(`UPDATE hub_wx_scenes SET consumed_at = ?
		WHERE scene = ? AND browser_hash = ? AND consumed_at = 0 AND expires_at > ?`,
		now.Unix(), scene, browserHash, now.Unix())
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// The channels of hub_reach.
const (
	ReachWeChatMP = "wechat-mp" // addr: the service account's openid
	ReachEmail    = "email"     // addr: the address
)

// HubReach is one way to reach someone.
type HubReach struct {
	Owner     string
	Channel   string
	Addr      string
	Followed  bool
	UpdatedAt time.Time
}

// ApplicantReachOwner is hub_reach's owner for someone not on the list yet.
func ApplicantReachOwner(kind, subject string) string {
	return "applicant:" + kind + ":" + NormIdentitySubject(kind, subject)
}

// SetHubReach records (or refreshes) how owner is reached on a channel.
func (s *Store) SetHubReach(r HubReach) error {
	if r.Owner == "" || r.Channel == "" || r.Addr == "" {
		return errors.New("reach needs an owner, a channel and an address")
	}
	if r.UpdatedAt.IsZero() {
		r.UpdatedAt = time.Now()
	}
	f := 0
	if r.Followed {
		f = 1
	}
	_, err := s.write.Exec(`INSERT INTO hub_reach (owner, channel, addr, followed, updated_at) VALUES (?, ?, ?, ?, ?)
		ON CONFLICT (owner, channel) DO UPDATE SET addr = excluded.addr, followed = excluded.followed, updated_at = excluded.updated_at`,
		r.Owner, r.Channel, r.Addr, f, r.UpdatedAt.Unix())
	return err
}

// HubReachOf is how owner is reached, one row per channel.
func (s *Store) HubReachOf(owner string) ([]HubReach, error) {
	rows, err := s.read.Query(`SELECT owner, channel, addr, followed, updated_at FROM hub_reach WHERE owner = ? ORDER BY channel`, owner)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []HubReach
	for rows.Next() {
		var r HubReach
		var f int
		var at int64
		if err := rows.Scan(&r.Owner, &r.Channel, &r.Addr, &f, &at); err != nil {
			return nil, err
		}
		r.Followed, r.UpdatedAt = f != 0, time.Unix(at, 0)
		out = append(out, r)
	}
	return out, rows.Err()
}
