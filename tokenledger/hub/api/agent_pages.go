package api

// The console's two pages for outside agents (T4DN):
//
//   - 我的 · Agent, /app/me/agents — a tab of 我的, so isMeTab already serves
//     it (the console draws the tab itself); it needs no line of its own here.
//   - the OAuth consent card, oauthConsentPagePath — where /oauth/authorize
//     sends a signed-in person's browser with the agent's whole OAuth query
//     string. The console draws it outside its shell, like a sign-in page
//     (extras/web-console/src/app/main.tsx), and reads/approves the request
//     over /v1/me/oauth/request and /v1/me/oauth/approve.
//
// appMount serves it like a session page: isAgentPage(p) beside isMeTab(p) /
// isSessionPage(p), behind appSide's viewerOnly.

// oauthConsentPagePath is the consent card's address under the hub's root.
const oauthConsentPagePath = AppPrefix + "/oauth/authorize"

// isAgentPage says whether p (a request path) is one of the console's pages
// for outside agents that no routeAccess row names.
func isAgentPage(p string) bool {
	return p == oauthConsentPagePath || p == oauthConsentPagePath+"/"
}
