# xray-lite

中文菜单管理官方 [XTLS/Xray-core](https://github.com/XTLS/Xray-core)，快捷命令 `xl`。管理流程参考 [singbox-lite](https://github.com/0xdabiaoge/singbox-lite)。适用于 Debian、Ubuntu、Alpine，以及已有 Docker、Podman、LXC 容器内部 root；架构 amd64、arm64、armv7。

## 安装

在 VPS 或已有容器内以 **root** 执行一键安装（需要系统已有 `curl` 或 `wget`）：

```sh
sh -c 'f=$(mktemp) || exit 1; trap '\''rm -f "$f"'\'' EXIT; (curl -fsSL https://raw.githubusercontent.com/Haikure/xray-lite/main/install.sh -o "$f" || wget -qO "$f" https://raw.githubusercontent.com/Haikure/xray-lite/main/install.sh) && sh "$f"'
```

入口会下载 `Haikure/xray-lite` 的 `main` 分支，自动准备 Bash、jq 等依赖，再下载并验证官方最新 Xray。检测到内存限制不超过 512 MiB 且缺少 jq 时，会跳过 apt/apk 并提示从 jq 官方 Releases 下载对应架构的独立二进制。Alpine 不需要先手动安装 Bash。交互终端中安装成功后自动打开中文管理菜单，之后直接输入 `xl` 即可再次进入。非交互执行不自动打开菜单。可在 `sh install.sh` 后加 `--no-menu` 禁止自动进入菜单。

从已经下载的完整项目目录安装：

```sh
sh install.sh
xl
```

## 终端交互菜单

提供类似参考项目的中文数字菜单，输入编号并回车操作：

```text
════════════════════════════════════════════════
  xray-lite v0.1.0 · Xray-core：26.10.21
  Haikure/xray-lite
  服务：运行中  节点：3  模式：systemd
════════════════════════════════════════════════
  节点管理
   1 添加节点       2 Argo 隧道       3 查看节点
   4 删除节点       5 修改节点      20 批量创建
  服务管理
   6 重启服务       7 停止服务       8 运行状态
   9 实时日志      10 定时重启      22 启动服务
  配置与维护
  11 DNS/时间诊断  12 配置检查      13 脚本更新
  14 DNS 设置      15 核心更新      16 NAT 设置
  17 卸载          23 回滚
  进阶功能
  18 中转/导入     19 端口转发      21 批量 YAML

   0 退出
```

这是 Bash 文本交互界面，通过数字菜单和逐项提示管理，未使用鼠标或方向键选单。添加、修改节点、证书、DNS、NAT、端口转发和 Argo 无需手写 JSON；高级批量配置及文件导入保留 JSON 入口。密码输入隐藏，常用修改只更新当前所选字段。

## 核心安装策略

下载直接访问官方 Release API 的完整分页列表，按 `published_at` 选择最新非草稿项，包括预发布，无预发布确认。不使用 `/releases/latest`。最新发布缺少架构资产或 SHA-256 摘要即失败，不降级。检查摘要、实际版本和当前配置后替换，应用失败回滚。

离线安装接受**事先从官方取得的**单个 Release JSON 和该发布的原始 zip，并执行同样的摘要与版本检查：

```sh
sh install.sh --no-menu --offline official-release.json Xray-linux-64.zip --no-start
```

默认目录与其他 Xray 安装隔离：程序 `/opt/xray-lite/app`，状态 `/var/lib/xray-lite`，PID `/run/xray-lite`，服务 `xray-lite`。可通过 `XL_HOME`、`XL_STATE`、`XL_RUN`、`XL_LINK` 指定绝对路径；安装和后续调用需保持一致。`XL_SERVICE_MODE=auto|systemd|openrc|direct`。配置及私钥目录权限 700，文件 600。

## 创建、修改、查看

```sh
xl node add --protocol vless --transport tcp --security reality \
  --name "我的 Reality" --public-address example.com --port 10001 --sni www.microsoft.com
xl node list
xl node show 节点ID
xl node set 节点ID --name "新名称" --port 10002
xl export 节点ID yaml
xl export 节点ID link
xl export 节点ID xray > client.json
xl export all yaml > proxies.yaml
```

涉及密码时建议用权限 600 的 JSON 文件，`xl node add --file spec.json` / `xl node set ID --file patch.json`，避免把密码保留在命令历史。JSON 字段见 [示例](examples/)。支持 `name`、`public_address`、`public_port`、`listen`、`port`、`protocol`、`transport`、`security`、`uuid`、`password`、`sni`、`certificate`、`key_file`、`path`、`host`、`service_name`、`flow`、`cipher`、`username`、`udp`、`private_key`、`short_id`、`target`、`up`、`down`、`obfs_password`、`hop_ports`。带宽单位 Mbps。省略认证自动生成；TLS 未提供证书时生成含 SNI SAN 的自签证书。默认 Shadowsocks 为 SS2022 AES-128。

`xl batch nodes.json` 读取节点对象数组；按文件中声明的端口创建，整批检查和回滚。`xl node delete ID` 删除单个节点。修改只更新指定字段；协议或结构变更可通过 `xl config apply config.json`。修改基于当前磁盘配置，保留手动添加的字段。

查看与导出每次即时读取当前配置、NAT、证书和 Reality 私钥。名称及公网地址由元数据补充，认证、SNI、WS 路径、gRPC serviceName、端口、混淆和跳跃参数以配置为准。单节点 YAML 使用 `- { ... }`，是合法 YAML flow mapping，可直接放入 `proxies:` 列表，不包含规则或代理组。所有 Reality YAML 都含：

```yaml
reality-opts:
  public-key: "由当前私钥推导"
  short-id: "当前配置的 Short ID"
  support-x25519mlkem768: true
```

Xray 客户端 JSON 为完整配置，默认本地 SOCKS `127.0.0.1:10808`。核心当前要求纯 VLESS-TCP 满足其加密限制，候选配置不合规即拒绝应用。第三方配置中的未知扩展可能无法表达为 Mihomo，会说明原因。

## 证书

```sh
xl cert 节点ID /etc/ssl/example/fullchain.pem /etc/ssl/example/privkey.pem
```

每次查看/导出重新读取当前文件和软链接目标，对叶证书 DER 计算 SHA-256；通过系统 CA、有效期、用途、SNI 和中间链判断是否受信任。有效自签使用 HY2 `insecure=1` 加 `pinSHA256`、Mihomo `skip-cert-verify: true` 加 `fingerprint`。受信任 CA 使用正常验证标志并更新指纹。缺失、损坏、过期、不完整链或 SNI 不匹配显示具体错误，不自动放宽验证。

Mihomo `fingerprint` 是证书固定，`client-fingerprint` 是 uTLS，两者独立。当前 Mihomo 在设置叶证书指纹时只执行证书固定；不能把 `skip-cert-verify: false` 解释为额外 CA 验证已经执行。Xray v26.10.21 已移除 `allowInsecure`，客户端 JSON 使用其当前 `pinnedPeerCertSha256` 格式。

外部换证、同路径续签、软链接变化和手动改配置后，导出会反映磁盘内容。与最后一次成功启动的摘要不一致时显示“运行态尚未确认”。查看不会重启；`xl restart` 成功才确认运行态。客户端需重新导入更新后的导出。

## NAT 和容器

```sh
xl nat set examples/nat.json
xl nat show
```

NAT 模型声明 `address` 和 `mappings`，每条映射含 `local`、`public`、`protocol: tcp|udp`。例如监听 10001，公网 30001。所有客户端导出使用公网端口；HY2 的每个跳跃端口必须有 UDP 映射；SOCKS UDP 和 SS 需要同公网端口的 TCP/UDP 映射。宿主机是否真正发布端口在容器内无法确认，需按声明配置宿主机。

实际探测 systemd、OpenRC；无可用 init 使用 direct。容器启动命令用 `xl run` 前台运行单个 Xray。需要监管、定时重启及轮转用 `xl supervise`。不需要 NET_ADMIN 即可使用 Xray 用户态转发。读取 cgroup v1/v2 内存限制，设置 Go 内存目标；此目标不是内核硬限制。direct 日志在重启或 `tick` 时按 1 MiB 轮转，保留一份；长期容器使用 `supervise` 或定时 `tick`。systemd 日志大小由宿主 journald 管理。

```sh
xl start
xl stop
xl restart
xl status
xl logs
xl schedule 360
xl check
xl diagnose
xl dns examples/dns.json
```

定时重启有 cron 时写入每分钟任务；无 cron 可用 `supervise` 或容器调度器调用 `xl tick`。时间诊断显示 UTC、系统同步状态和 DNS；不会擅自修改宿主机时间。

## 中转和转发

```sh
xl relay import exit1 outbound.json
xl relay link exit2 share-link.txt
xl relay token-export 节点ID passfile > node.token
xl relay token-import exit3 node.token passfile
xl relay route 入口节点ID exit1
xl relay route 入口节点ID direct
xl forward set web --file examples/forward.json
xl forward engine web nftables
xl forward list
xl forward delete web
```

项目 Token 使用 AES-256-CBC 加密、PBKDF2 200000 次派生独立加密/认证密钥、HMAC-SHA256 认证，先验认证再解密。口令文件权限必须 600 或 400；不在 Token 中保存服务端私钥。第三方导入支持 VLESS、Trojan、HY2、SS、SOCKS5 链接及 Xray 出口对象；不支持的格式明确拒绝。

用户态引擎由同一 Xray 进程的 dokodemo-door 处理 TCP/UDP，支持 IPv4、IPv6 和域名。nftables 使用独立 `inet xray_lite` NAT 表，原子加载规则，不清空系统规则；需要 NET_ADMIN 与宿主机转发。域名在应用规则时解析，DNS 变化后需重新应用。中转入口可使用任意已创建的节点，路由指向导入出口。

## Argo

```sh
xl argo install
xl argo add WS节点ID --kind quick
xl argo add WS节点ID --file examples/argo-fixed.json
xl argo list
xl argo delete WS节点ID
```

VLESS-WS/Trojan-WS 可以使用临时或固定隧道。按官方 cloudflared Release 摘要下载，凭据限制权限；自签源站使用 CA pool，不关闭源站验证。固定隧道需自行在 Cloudflare 配置域名 DNS 和隧道凭据；脚本不操作 Cloudflare 账户。临时域名从当前 cloudflared 日志读取，启动后重新查看即可导出。外层 Cloudflare TLS 使用系统信任，不错误固定内部源站证书。

## 更新、回滚、卸载

```sh
xl core update
xl rollback
xl script update
xl uninstall --yes
```

所有修改共用 flock；代际目录保存配置、元数据和核心引用，通过单个 `current` 符号链接切换；配置检查失败不切换，启动/规则应用失败恢复上一份。`previous` 保存上次成功修改之前的状态。脚本更新默认使用 `Haikure/xray-lite` 的 Release，菜单 13 直接更新；也可显式指定 `xl script update owner/repo`。发布需提供 `xray-lite.tar.gz` 和 GitHub SHA-256 digest，包根目录包含 `xl`、`lib/`、`install.sh`、`install-local.sh`、`VERSION`。一键安装使用仓库分支源码，无需先创建 Release。脚本包属于可执行代码，更新源应为自己信任的本项目发布仓库。

## 功能差异与验收

| 协议/组合 | 官方 Xray 管理 | Mihomo 导出 |
|---|---|---|
| VLESS TCP Reality/TLS Vision | 支持 | 支持表达，实际连接取决于核心兼容性 |
| VLESS WS TLS、gRPC TLS/Reality | 支持 | 支持 |
| VLESS XHTTP TLS/Reality | 支持 | 支持当前可表达字段 |
| Trojan TCP/WS TLS、gRPC TLS/Reality | 支持 | 支持表达 |
| Trojan XHTTP TLS/Reality | 支持 | Mihomo 不支持，使用链接/Xray JSON |
| 原生 Hysteria2 TLS/认证/Salamander/带宽/跳跃 | 支持 | 支持 |
| 经典 AEAD 四种、SS2022 三种 | 由当前官方核心检查 | 支持其客户端具备的算法 |
| 认证 SOCKS5 TCP/可选 UDP | 支持 | 支持 |
| TUIC、AnyTLS/Any-Reality、ShadowTLS、sing-box Multiplex/Padding | 不纳入纯 Xray 范围 | 不生成替代实现 |

Mihomo 官方文档目前明确提示与 Xray v26.7.11+ Reality 存在兼容性限制。`support-x25519mlkem768: true` 已按要求加入；该字段不能保证所有最新 Xray/Mihomo 组合建立连接。验证记录见 [docs/VERIFICATION.md](docs/VERIFICATION.md)，运行 `bash tests/run.sh` 可重复本地离线回归。测试使用临时目录及官方二进制，不安装或修改系统服务。
