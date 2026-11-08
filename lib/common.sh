#!/usr/bin/env bash
# Paths are independent of any existing Xray installation.
export PATH="/usr/local/bin:$PATH"
: "${XL_HOME:=/opt/xray-lite}"
: "${XL_STATE:=/var/lib/xray-lite}"
: "${XL_RUN:=/run/xray-lite}"
: "${XL_LINK:=/usr/local/bin/xl}"
: "${XL_SERVICE_MODE:=auto}"
: "${XL_REPO:=Haikure/xray-lite}"
export XL_HOME XL_STATE XL_RUN XL_LINK XL_SERVICE_MODE XL_REPO

xl_die() { printf '错误：%s\n' "$*" >&2; exit 1; }
xl_note() { printf '%s\n' "$*" >&2; }
xl_need() { local c; for c in "$@"; do command -v "$c" >/dev/null || xl_die "缺少依赖 $c；运行 bash install.sh --deps"; done; }
xl_root() { (( EUID == 0 )) || xl_die '需要容器内 root 或 VPS root。'; }
xl_id() { openssl rand -hex 8; }
xl_hash() { sha256sum "$1" | awk '{print $1}'; }
xl_json() { jq -cn --arg value "$1" '$value'; }
xl_uri() { jq -rn --arg value "$1" '$value|@uri'; }
xl_hostport() { local host=${1#[}; host=${host%]}; if [[ $host == *:* ]]; then printf '[%s]:%s' "$host" "$2"; else printf '%s:%s' "$host" "$2"; fi; }
xl_jq() { local path=$1; shift; jq "$@" "$path" > "$path.tmp" || { rm -f -- "$path.tmp"; return 1; }; mv -f -- "$path.tmp" "$path"; }
xl_path_check() {
    local p
    for p in "$XL_HOME" "$XL_STATE" "$XL_RUN" "$XL_LINK"; do
        [[ $p =~ ^/[a-zA-Z0-9_./-]+$ && $p != *'..'* && $p != */ ]] || xl_die '路径必须为无空白和特殊字符的绝对路径。'
        case $p in /bin|/sbin|/usr|/usr/bin|/usr/sbin|/usr/local|/etc|/var|/var/lib|/run|/tmp|/home|/root|/opt) xl_die "不能将系统目录作为项目目录：$p";; esac
    done
    [[ $XL_STATE != "$XL_HOME" && $XL_RUN != "$XL_STATE" && $XL_RUN != "$XL_HOME" ]] || xl_die '程序、状态和运行目录必须独立。'
}
xl_current() { [[ -f $XL_STATE/current/config.json ]] || xl_die '尚未安装：bash install.sh'; readlink -f "$XL_STATE/current"; }
xl_core() { printf '%s/core' "${1:-$(xl_current)}"; }
xl_lock() (
    xl_root; xl_need jq openssl curl unzip sha256sum flock timeout
    xl_path_check
    xl_prepare_dir "$XL_STATE"; xl_prepare_dir "$XL_RUN"; xl_prepare_dir "$XL_HOME"
    exec 9>"$XL_STATE/lock"
    flock -w 30 9 || xl_die '另一项修改正在进行，请稍后重试。'
    "$@"
)
xl_prepare_dir() {
    local dir=$1
    [[ ! -L $dir ]] || xl_die "项目目录不能是软链接：$dir"
    if [[ -d $dir && ! -f $dir/.xray-lite-owned && -n $(ls -A "$dir") ]]; then xl_die "目录非空且不属于本项目：$dir"; fi
    mkdir -p "$dir"; chmod 700 "$dir"
    printf 'xray-lite\n' > "$dir/.xray-lite-owned"
}
xl_read() (
    xl_need jq openssl flock
    [[ -f $XL_STATE/lock ]] || xl_die '尚未安装。'
    exec 9<"$XL_STATE/lock"; flock -s -w 30 9 || xl_die '等待修改完成超时。'
    XL_GEN=$(xl_current); export XL_GEN
    "$@"
)
xl_validate_json() { jq -e 'type=="object"' "$1" >/dev/null || xl_die "JSON 对象无效：$1"; }
xl_port() { [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
xl_address() { [[ -n $1 && $1 != *[$'\n\r\t /@#?']* && $1 != -* ]]; }
xl_opts() {
    # JSON spec or --key value. Secrets can be supplied with a protected spec file.
    if [[ ${1:-} == --file ]]; then [[ $# == 2 ]] || xl_die '用法：--file spec.json'; xl_validate_json "$2"; cat "$2"; return; fi
    local result='{}' key
    while (( $# )); do
        [[ $# -ge 2 && $1 == --* ]] || xl_die "参数需要 --名称 值：$1"
        key=${1#--}; key=${key//-/_}
        result=$(jq -cn --argjson o "$result" --arg k "$key" --arg v "$2" '$o+{($k):$v}')
        shift 2
    done
    printf '%s\n' "$result"
}
