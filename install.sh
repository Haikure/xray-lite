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

prepare_dependencies() {
    missing=0
    for tool in bash jq curl openssl unzip flock timeout sha256sum tar mktemp readlink; do
        command -v "$tool" >/dev/null 2>&1 || missing=1
    done
    [ -s /etc/ssl/certs/ca-certificates.crt ] || [ -s /etc/ssl/cert.pem ] || missing=1
    [ "$missing" -ne 0 ] || return 0
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
