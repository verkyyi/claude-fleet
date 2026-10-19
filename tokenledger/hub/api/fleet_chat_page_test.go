package api

import (
	"testing"
)

// The web chat's page (claude-fleet#3646) moved to /app, the console's front
// page (claude-fleet#3926), and its /chat/assets build went with the old
// console (claude-fleet#3939): /chat and /chat/ move on, the files are gone;
// GET /v1/chat/home says where the conversation runs without relaying
// anything.

func TestChatInEveryMenu(t *testing.T) {
	for _, role := range []string{roleUser, roleAdmin} {
		found := false
		for _, p := range pagesFor(role) {
			found = found || p == "chat"
		}
		if !found {
			t.Errorf("%s's pages %v have no chat", role, pagesFor(role))
		}
	}
}
