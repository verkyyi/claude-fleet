# gh-relay — GitHub through the Singapore relay (claude-fleet#3348)

The ACK cluster (Shenzhen) cannot reach `https://github.com` (timeouts); the
relay box `ai-relay-sg` (Lightsail `ai-relay-1g`, `47.131.114.67`, the same box
as the git-mirror's sync path and the AI relay — 24haowan-monorepo
`infra/ci-runners/ai-relay-sg/README.md`) can. `gh-relay.py` is an HTTP CONNECT
proxy on `:3128` that tunnels **only**:

| Wall | What |
|---|---|
| Lightsail firewall | 3128 open to the cluster egress `47.106.171.142/32` only |
| source check (in-process) | `GH_RELAY_SOURCES` — the same /32; anyone else gets the connection closed, no answer |
| method | `CONNECT` only — 403 `method_not_allowed` for plain HTTP proxying |
| port | 443 only — 403 `port_not_allowed` |
| host | GitHub's own names, exact match (`GH_RELAY_HOSTS`, default: github.com, api/codeload/uploads.github.com, objects/raw/release-assets/media/github-cloud.githubusercontent.com, ghcr.io, …) — 403 `host_not_allowed` |
| address | every resolved address must be public — 403 `blocked_address`; the unit's `IPAddressDeny` refuses private ranges in the kernel too |

Nothing is decrypted: the client's TLS runs end to end to GitHub. One JSON line
per request in journald (`src host code up down ms why`), never a payload.
`python3 -I gh-relay.py --selftest` runs offline.

The node side is `extras/managed-node/render.py --github-proxy http://47.131.114.67:3128`
(docs/MANAGED-LINUX.md «Dev network»).

## Install / update (on ai-relay; files scp'd to /tmp first)

```sh
# from a machine holding the relay key (README in the monorepo: ~/.ssh/ai-relay-sg-rsa)
scp -i ~/.ssh/ai-relay-sg-rsa extras/gh-relay/gh-relay.py extras/gh-relay/gh-relay.service admin@47.131.114.67:/tmp/
ssh -i ~/.ssh/ai-relay-sg-rsa admin@47.131.114.67 '
  grep ^nameserver /etc/resolv.conf     # must be 172.26.0.2 (the unit allows only that private address)
  python3 -I /tmp/gh-relay.py --selftest &&
  sudo install -d /opt/gh-relay && sudo install -m 755 /tmp/gh-relay.py /opt/gh-relay/ &&
  sudo install -m 644 /tmp/gh-relay.service /etc/systemd/system/ &&
  sudo systemctl daemon-reload && sudo systemctl enable --now gh-relay && sudo systemctl restart gh-relay &&
  systemctl is-active gh-relay && sudo ss -ltnp | grep 3128'
# the firewall: 3128 from the cluster egress only — keep the existing rules, add one
aws lightsail open-instance-public-ports --region ap-southeast-1 --instance-name ai-relay-1g \
  --port-info fromPort=3128,toPort=3128,protocol=tcp,cidrs=47.106.171.142/32
aws lightsail get-instance-port-states --region ap-southeast-1 --instance-name ai-relay-1g
```

## Check it

```sh
# from the cluster (fleet-linux-0, any login): through, and only GitHub
curl -sS -o /dev/null -w '%{http_code}\n' -x http://47.131.114.67:3128 https://github.com/       # 200
curl -sS -o /dev/null -w '%{http_code}\n' -x http://47.131.114.67:3128 https://example.com/      # 000 (403 from the proxy)
# from anywhere else: no answer (firewall), and the program would close it anyway
curl -m5 -x http://47.131.114.67:3128 https://github.com/                                         # timeout
# on the relay
sudo journalctl -u gh-relay -n 20 --no-pager -o cat
```

If the cluster egress IP changes, change both the Lightsail rule and
`GH_RELAY_SOURCES` in the unit (and the 9418 rule beside it).
