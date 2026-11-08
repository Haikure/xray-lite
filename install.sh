#!/bin/sh
# Standalone POSIX bootstrap: also runs on Alpine before Bash is installed.
set -eu
umask 077
PATH=/usr/local/bin:$PATH
export PATH
XL_REPO=${XL_REPO:-Haikure/xray-lite}
XL_REF=${XL_REF:-main}
export XL_REPO
die() { printf '错误：%s\n' "$*" >&2; exit 1; }
case ${1-} in
    --help|-h)
        printf '%s\n' '用法：sh install.sh [--no-menu] [--no-start] [--offline release.json core.zip]'
        printf '%s\n' '      sh install.sh --script-only（仅更新已安装的管理脚本）'
        printf '%s\n' '自动准备依赖并安装官方最新 Xray，交互终端安装完成后打开 xl 菜单。'
        exit 0;;
esac
[ "$(id -u)" -eq 0 ] || die '请在 VPS 或已有容器内使用 root 运行。'

memory_limit_bytes() {
    memory_limit=$(awk '/MemTotal:/ {printf "%.0f", $2*1024; exit}' /proc/meminfo 2>/dev/null) || return 1
    case $memory_limit in ''|*[!0-9]*) return 1;; esac
    for memory_file in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
        [ -r "$memory_file" ] || continue
        IFS= read -r memory_value < "$memory_file" || continue
        case $memory_value in ''|*[!0-9]*) continue;; esac
        [ "$memory_value" -gt 0 ] || continue
        if [ "$memory_value" -lt "$memory_limit" ]; then memory_limit=$memory_value; fi
    done
    printf '%s\n' "$memory_limit"
}
jq_asset_for_arch() {
    case $(uname -m) in
        x86_64|amd64) printf 'jq-linux-amd64';;
        aarch64|arm64) printf 'jq-linux-arm64';;
        armv7*|armhf) printf 'jq-linux-armhf';;
        *) return 1;;
    esac
}
bootstrap_download() {
    printf '下载：%s\n' "$1" >&2
    if [ -t 2 ]; then download_display=--progress-bar; else download_display=--silent; fi
    curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 --retry 2 \
        "$download_display" --show-error "$1" -o "$2" || die "下载失败：$1（请检查网络、DNS 和系统时间）"
    printf '下载完成：%s 字节\n' "$(wc -c < "$2")" >&2
}
install_jq_binary() (
    jq_asset=$(jq_asset_for_arch) || die "不支持的 jq 架构：$(uname -m)"
    # Pinned official checksums: https://jqlang.org/download/
    case $jq_asset in
        jq-linux-amd64) jq_digest=b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f;;
        jq-linux-arm64) jq_digest=8b85c817833814ddca00a144c33705546355afccf0cf39b188f3cdb48b852309;;
        jq-linux-armhf) jq_digest=78458244fb546469b4042e9e07cf78714ef6848895eb9515df76b4eb0b1dc992;;
    esac
    mkdir -p /usr/local/bin
    jq_stage=$(mktemp -d /usr/local/bin/.xl-jq.XXXXXXXX)
    trap 'rm -rf -- "$jq_stage"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    bootstrap_download "https://github.com/jqlang/jq/releases/download/jq-1.8.2/$jq_asset" "$jq_stage/jq"
    printf '校验 jq SHA-256…\n' >&2
    [ "$(sha256sum "$jq_stage/jq" | awk '{print $1}')" = "$jq_digest" ] || die 'jq 摘要不符，未安装。'
    chmod 755 "$jq_stage/jq"
    [ "$("$jq_stage/jq" --version)" = jq-1.8.2 ] || die 'jq 二进制无法运行或版本不符。'
    "$jq_stage/jq" -en 'true' >/dev/null || die 'jq 自检失败。'
    mv -f "$jq_stage/jq" /usr/local/bin/jq
    printf 'jq 1.8.2 已安装：/usr/local/bin/jq\n' >&2
)
prepare_dependencies() {
    packages='' jq_binary=0
    printf '[1/5] 检查安装依赖…\n' >&2
    memory_limit=$(memory_limit_bytes 2>/dev/null || true)
    for tool in bash jq curl openssl unzip flock timeout sha256sum tar mktemp readlink; do
        if command -v "$tool" >/dev/null 2>&1; then continue; fi
        printf '缺少依赖：%s\n' "$tool" >&2
        if [ "$tool" = jq ] && [ -n "$memory_limit" ] && [ "$memory_limit" -le 536870912 ]; then
            printf '内存限制约 %s MiB，jq 将使用官方独立二进制，减少包管理器开销。\n' "$((memory_limit / 1048576))" >&2
            jq_binary=1
            continue
        fi
        case $tool in flock) package=util-linux;; timeout|sha256sum|mktemp|readlink) package=coreutils;; *) package=$tool;; esac
        case " $packages " in *" $package "*) ;; *) packages="$packages $package";; esac
    done
    if ! [ -s /etc/ssl/certs/ca-certificates.crt ] && ! [ -s /etc/ssl/cert.pem ]; then packages="$packages ca-certificates"; fi
    if [ -n "$packages" ]; then
        printf '正在安装缺少的依赖：%s\n' "$packages" >&2
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update || die 'apt 软件源更新失败。'
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $packages || die 'apt 依赖安装失败。'
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache $packages || die 'apk 依赖安装失败。'
        else
            die "请先安装依赖：$packages"
        fi
    fi
    if [ "$jq_binary" -eq 1 ]; then install_jq_binary; fi
    for tool in bash jq curl openssl unzip flock timeout sha256sum tar mktemp readlink; do
        command -v "$tool" >/dev/null 2>&1 || die "依赖安装后仍不可用：$tool"
    done
    jq -en 'true' >/dev/null || die 'jq 无法正常运行，请检查安装文件。'
    printf '依赖检查完成：%s\n' "$(jq --version)" >&2
}

