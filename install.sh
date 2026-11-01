#!/bin/sh
# Standalone POSIX bootstrap: also runs on Alpine before Bash is installed.
set -eu
umask 077
XL_REPO=${XL_REPO:-Haikure/xray-lite}
XL_REF=${XL_REF:-main}
export XL_REPO
die() { printf '错误：%s\n' "$*" >&2; exit 1; }
case ${1-} in
    --help|-h)
        printf '%s\n' '用法：sh install.sh [--no-menu] [--no-start] [--offline release.json core.zip]'
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
jq_binary_hint() {
    jq_memory_mib=$(( $1 / 1048576 ))
    jq_asset=$(jq_asset_for_arch 2>/dev/null || true)
    printf '检测到内存限制约 %s MiB（不超过 512 MiB），缺少 jq；跳过 apt/apk 以避免 OOM。\n' "$jq_memory_mib" >&2
    printf 'jq 官方发布页：https://github.com/jqlang/jq/releases\n' >&2
    if [ -n "$jq_asset" ]; then
        printf '请直接安装对应架构的 jq 二进制：\n' >&2
        printf '  mkdir -p /usr/local/bin\n' >&2
        printf '  wget -O /usr/local/bin/jq https://github.com/jqlang/jq/releases/latest/download/%s\n' "$jq_asset" >&2
        printf '  chmod +x /usr/local/bin/jq\n' >&2
    else
        printf '请下载适用于 %s 的 Linux jq 二进制，放到 /usr/local/bin/jq 并赋予执行权限。\n' "$(uname -m)" >&2
    fi
    printf '安装后重新运行原安装命令。\n' >&2
}
prepare_dependencies() {
    missing=0 jq_missing=0
    for tool in bash jq curl openssl unzip flock timeout sha256sum tar mktemp readlink; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing=1
            [ "$tool" != jq ] || jq_missing=1
        fi
    done
    [ -s /etc/ssl/certs/ca-certificates.crt ] || [ -s /etc/ssl/cert.pem ] || missing=1
    [ "$missing" -ne 0 ] || return 0
    if [ "$jq_missing" -eq 1 ]; then
        memory_limit=$(memory_limit_bytes 2>/dev/null || true)
        case $memory_limit in
            ''|*[!0-9]*) ;;
            *)
                if [ "$memory_limit" -le 536870912 ]; then
                    jq_binary_hint "$memory_limit"
                    die '低内存环境缺少 jq；安装后请重新运行。'
                fi;;
        esac
    fi
    printf '正在安装 xray-lite 所需依赖…\n' >&2
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends bash jq curl ca-certificates openssl unzip util-linux coreutils tar
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache bash jq curl ca-certificates openssl unzip util-linux coreutils tar
    else
        die '请安装 Bash、jq、curl、CA 证书、OpenSSL、unzip、flock、timeout、coreutils 和 tar。'
    fi
}

case ${1-} in --deps) prepare_dependencies; exit 0;; esac
no_menu=0
if [ "${1-}" = --no-menu ]; then no_menu=1; shift; fi
# Offline installation must not cause package or repository requests.
offline=0
for argument in "$@"; do [ "$argument" != --offline ] || offline=1; done
if [ "$offline" -eq 0 ]; then prepare_dependencies; fi

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
    printf '正在下载 %s (%s)…\n' "$XL_REPO" "$XL_REF" >&2
    curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 --retry 2 \
        --silent --show-error "https://codeload.github.com/$XL_REPO/tar.gz/$XL_REF" -o "$download_dir/source.tar.gz"
    tar -tzf "$download_dir/source.tar.gz" | awk '/^\// || /(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' || die '下载的归档路径无效。'
    tar -tvzf "$download_dir/source.tar.gz" | awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {bad=1} END {exit bad}' || die '下载的归档包含不支持的文件类型。'
    mkdir "$download_dir/source"
    tar -xzf "$download_dir/source.tar.gz" --strip-components=1 --no-same-owner -C "$download_dir/source"
    source_dir="$download_dir/source"
    [ -f "$source_dir/install-local.sh" ] && [ -f "$source_dir/lib/common.sh" ] && [ -f "$source_dir/xl" ] || die '下载的仓库文件不完整。'
fi
bash "$source_dir/install-local.sh" "$@"
if [ "$no_menu" -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then
    bash "${XL_HOME:-/opt/xray-lite}/app/xl" menu
fi
