package api

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"strconv"
	"strings"
	"time"
)

// The hub's own pass through the Singapore relay (claude-fleet#1976, EPIC
// #1967 R1).
//
// With CCQUOTA_FLEET_OAUTH_REFRESH_VIA=relay the vault posts a Codex refresh
// to the relay's /openai-auth/ route itself (credvault.RelayRefresher)
// instead of handing it to an admin node. The relay's forward_auth asks this
// hub, as for every request, whether the request may pass; the hub answers
// for its own request with a pass only it can sign:
//
//	frh1.<exp unix>.<base64url HMAC-SHA256>
//
// keyed with a key derived from SessionCredKey (one Secret, the same on every
// replica, so whichever replica the check lands on can verify it), good for
// hubRelayPassTTL, and only for the /openai-auth/ route — it opens neither
// /anthropic/ nor /chatgpt/. Nothing is stored: a pass is minted per refresh
// and expires on its own.

const (
	hubRelayPassPrefix = "frh1."
	hubRelayPassTTL    = 5 * time.Minute
	hubRelayPassRoute  = "/openai-auth/"
)

// errHubRelayPassOff means the hub holds no key to sign its relay pass.
var errHubRelayPassOff = errors.New("no session pass key (CCQUOTA_FLEET_SESSION_CRED_KEY) to sign the hub's relay pass")

func (s *Server) hubRelayPassMAC(body string) []byte {
	k := hmac.New(sha256.New, s.SessionCredKey)
	k.Write([]byte("claude-fleet hub relay pass v1"))
	mac := hmac.New(sha256.New, k.Sum(nil))
	mac.Write([]byte(body))
	return mac.Sum(nil)
}

// HubRelayPass mints the hub's pass for one refresh through the relay
// (credvault.RelayRefresher.Pass).
func (s *Server) HubRelayPass() (string, error) {
	if len(s.SessionCredKey) == 0 {
		return "", errHubRelayPassOff
	}
	body := hubRelayPassPrefix + strconv.FormatInt(time.Now().Add(hubRelayPassTTL).Unix(), 10)
	return body + "." + base64.RawURLEncoding.EncodeToString(s.hubRelayPassMAC(body)), nil
}

// verifyHubRelayPass is the relay check for a frh1. pass.
func (s *Server) verifyHubRelayPass(tok, uri string, now time.Time) relayVerdict {
	if len(s.SessionCredKey) == 0 {
		return relayVerdict{why: "hub pass refused: " + SessionCredOff}
	}
	if !strings.HasPrefix(uri, hubRelayPassRoute) {
		return relayVerdict{why: "hub pass refused: it opens " + hubRelayPassRoute + " only"}
	}
	i := strings.LastIndexByte(tok, '.')
	if i <= len(hubRelayPassPrefix) {
		return relayVerdict{why: "hub pass refused: malformed"}
	}
	body := tok[:i]
	got, err := base64.RawURLEncoding.DecodeString(tok[i+1:])
	if err != nil || !hmac.Equal(got, s.hubRelayPassMAC(body)) {
		return relayVerdict{why: "hub pass refused: signature does not verify"}
	}
	exp, err := strconv.ParseInt(body[len(hubRelayPassPrefix):], 10, 64)
	if err != nil {
		return relayVerdict{why: "hub pass refused: malformed"}
	}
	if !time.Unix(exp, 0).After(now) {
		return relayVerdict{why: "hub pass refused: expired"}
	}
	if time.Unix(exp, 0).After(now.Add(hubRelayPassTTL + time.Minute)) {
		return relayVerdict{why: "hub pass refused: lives longer than a hub pass may"}
	}
	return relayVerdict{ok: true, who: "hub"}
}
