package cli

import "github.com/verkyyi/claude-fleet/tokenledger/shared/secretflag"

// The credential flags and token roads are shared/secretflag's (the hub's
// commands take theirs the same way, claude-fleet#4812).
var (
	secretEnvFlag = secretflag.EnvFlag
	tokenFromFD   = secretflag.FromFD
	tokenFromFile = secretflag.FromFile
)
