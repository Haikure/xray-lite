# 验收记录

日期：2026-10-24。工作区从空目录建立。未安装到宿主机，未修改宿主机服务，未构建、下载或提供容器镜像。容器支持指已有容器内部安装与运行。

## 使用的真实二进制

- 官方 Xray v26.10.21，linux/amd64，官方 zip SHA-256：`0eec3ed4163c273d8c8bf821f7d219e257921cf584aa3fb970715e458e631978`。
- 官方 Mihomo v1.19.33，linux/amd64，官方 gz SHA-256：`132f6f3edf9a65e62f04853aed3358472e0b2b7666daa8419edfa2ddf5bb6323`。
- Bash、jq、OpenSSL 3.5.5。依赖与二进制下载已获得用户授权。

## 已执行

`bash tests/run.sh`：离线回归覆盖：

- 按发布时间选择最新非草稿项，保留预发布；完整分页；最新发布缺资产时失败；下载和摘要失败保留状态。
- Reality 从当前私钥推导公钥；所有可表达 Reality YAML 含 `reality-opts.support-x25519mlkem768: true`；真实 Mihomo 解析。
- VLESS/Trojan TCP、WS、gRPC、XHTTP 的服务端和客户端配置通过真实 Xray 检查；Trojan-XHTTP 明确拒绝 Mihomo 转换。
- 原生 HY2、Salamander、带宽和端口范围，SOCKS5，以及四种经典 AEAD、三种 SS2022 配置。
- 当前磁盘认证和 SNI 修改即时反映，局部更新保留手动字段。
- NAT 内外端口、UDP 跳跃映射缺失拒绝、无效批量创建回滚、IPv6 分享端点。
- 自签同路径换证、软链接更新、受信 CA 切换及续签、完整/缺失中间链、损坏、过期、缺失和 SNI 不匹配。
- Token 往返及错误口令拒绝，第三方链接导入。
- 并发修改序列化、运行确认摘要失效、无 NET_ADMIN 的 Xray UDP/IPv6 转发配置及删除。

`bash tests/runtime.sh`：真实 Mihomo → 官方 Xray → 本地 HTTP 目标：

| 组合 | 本地连接 |
|---|---|
| VLESS TCP TLS Vision、WS TLS、gRPC TLS、XHTTP TLS | 4/4 通过 |
| Trojan TCP TLS、WS TLS、gRPC TLS | 3/3 通过 |
| HY2 TLS、Shadowsocks SS2022 AES-128、SOCKS5 | 3/3 通过 |
| VLESS TCP/gRPC/XHTTP Reality、Trojan gRPC Reality | 0/4；握手未完成 |

测试同时验证启动失败后恢复旧配置、元数据和旧核心运行。`--smoke` 单例复测通过。测试用例仅显式放行 `127.0.0.1:42001`，因为新版官方 freedom 默认阻止这些代理协议访问私网；产品默认保留官方行为。

Reality 四个用例使用本地 OpenSSL TLS 目标；不能将其失败单独归因于任一核心。Mihomo 官方文档另外提示与 Xray v26.7.11+ 存在兼容性限制。新增 MLKEM 字段可被当前 Mihomo 解析，不构成真实 Reality 连接已经通过的证明。

## 尚未完成的环境验收

- Debian/Ubuntu VPS 的 root 安装和 systemd 实际生命周期。
- Alpine OpenRC、容器内 root/rootless 容器 root 的实际安装；无 init 的 direct 生产入口。
- arm64、armv7，128 MB 内存硬限及负载测量。
- 具有 NET_ADMIN 的 nftables 实际转发与宿主机 NAT 发布。
- cloudflared 的真实临时/固定隧道、固定隧道账户/DNS 凭据。
- 真实公网 Reality 目标及客户端连接、HY2 UDP 业务和长时间端口跳跃。

本地没有可用的免交互 root，也无法创建用户命名空间；没有用测试钩子替代上述部署验收。离线测试仅在测试进程内绕过 root 入口，生产脚本保留 root 要求。所有测试临时进程在退出时清理。
