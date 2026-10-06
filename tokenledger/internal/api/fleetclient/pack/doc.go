// Package pack is where a hub build puts the client it serves
// (claude-fleet#1803): bin/fleet-client-pack.sh copies every file
// ../manifest lists here, from the repo's one copy, before `go build` /
// `docker build`. Nothing but this file is committed; fleetclient embeds the
// directory (`all:pack`) and serves no client when it holds only this file.
package pack
