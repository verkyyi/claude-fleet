---
name: runbook-door-down
description: 入口端口（每人家机器上的第二个 sshd，默认 22022——fleet 唯一有意开在公网的门）掉线的故障手册——手机 / 电脑连不进、Termius 超时或被拒；分清是门没开（sshd 没起、配置被拒、名单为空）、外面到不了（路由器没转发、没有公网地址、钥匙不符）、名字指错（DNS 没跟上家）、还是 Linux 节点被摘（就绪探针）；各自怎么修、怎么验收。用于「连不上家机器」「22022 不通」「体检 entry / public / ingress 行 WARN」「换了路由器 / 搬家后进不去」。只给管理机器的人用。
---

# runbook-door-down — 入口端口掉线

占位：`<MAC>` 家机器 · `<NAME>` 这个人的地址名（`<NAME>.<入口给的子域>`）· `<PORT>` 路由器给这台的公网端口（机器节点路线
`entry=<host>:<port>`，没有就是 22022）· `<LAN_IP>` 家机器有线网卡的内网地址 · `<STATE>` `/var/db/fleet-node`（Linux 节点照它的状态目录）·
`<RT>` `/Library/Application Support/claude-fleet`。
权威出处：`docs/MANAGED-NODE.md` §16「入口端口：只认入口登记的钥匙」及其两小节「外面能不能连上它」「你的地址指向你的家」；
仓库根 `CLAUDE.md`「A fleet temp server binds 127.0.0.1」那一条的末段（唯一的例外）；`docs/BREAK-IT.md` 的 `entry-*` 行与
`linux-stale-lane-door-down`；`bin/fleet-node-supervisor.py entry …`。云上 Linux 节点本身见 [ack-linux-node]，机器入网见 [mac-node-enroll]。

## 什么时候用

- 某人的手机或电脑连不进家机器（`ssh -p <PORT> <login>@<NAME>…` 超时 / 被拒 / 主机钥匙变了）。
- `fleet doctor` 的 `entry` 行 WARN（名单落后、配置被拒、名单有人却没在听），`public` 行 WARN（外面连不上 / 没有公网地址 / 结果过期），
  `ingress` 行 WARN（系统 sshd 的公网转发探不通）。
- 换了路由器、宽带、搬家；或 Linux 托管节点上 22022 对所有人都死了。

## 先查什么

在家机器上（admin 的 ssh 或 tailnet）：

```sh
sudo python3 "<RT>/current/bin/fleet-node-supervisor.py" entry status          # 入口 vN · 本机 vM · 在不在听 · AllowUsers
sudo python3 "<RT>/current/bin/fleet-node-supervisor.py" entry reach           # 现在就从外面敲一次门（结果写 <STATE>/entry/reach.json）
fleet doctor | grep -E '^ *(PASS|WARN|FAIL|INFO) +(entry|public|ingress|node) '
sudo tail -50 /var/log/fleet-node/entry.log                                    # 入口 sshd 的日志：进门、钥匙被拒、没这个登录
lsof -nP -iTCP:22022 -sTCP:LISTEN                                              # 真有进程在听吗
```

从外面（手机热点上的电脑，不在同一个家网里）：`nc -vz <NAME>.<子域> <PORT>`，再 `ssh-keyscan -p <PORT> <NAME>.<子域>`。

按结果分四类：**门没开**（没在听 / 配置被拒）· **外面到不了**（本机在听、`public` 说连不上）· **名字指错**（`dig` 出来的地址不是家）·
**被摘**（Linux 节点，pod 不 Ready）。

## 步骤