case ${1-} in --deps) prepare_dependencies; exit 0;; esac
no_menu=0 script_only=0
# Offline installation must not cause package or repository requests.
offline=0
for argument in "$@"; do
    shift
    case $argument in
        --no-menu) no_menu=1;;
        --script-only) script_only=1; no_menu=1; set -- "$@" "$argument";;
        --offline) offline=1; set -- "$@" "$argument";;
        *) set -- "$@" "$argument";;
    esac
done
if [ "$script_only" -eq 1 ]; then
    for argument in "$@"; do [ "$argument" = --script-only ] || die '--script-only 不能与核心安装参数一起使用。'; done
    [ -f "${XL_HOME:-/opt/xray-lite}/app/VERSION" ] && [ -f "${XL_STATE:-/var/lib/xray-lite}/current/config.json" ] || die '未找到已有安装；首次安装请运行不带 --script-only 的安装命令。'
    for tool in bash jq curl tar; do command -v "$tool" >/dev/null 2>&1 || die "缺少迁移依赖：$tool"; done
    printf '仅迁移管理脚本，保留当前 Xray 核心、配置和运行状态。\n' >&2
elif [ "$offline" -eq 0 ]; then prepare_dependencies; fi

source_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
download_dir=''
trap 'if [ -n "$download_dir" ]; then rm -rf -- "$download_dir"; fi' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ ! -f "$source_dir/install-local.sh" ] || [ ! -f "$source_dir/lib/common.sh" ]; then
    [ "$offline" -eq 0 ] || die '离线安装需先下载完整仓库。'
    case $XL_REPO in *[!A-Za-z0-9_./-]*|*/../*|../*|/*) die '仓库名称无效。';; esac
    case $XL_REF in ''|*[!A-Za-z0-9_.-]*|..*) die '分支或标签名称无效。';; esac
    download_dir=$(mktemp -d)
    printf '获取脚本 %s (%s)…\n' "$XL_REPO" "$XL_REF" >&2
    bootstrap_download "https://codeload.github.com/$XL_REPO/tar.gz/$XL_REF" "$download_dir/source.tar.gz"
    tar -tzf "$download_dir/source.tar.gz" | awk '/^\// || /(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' || die '下载的归档路径无效。'
    tar -tvzf "$download_dir/source.tar.gz" | awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {bad=1} END {exit bad}' || die '下载的归档包含不支持的文件类型。'
    mkdir "$download_dir/source"
    tar -xzf "$download_dir/source.tar.gz" --strip-components=1 --no-same-owner -C "$download_dir/source"
    source_dir="$download_dir/source"
    [ -f "$source_dir/install-local.sh" ] && [ -f "$source_dir/lib/common.sh" ] && [ -f "$source_dir/xl" ] || die '下载的仓库文件不完整。'
fi
XL_DEPS_READY=1 bash "$source_dir/install-local.sh" "$@"
if [ "$no_menu" -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then
    bash "${XL_HOME:-/opt/xray-lite}/app/xl" menu
fi
