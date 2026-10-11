# The keys page's pictures (claude-fleet#3199)

One picture of Termius on an iPhone per wizard step, served at
`/fleet/keys/img/<file>` and drawn under the step when it is here:

| file          | the step                                   | mark on it                         |
|---------------|--------------------------------------------|------------------------------------|
| `step1.png`   | 1 装 Termius — the App Store page          | 「获取」                            |
| `step2.png`   | 2 生成钥匙 — Keychain → + → Generate Key    | the + and Generate Key, ED25519    |
| `step3.png`   | 3 复制公钥 — the key's Copy Public Key      | Copy Public Key                    |
| `step4.png`   | 4 新建主机 — New Host with its four fields  | Hostname · Port · Username · Key   |
| `step5.png`   | 5 连接 — the new host key question         | Accept / Continue                  |
| `step6.png`   | 6 看台 — the keyboard's ctrl key            | ctrl                               |

Take them on the current Termius iOS, 1170 px wide or less, mark the place to
tap (a red circle), crop the status bar, PNG or JPEG. A file named here that is
missing just draws no picture; any other file is never served.
