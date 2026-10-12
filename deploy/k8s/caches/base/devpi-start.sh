#!/bin/sh
# fleet-pypi (#3548): devpi-server as a read-through PyPI cache. The first start
# makes the server directory on the disk with a random root password kept beside
# it (0600, never printed); every start points root/pypi at FLEET_PYPI_UPSTREAM,
# so changing the upstream is an apply, not a hand step.
set -eu
dir=/data/server
pw=/data/root.pw
umask 077
if [ ! -s "$pw" ]; then
  python3 -c 'import secrets; print(secrets.token_urlsafe(32))' > "$pw.tmp" && mv "$pw.tmp" "$pw"
fi
if [ ! -e "$dir/.nodeinfo" ]; then
  devpi-init --serverdir "$dir" --root-passwd "$(cat "$pw")"
fi
devpi-server --serverdir "$dir" --host 0.0.0.0 --port 3141 --restrict-modify root --request-timeout 30 \
  --mirror-cache-expiry "${FLEET_PYPI_EXPIRY:-1800}" &
pid=$!
trap 'kill -TERM "$pid" 2>/dev/null' TERM INT
i=0
until python3 -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:3141/+api", timeout=2)' 2>/dev/null; do
  i=$((i + 1)); [ "$i" -lt 120 ] || { echo 'fleet-pypi: server did not come up' >&2; kill "$pid"; exit 1; }
  kill -0 "$pid" 2>/dev/null || { echo 'fleet-pypi: server exited' >&2; exit 1; }
  sleep 1
done
export DEVPI_CLIENTDIR=/tmp/devpi-client
devpi use http://127.0.0.1:3141 >/dev/null
devpi login root --password "$(cat "$pw")" >/dev/null
devpi index root/pypi "mirror_url=${FLEET_PYPI_UPSTREAM}" >/dev/null
devpi logoff >/dev/null
echo "fleet-pypi: root/pypi mirrors ${FLEET_PYPI_UPSTREAM}"
wait "$pid" || wait "$pid"
