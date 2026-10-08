package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/release"
)

// runRelease is `ccquota release` (claude-fleet#2335): a machine's side of the
// hub's node releases — fetch one, verify one, and the operator's keygen.
//
//	ccquota release fetch  --hub URL --pubkey FILE [--artifacts] <sha|stable> <dest>
//	ccquota release verify --hub URL --pubkey FILE <sha|stable>   (the hub's copy)
//	ccquota release verify --pubkey FILE --dir <dest>             (an installed one)
//	ccquota release keygen --out FILE                             (the hub's key)
//	ccquota release pubkey --key FILE                             (its public line)
//
// fetch talks to the hub only — never GitHub — and installs nothing that does
// not match the signature of the pinned key: exit 1 on any mismatch, dest
// left absent.
func runRelease(args []string) error {
	if len(args) == 0 {
		return errors.New("usage: ccquota release fetch|verify|keygen|pubkey …")
	}
	switch args[0] {
	case "fetch":
		return runReleaseFetch(args[1:])
	case "verify":
		return runReleaseVerify(args[1:])
	case "keygen":
		return runReleaseKeygen(args[1:])
	case "pubkey":
		return runReleasePubkey(args[1:])
	}
	return fmt.Errorf("release: unknown command %q", args[0])
}

func releasePinned(path string) (ed25519.PublicKey, error) {
	if path == "" {
		return nil, errors.New("--pubkey is required (the key pinned at install)")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return release.ParsePublicKey(b)
}

func releaseFetcher(hub, pubkey string) (*release.Fetcher, error) {
	if hub == "" {
		return nil, errors.New("--hub is required")
	}
	key, err := releasePinned(pubkey)
	if err != nil {
		return nil, err
	}
	return &release.Fetcher{Hub: hub, Key: key, Client: &http.Client{Timeout: 10 * time.Minute}}, nil
}

func runReleaseFetch(args []string) error {
	fs := flag.NewFlagSet("release fetch", flag.ExitOnError)
	hub := fs.String("hub", os.Getenv("FLEET_HUB_URL"), "the hub's URL")
	pub := fs.String("pubkey", "", "the pinned release key file (`ed25519 <base64>`)")
	arts := fs.Bool("artifacts", false, "also fetch every binary / installer")
	_ = fs.Parse(args)
	if fs.NArg() != 2 {
		return errors.New("usage: ccquota release fetch --hub URL --pubkey FILE [--artifacts] <sha|stable> <dest>")
	}
	f, err := releaseFetcher(*hub, *pub)
	if err != nil {
		return err
	}
	m, err := f.Fetch(context.Background(), fs.Arg(0), fs.Arg(1), *arts)
	if err != nil {
		return err
	}
	fmt.Println(release.Summary(m))
	return nil
}

func runReleaseVerify(args []string) error {
	fs := flag.NewFlagSet("release verify", flag.ExitOnError)
	hub := fs.String("hub", os.Getenv("FLEET_HUB_URL"), "the hub's URL")
	pub := fs.String("pubkey", "", "the pinned release key file")
	dir := fs.String("dir", "", "check an installed release directory instead")
	_ = fs.Parse(args)
	if *dir != "" {
		key, err := releasePinned(*pub)
		if err != nil {
			return err
		}
		m, err := release.VerifyDir(key, *dir)
		if err != nil {
			return err
		}
		fmt.Println("OK", release.Summary(m))
		return nil
	}
	if fs.NArg() != 1 {
		return errors.New("usage: ccquota release verify --hub URL --pubkey FILE <sha|stable>")
	}
	f, err := releaseFetcher(*hub, *pub)
	if err != nil {
		return err
	}
	// the whole check, into a throwaway directory
	tmp, err := os.MkdirTemp("", "ccquota-release-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	m, err := f.Fetch(context.Background(), fs.Arg(0), tmp+"/r", true)
	if err != nil {
		return err
	}
	fmt.Println("OK", release.Summary(m))
	return nil
}

func runReleaseKeygen(args []string) error {
	fs := flag.NewFlagSet("release keygen", flag.ExitOnError)
	out := fs.String("out", "", "where to write the private key (base64 seed, 0600)")
	_ = fs.Parse(args)
	if *out == "" {
		return errors.New("usage: ccquota release keygen --out FILE")
	}
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(*out, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	_, err = f.WriteString(base64.StdEncoding.EncodeToString(priv.Seed()) + "\n")
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return err
	}
	fmt.Println(release.FormatPublicKey(pub))
	return nil
}

func runReleasePubkey(args []string) error {
	fs := flag.NewFlagSet("release pubkey", flag.ExitOnError)
	keyf := fs.String("key", "", "the private key file")
	_ = fs.Parse(args)
	b, err := os.ReadFile(*keyf)
	if err != nil {
		return err
	}
	k, err := release.LoadPrivateKey(b)
	if err != nil {
		return err
	}
	fmt.Println(release.FormatPublicKey(k.Public().(ed25519.PublicKey)))
	return nil
}
