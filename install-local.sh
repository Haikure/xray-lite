#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
XL_APP=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$XL_APP/lib/common.sh"
for module in environment service certificate release state nodes export relay forward argo interactive menu; do source "$XL_APP/lib/$module.sh"; done
xl_root
if [[ ${1:-} == --deps ]]; then
    if command -v apt-get >/dev/null; then apt-get update; apt-get install -y --no-install-recommends bash jq curl ca-certificates openssl unzip util-linux coreutils tar
    elif command -v apk >/dev/null; then apk add --no-cache bash jq curl ca-certificates openssl unzip util-linux coreutils tar
    else xl_die '请安装 Bash、jq、curl、系统 CA、OpenSSL、unzip、flock、timeout、tar。'; fi
    exit
fi
xl_need bash jq curl openssl unzip sha256sum flock timeout tar
xl_path_check
xl_install_local() (
mkdir -p "$(dirname "$XL_LINK")"
if [[ -e $XL_LINK && $(readlink -f "$XL_LINK") != "$XL_HOME/app/xl" ]]; then xl_die "快捷命令 $XL_LINK 已被其他程序占用。"; fi
stage=$(mktemp -d "$XL_HOME/install.XXXXXXXX")
app_replaced=0; completed=0
xl_install_cleanup() {
    local rc=$?
    trap - EXIT
    if (( completed==0 && app_replaced==1 )) && [[ -d $XL_HOME/app.previous ]]; then rm -rf -- "$XL_HOME/app"; mv "$XL_HOME/app.previous" "$XL_HOME/app"; fi
    rm -rf -- "$stage"
    exit "$rc"
}
trap xl_install_cleanup EXIT
mkdir "$stage/app"
cp -a "$XL_APP/xl" "$XL_APP/install.sh" "$XL_APP/install-local.sh" "$XL_APP/lib" "$XL_APP/VERSION" "$XL_APP/README.md" "$stage/app/"
chmod 755 "$stage/app/xl" "$stage/app/install.sh" "$stage/app/install-local.sh"
sh -n "$stage/app/install.sh"
for file in "$stage/app/xl" "$stage/app/install-local.sh" "$stage/app/"lib/*.sh; do bash -n "$file"; done
if [[ -d $XL_HOME/app ]]; then
    [[ ! -e $XL_HOME/app.previous ]] || rm -rf -- "$XL_HOME/app.previous"
    mv "$XL_HOME/app" "$XL_HOME/app.previous"
fi
if ! mv "$stage/app" "$XL_HOME/app"; then [[ ! -d $XL_HOME/app.previous ]] || mv "$XL_HOME/app.previous" "$XL_HOME/app"; xl_die '安装脚本失败。'; fi
app_replaced=1
ln -sfn "$XL_HOME/app/xl" "$XL_LINK"
export XL_HOME XL_STATE XL_RUN XL_LINK XL_SERVICE_MODE
XL_APP="$XL_HOME/app"
xl_bootstrap "$@"
completed=1
printf '安装完成。运行 xl 打开中文菜单。\n'
)
xl_lock xl_install_local "$@"
