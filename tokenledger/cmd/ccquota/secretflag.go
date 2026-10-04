package main

import (
	"flag"
	"os"
)

// secretValue is a string flag whose value never reaches -h output
// (claude-fleet#1508). A token flag defaulted straight from $CCQUOTA_TOKEN made
// PrintDefaults print the node's enrollment token as `(default "ccq_…")`, so a
// worker glancing at `ccquota place -h` copied it into its own context. String()
// is always empty — DefValue is "", PrintDefaults treats it as a zero value and
// prints no default — and the usage names the environment variable instead.
type secretValue struct{ p *string }

func (s secretValue) String() string { return "" }

func (s secretValue) Set(v string) error {
	*s.p = v
	return nil
}

// secretEnvFlag is fs.String(name, os.Getenv(env), usage) for a credential:
// same default, same explicit override, but -h shows `(default: $ENV)`.
func secretEnvFlag(fs *flag.FlagSet, name, env, usage string) *string {
	p := new(string)
	*p = os.Getenv(env)
	fs.Var(secretValue{p}, name, usage+" (default: $"+env+")")
	return p
}
