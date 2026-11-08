# 验收记录

## 2026-11-08 main 更新与旧版迁移（0.1.3）

管理脚本更新改为直接下载 `main` 源码，保留显式 `--ref`，不查询 Release 或仓库信息 API。新增 `sh install.sh --script-only`，供 0.1.0 等旧版手动迁移；仅替换管理脚本，成功后退出旧菜单重新运行 `xl`。此入口随 0.1.3 推送到 `main` 后才可通过线上安装命令使用。

已通过本地 `bash tests/script-main.sh` 和既有 `bash tests/install-menu.sh`，以及 Shell 语法与差异检查。专项测试使用 Git 历史中的真实 0.1.0 脚本、当前完整源码和生产安装器，在临时目录绕过 root 检查并模拟源码下载，验证：

- 0.1.0 迁移后版本正确，旧脚本保存在 `app.previous`。
- 核心、节点配置、证书、核心发布信息、回滚指针、当前软链接和运行文件保持不变；服务安装和重启路径未触发。
- 默认更新仅下载 `Haikure/xray-lite/main`，显式仓库与分支参数仍可用。
- 单文件 POSIX 入口完成源码下载、参数传递和脚本替换。
- 未安装目录及冲突参数被拒绝；候选验证失败保留旧脚本，替换后自检失败恢复旧脚本。

专项脚本放在已有的本地 `tests/` 目录，该目录按项目规则被 Git 忽略。本轮未执行宿主机 root 安装或生产服务操作。

## 2026-11-08 安装与更新修复

本地脚本版本为 0.1.2。以下检查已通过：

- `sh -n install.sh`、Bash 脚本语法检查及 `git diff --check`。
- 安装与更新专项回归：完整分页、预发布展示、终端选版本与取消、非交互确认、同版本跳过；下载/配置/启动失败保留旧状态；无 Release、缺发布包、指定源码、自更新后菜单重新载入；损坏摘要、异常 API、残缺包和替换后自检失败；模拟 256 MiB 下缺 jq 时不调用包管理器。
- `bash tests/install-menu.sh`：单文件入口下载、安装参数、离线不联网、安装后自动打开菜单及节点向导。
- `XRAY_TEST_CORE=/tmp/xray-lite-live-xray bash tests/run.sh`：使用本次下载的官方 Xray v26.10.31 完成现有配置、协议、证书、导入导出和可靠性回归。本轮没有 Mihomo 二进制，其可选校验未执行。
- 官方下载文件专项验证：使用真实下载的 API 响应、官方二进制与项目源码归档，通过生产函数校验并安装到临时目录。jq 使用真实 SHA-256 和版本自检；Xray 完整分页、配置检查、核心路径和同版本跳过通过；项目无 Release，经默认分支源码更新与备份通过。

以上两项专项测试已在本轮执行，其临时测试脚本未纳入仓库。

已获网络权限后实际读取 GitHub：项目 Release 列表为空，默认分支为 `main`，源码版本仍为 0.1.1；Xray 发布列表为两页，最新发布为正式版 v26.10.31。本地修复尚未推送。

本次下载校验：

| 文件 | SHA-256 |
| --- | --- |
| jq 1.8.2 Linux amd64 | `b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f` |
| Xray v26.10.31 Linux 64 zip | `e4bd9119f50ae7c41658b1abd0679ae06f98bd864a2907ff33f2f2cf7081b214` |

下载使用真实 HTTPS 请求；处理阶段将下载请求映射到这些原始文件。测试只在临时目录写入，隔离了 root 入口与系统安装目标。本轮未执行宿主机 root 安装、apt/apk、systemd/OpenRC 服务操作，也未验证 ARM 和真实低内存硬限。

## 2026-10-24 初始验收

日期：2026-10-24。工作区从空目录建立。未安装到宿主机，未修改宿主机服务，未构建、下载或提供容器镜像。容器支持指已有容器内部安装与运行。

## 使用的真实二进制

- 官方 Xray v26.10.21，linux/amd64，官方 zip SHA-256：`0eec3ed4163c273d8c8bf821f7d219e257921cf584aa3fb970715e458e631978`。
- 官方 Mihomo v1.19.33，linux/amd64，官方 gz SHA-256：`132f6f3edf9a65e62f04853aed3358472e0b2b7666daa8419edfa2ddf5bb6323`。
- Bash、jq、OpenSSL 3.5.5。依赖与二进制下载已获得用户授权。

## 已执行

一键安装与菜单补充验证（`bash tests/install-menu.sh`，也纳入 `tests/run.sh`）：单文件 POSIX 入口使用本地下载夹具验证 `Haikure/xray-lite/main` 地址、参数传递、下载失败中止、离线模式不联网；通过伪终端验证安装后自动打开菜单；验证中文菜单渲染、节点序号选择、名称输入、EOF 取消和添加/修改向导。依赖安装及 GitHub 端到端下载安装本轮未执行，测试未修改宿主机或访问公网。

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
