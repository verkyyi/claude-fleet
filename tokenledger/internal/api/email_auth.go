package api

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math/big"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/i18n"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Sign in by mail — the way in when WeChat and GitHub are not at hand
// (claude-fleet#3604, EPIC #3570 C11, 共同约定 10).
//
//	POST /auth/email/start  {email}   a mail with a link and six digits —
//	                                   «sent» whether or not the address can
//	                                   sign in here
//	GET  /auth/email/link?t=          the link: in the browser that asked only
//	POST /auth/email/code   {code}    the six digits, typed in that browser
//
// What a mail opens is decided at the end, as for every way in: an address
// someone signs in with is that person; an address nobody has comes in only
// on the invite the browser carries (admitPerson); a signed-in person adds
// it to themselves (登录方式 · 加邮箱). An address that can do none of these
// is still answered «sent» — and gets no mail.
//
// Kept: hashes only (hub_signin_codes, shared by both replicas) — the link's
// token, the digits salted with the mail's id, the asking browser's nonce;
// 15 minutes, used once, five wrong codes void it; at most one mail a minute
// and five an hour per address, counted for unknown addresses alike so the
// limits say nothing about who is here. The link works only in the browser
// that asked (its ccq_em_flow cookie); on another device a person types the
// digits into that browser instead. BREAK-IT email-link-replay.

// EmailAuth is the mail sign-in's configuration.
type EmailAuth struct {
	// SMTPURL is CCQUOTA_SMTP_URL (credentials inside: the Secret only);
	// From is CCQUOTA_SMTP_FROM.
	SMTPURL string
	From    string
	// Send delivers a mail; nil means SMTP from SMTPURL. Tests set it.
	Send func(ctx context.Context, to, subject, body string) error

	smtp *smtpConf
}

const (
	emailFlowCookie = "ccq_em_flow"
	emailFlowPath   = "/auth/email/"
	// emailGap / emailHourly: the limits per address.
	emailGap    = 60 * time.Second
	emailHourly = 5
)

// NewEmailAuth reads the SMTP settings; nil, nil when CCQUOTA_SMTP_URL is
// empty (mail sign-in off).
func NewEmailAuth(smtpURL, from string) (*EmailAuth, error) {
	if strings.TrimSpace(smtpURL) == "" {
		return nil, nil
	}
	c, err := parseSMTP(smtpURL, from)
	if err != nil {
		return nil, err
	}
	return &EmailAuth{SMTPURL: smtpURL, From: c.from.String(), smtp: c}, nil
}

func (x *EmailAuth) ready() bool { return x != nil && (x.Send != nil || x.smtp != nil) }

// SMTPHost is the mail server's name, for the start-up line.
func (x *EmailAuth) SMTPHost() string {
	if x == nil || x.smtp == nil {
		return ""
	}
	return x.smtp.hostName()
}

func (x *EmailAuth) send(ctx context.Context, to, subject, body string) error {
	if x.Send != nil {
		return x.Send(ctx, to, subject, body)
	}
	return x.smtp.send(ctx, to, subject, body)
}

func hashHex(parts ...string) string {
	sum := sha256.Sum256([]byte(strings.Join(parts, "\x00")))
	return hex.EncodeToString(sum[:])
}

// sixDigits is a uniformly random 000000–999999.
func sixDigits() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%06d", n.Int64()), nil
}

// emailBrowser is this browser's nonce for mail sign-in, minted (and set)
// when it has none.
func (s *Server) emailBrowser(w http.ResponseWriter, r *http.Request) (string, error) {
	if c, err := r.Cookie(emailFlowCookie); err == nil && validInviteCode(c.Value) {
		return c.Value, nil
	}
	n, err := randomToken(24)
	if err != nil {
		return "", err
	}
	http.SetCookie(w, &http.Cookie{
		Name: emailFlowCookie, Value: n, Path: emailFlowPath,
		HttpOnly: true, SameSite: http.SameSiteLaxMode, Secure: isHTTPS(r),
		MaxAge: int(store.SigninCodeTTL.Seconds()),
	})
	return n, nil
}

// errEmailSlow: the address had a mail a moment ago, or five this hour.
var errEmailSlow = errors.New("too many mails to this address")