1. **门没开**：
   - 开关：`<STATE>/machine.env` 里要有 `FLEET_ENTRY=1`。没有：`FLEET_ENTRY=1 sudo fleet node install`（「入口」一步写进去），
     再 `sudo python3 "<RT>/current/bin/fleet-node-supervisor.py" entry ensure`。
   - 名单为空（没有一个守护接管、非管理员的登录以这台为家）⇒ 门按设计不起。管理员登录永远不进 AllowUsers；要进门的人得有自己的
     托管登录（[login-lifecycle]）。
   - 配置被拒：`entry.log` / `entry status` 写着 `sshd -t` 的错或缺 `PerSourcePenalties`（OpenSSH < 9.8 根本不起）——升级系统的
     OpenSSH，不要手改 `<STATE>/entry/sshd_config`（守护每分钟比对并放回）。
   - 名单落后（入口 vN > 本机 vM）：`sudo python3 "<RT>/current/bin/fleet-node-supervisor.py" entry pull`；入口不在时最后一份照用。
2. **外面到不了**（`public` 行写了原因）：
   - 「超时 / 被拒」：在路由器上把公网 TCP `<PORT>` 转发到 `<LAN_IP>:22022`（体检那行原样写着这两个数）；`FLEET_ENTRY_PORTMAP=auto`
     会先试 NAT-PMP / UPnP，路由器不肯就手配。两台家机器在同一个路由器后面时各用一个外侧端口，机器节点路线写 `entry=<host>:<port>`。
   - 「这台没有公网地址」（运营商级 NAT，`no_public: cgnat`）：家里宽带要公网 IPv4（找运营商），或让 IPv6 可达；在那之前这台不能当家，
     人改用中转路线（[sg-relay-setup]）或换一台当家。
   - 「钥匙不符」：那个地址上应门的不是这台的入口 sshd（转发指错了机器、端口被别的服务占了）——改转发，不是改钥匙。
   - 「结果过期」：节点程序 5 分钟没报了——查 `node` 行和守护（`fleet-node-supervisor.py status`）。
3. **名字指错**：`dig +short <NAME>.<子域>`（公共解析器）。记录只由入口写：家从外面连不上（或 15 分钟没新结果）时入口**一条不改**、
   留着最后的地址——所以先修第 2 步，等一分钟入口那拍自己改；有人在 DNS 控制台手改过，下一拍会被改回。没领名字的人查不到地址是设计如此。
4. **Linux 节点被摘**（pod 不 Ready、22022 对每个登录都死）：`fleet-node-linux.py ready` 只看整机；一个已删登录残留的被拒 lane
   不该摘它——`sudo python3 "<RT>/current/bin/fleet-node-supervisor.py" account forget <login>` 把它挪进 attic。细节见 [ack-linux-node]。
5. **一个人进不去、别人都行**：多半是钥匙——看 `entry.log` 里他的指纹是「被拒」还是「没这个登录」；钥匙在入口的钥匙页加 / 撤，
   不往 `~/.ssh/authorized_keys` 或 `<STATE>/entry/keys/` 手写（会被放回）。被吊销的设备证书照吊销名单拒（`entry revocations status`）。
6. **从不**：把门改成密码登录、放进管理员登录、把 22 端口的系统 sshd 开到公网代替它、关掉 `PerSourcePenalties`。

## 怎么验收

- 家机器：`entry status --check` 退 0；`fleet doctor` 的 `entry` 行 PASS（入口 vN = 本机 vN）、`public` 行 PASS「外面连得上：<地址:端口>」。
- 外面：`ssh-keyscan -p <PORT> <NAME>.<子域>` 拿到的主机钥匙 = `<STATE>/entry/ssh_host_ed25519_key.pub`；那个人的手机 / 电脑连进去落在自己的会话。
- 这次进门有记录：家机器 `/var/log/fleet-node/entry.ndjson` 多一行（人 · 登录 · 指纹 · 来源 · 结果），入口的审计里也有。

## 怎么回滚

- 关门：`FLEET_ENTRY=0 sudo fleet node install`（去掉开关）后 `entry ensure`——sshd 停，`access_ssh` 只撤自己加的，`status` 回到没开前。
- 路由器转发 / 自动端口映射：删掉那条转发，或 `FLEET_ENTRY_PORTMAP=off`（machine.env）让节点程序不再碰路由器（已开的映射 2 小时后过期）。
- 名单：入口的版本只进不退；撤一把误加的钥匙在钥匙页撤，下一次拉取就生效，正连着的连接会被断开。
