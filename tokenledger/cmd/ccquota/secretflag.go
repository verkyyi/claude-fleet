package main

import "github.com/verkyyi/claude-fleet/tokenledger/shared/secretflag"

// The hub's credential flags are shared/secretflag's, like the node's
// (agent/cli, claude-fleet#4812).
var secretEnvFlag = secretflag.EnvFlag