// emailStart asks for a mail to addr from this browser. It records the ask
// whatever the address is, and delivers only when the mail could open
// something (emailOpens). nil is «sent» — never «this address is unknown».
func (s *Server) emailStart(w http.ResponseWriter, r *http.Request, addr string, now time.Time) error {
	last, n, err := s.Store.SigninCodeStats(store.IdentityEmail, addr, now.Add(-time.Hour))
	if err != nil {
		return err
	}
	if (!last.IsZero() && now.Sub(last) < emailGap) || n >= emailHourly {
		return errEmailSlow
	}
	browser, err := s.emailBrowser(w, r)
	if err != nil {
		return err
	}
	id, err1 := randomToken(12)
	link, err2 := randomToken(24)
	code, err3 := sixDigits()
	if err := errors.Join(err1, err2, err3); err != nil {
		return err
	}
	if err := s.Store.CreateSigninCode(store.SigninCode{ID: id, Kind: store.IdentityEmail, Subject: addr,
		BrowserHash: hashHex("em-browser", browser), LinkHash: hashHex("em-link", link), CodeHash: hashHex("em-code", id, code),
		CreatedAt: now, ExpiresAt: now.Add(store.SigninCodeTTL)}); err != nil {
		return err
	}
	if !s.emailOpens(r, addr) {
		_ = s.Store.HubAudit("email:?", "signin.mail", addr, "held", "nobody signs in with it and no invite: no mail", now)
		return nil
	}
	loc := s.pageLocale(w, r)
	subject := pageT(loc, "mail.subject")
	body := i18n.Interpolate(pageT(loc, "mail.body"), map[string]string{
		"link": s.hubURL(r) + "/auth/email/link?t=" + link, "code": code, "host": r.Host})
	// Off the request: a known address answers as fast as an unknown one.
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if err := s.Email.send(ctx, addr, subject, body); err != nil {
			log.Printf("email sign-in: mail to …@%s not sent: %v", addr[strings.LastIndex(addr, "@")+1:], err)
		}
	}()
	_ = s.Store.HubAudit("email:?", "signin.mail", addr, "ok", "sign-in mail sent", now)
	return nil
}

// emailOpens: a mail to addr from r could open something — the address is
// someone's way in, the browser carries an invite, or a signed-in person is
// adding it to themselves.
func (s *Server) emailOpens(r *http.Request, addr string) bool {
	pid, err := s.Store.IdentityPrincipal(store.IdentityEmail, addr)
	if err != nil {
		return false
	}
	if pid != "" {
		return true
	}
	if c, err := r.Cookie(inviteCookie); err == nil && validInviteCode(c.Value) {
		return true
	}
	if _, me, ok := s.personSession(r); ok {
		role, err := s.personRole(me)
		return err == nil && role != ""
	}
	return false
}

// handleEmailStart is POST /auth/email/start: a form from /signin, or JSON.
func (s *Server) handleEmailStart(w http.ResponseWriter, r *http.Request) {
	if !s.Email.ready() || s.Store == nil {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	if !sameOrigin(r) {
		httpError(w, http.StatusForbidden, "cross-site request refused")
		return
	}
	asJSON := strings.HasPrefix(r.Header.Get("Content-Type"), "application/json")
	var addr string
	if asJSON {
		var req struct {
			Email string `json:"email"`
		}
		_ = json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req)
		addr = req.Email
	} else {
		r.Body = http.MaxBytesReader(w, r.Body, 4<<10)
		addr = r.FormValue("email")
	}
	addr = store.NormIdentitySubject(store.IdentityEmail, addr)
	reply := func(e string) {
		if asJSON {
			switch e {
			case "":
				writeJSON(w, http.StatusOK, map[string]any{"sent": true})
			case "email-slow":
				httpError(w, http.StatusTooManyRequests, "a mail went to this address a moment ago — wait a minute")
			default:
				httpError(w, http.StatusBadRequest, "not an email address")
			}
			return
		}
		to := appURL("/signin") + "?step=code"
		if e != "" {
			to = appURL("/signin") + "?e=" + e
			if e == "email-slow" {
				to += "&step=code"
			}
		}
		http.Redirect(w, r, to, http.StatusSeeOther)
	}
	if !validEmail(addr) {
		reply("email-bad")
		return
	}
	switch err := s.emailStart(w, r, addr, time.Now()); {
	case errors.Is(err, errEmailSlow):
		reply("email-slow")
	case err != nil:
		log.Printf("email sign-in: %v", err)
		httpError(w, http.StatusInternalServerError, "could not send the mail")
	default:
		reply("")
	}
}

// emailBrowserHash is this browser's nonce, hashed; "" when it has none.
func emailBrowserHash(r *http.Request) string {
	c, err := r.Cookie(emailFlowCookie)
	if err != nil || !validInviteCode(c.Value) {
		return ""
	}
	return hashHex("em-browser", c.Value)
}

