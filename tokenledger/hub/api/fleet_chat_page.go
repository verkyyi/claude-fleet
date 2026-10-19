package api

// ChatPagePath is where the web chat's page was (claude-fleet#3646): the
// conversation is the console's front page now (claude-fleet#3926), and the
// old page with its /chat/assets build went with the old console
// (claude-fleet#3939) — the address only moves on (consolePages).
const ChatPagePath = "/chat/"

// chatCSP is the console's policy — every byte the hub's own, same origin only.
const chatCSP = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; " +
	"font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