// handleEmailLink is the mail's link.
func (s *Server) handleEmailLink(w http.ResponseWriter, r *http.Request) {
	if !s.Email.ready() || s.Store == nil {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	now := time.Now()
	t := r.URL.Query().Get("t")
	var c *store.SigninCode
	if validInviteCode(t) {
		var err error
		if c, err = s.Store.SigninCodeByLink(hashHex("em-link", t)); err != nil {
			httpError(w, http.StatusInternalServerError, "could not read the sign-in")
			return
		}
	}
	if c == nil || !c.UsedAt.IsZero() || !now.Before(c.ExpiresAt) {
		http.Redirect(w, r, appURL("/signin")+"?e=email-expired", http.StatusFound)
		return
	}
	if b := emailBrowserHash(r); b == "" || !constantTimeEqual(b, c.BrowserHash) {
		// Another device: the link stays unspent; the digits finish it in
		// the browser that asked.
		http.Redirect(w, r, appURL("/signin")+"?e=email-device", http.StatusFound)
		return
	}
	if ok, err := s.Store.UseSigninCode(c.ID, now); err != nil || !ok {
		http.Redirect(w, r, appURL("/signin")+"?e=email-expired", http.StatusFound)
		return
	}
	s.emailFinish(w, r, c.Subject, now)
}

// handleEmailCode is the six digits, typed into the browser that asked.
func (s *Server) handleEmailCode(w http.ResponseWriter, r *http.Request) {
	if !s.Email.ready() || s.Store == nil {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	if !sameOrigin(r) {
		httpError(w, http.StatusForbidden, "cross-site request refused")
		return
	}
	now := time.Now()
	r.Body = http.MaxBytesReader(w, r.Body, 1<<10)
	code := strings.TrimSpace(r.FormValue("code"))
	b := emailBrowserHash(r)
	var c *store.SigninCode
	if b != "" {
		var err error
		if c, err = s.Store.SigninCodeForBrowser(b, now); err != nil {
			httpError(w, http.StatusInternalServerError, "could not read the sign-in")
			return
		}
	}
	if c == nil {
		http.Redirect(w, r, appURL("/signin")+"?e=email-expired", http.StatusSeeOther)
		return
	}
	if len(code) != 6 || !constantTimeEqual(hashHex("em-code", c.ID, code), c.CodeHash) {
		left, err := s.Store.FailSigninCode(c.ID, now)
		if err != nil {
			httpError(w, http.StatusInternalServerError, "could not read the sign-in")
			return
		}
		if left == 0 {
			_ = s.Store.HubAudit("email:?", "signin", c.Subject, "refused", "five wrong codes: mail voided", now)
			http.Redirect(w, r, appURL("/signin")+"?e=email-void", http.StatusSeeOther)
			return
		}
		http.Redirect(w, r, appURL("/signin")+"?step=code&e=email-wrong", http.StatusSeeOther)
		return
	}
	if ok, err := s.Store.UseSigninCode(c.ID, now); err != nil || !ok {
		http.Redirect(w, r, appURL("/signin")+"?e=email-expired", http.StatusSeeOther)
		return
	}
	s.emailFinish(w, r, c.Subject, now)
}

// emailFinish: the mail was proven by this browser. A signed-in person adds
// the address to themselves; anyone else signs in as whoever it lets in, or
// comes in on the invite the browser carries.
func (s *Server) emailFinish(w http.ResponseWriter, r *http.Request, addr string, now time.Time) {
	clearCookie(w, r, emailFlowCookie, emailFlowPath)
	if _, me, ok := s.personSession(r); ok {
		if role, err := s.personRole(me); err == nil && role != "" {
			owner, err := s.Store.IdentityPrincipal(store.IdentityEmail, addr)
			if err != nil {
				httpError(w, http.StatusInternalServerError, "could not read the people list")
				return
			}
			if owner == "" {
				err := s.Store.AddHubIdentity(store.HubIdentity{Kind: store.IdentityEmail, Subject: addr,
					PrincipalID: me, VerifiedAt: now, AddedBy: "mail"})
				if err != nil && !errors.Is(err, store.ErrIdentityTaken) {
					httpError(w, http.StatusInternalServerError, err.Error())
					return
				}
				if err == nil {
					_ = s.Store.HubAudit(me, "identity.add", addr, "ok", "email, proven by its mail", now)
					http.Redirect(w, r, AppPrefix+"/config#logins", http.StatusFound)
					return
				}
				owner = "?"
			}
			if owner != me {
				_ = s.Store.HubAudit(me, "identity.add", addr, "refused", "another person signs in with it", now)
				http.Redirect(w, r, AppPrefix+"/config?e=taken#logins", http.StatusFound)
				return
			}
			http.Redirect(w, r, loginReturn(w, r), http.StatusFound)
			return
		}
	}
	invite := s.takeInviteCookie(w, r)
	pid, role, refusal, err := s.admitPerson(store.IdentityEmail, addr, "", invite, now)
	if err != nil {
		log.Printf("email sign-in: %v", err)
		httpError(w, http.StatusInternalServerError, "could not read the people list")
		return
	}
	if role == "" {
		s.waySignedOut(w, r, store.IdentityEmail, refusal, addr, now)
		return
	}
	s.signInAs(w, r, store.IdentityEmail, pid, "", role, now)
}

func init() {
	for k, v := range map[string]i18n.Text{
		"mail.subject": {i18n.EN: "Sign in to claudefleet", i18n.ZhCN: "登录 claudefleet"},
		"mail.body": {
			i18n.EN: "Someone — hopefully you — asked to sign in to claudefleet ({host}) with this address.\n\n" +
				"Open this link in the same browser:\n{link}\n\nor type these six digits there: {code}\n\n" +
				"Both work once, for 15 minutes. Didn't ask? Ignore this mail: nothing happens without it.\n",
			i18n.ZhCN: "有人（希望是你）想用这个邮箱登录 claudefleet（{host}）。\n\n" +
				"在发起登录的那个浏览器里打开这个链接：\n{link}\n\n或在那里输入这 6 位数字：{code}\n\n" +
				"两者都只能用一次，15 分钟内有效。不是你要登录？不用管这封信，没有它什么都不会发生。\n",
		},
	} {
		pageText[k] = v
	}
}
