#!/usr/bin/env bash
xl_download() {
    local url=$1 destination=$2 status rc
    local display=(--silent --show-error)
    [[ $url == https://* ]] || xl_die '只允许 HTTPS 下载。'
    [[ ! -t 2 ]] || display=(--progress-bar --show-error)
    xl_note "下载：$url"
    if status=$(curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 --retry 2 \
        "${display[@]}" --write-out '%{http_code}' "$url" -o "$destination"); then
        xl_note "下载完成：$(wc -c < "$destination") 字节"
    else
        rc=$?
        xl_note "下载失败（curl $rc，HTTP $status）：$url"
        case $status in 403|429) xl_note 'GitHub 可能触发访问限流，请稍后重试。';; 404) xl_note '版本、仓库或下载资产不存在。';; *) xl_note '请检查网络、DNS、系统时间和 CA 证书。';; esac
        return "$rc"
    fi
}
xl_release_select() {
    jq -e '[.[][] | select(.draft==false and .published_at!=null)] | sort_by(.published_at) | last // error("没有可用发布项")' "$1"
}
xl_release_fetch() {
    local repository=$1 destination=$2 catalog=${3:-} page=1 count file dir
    dir=$(mktemp -d "$XL_STATE/release.XXXXXXXX")
    [[ -z $catalog ]] || : > "$catalog"
    while :; do
        xl_note "检查 $repository 发布列表，第 $page 页…"
        file="$dir/$page.json"
        xl_download "https://api.github.com/repos/$repository/releases?per_page=100&page=$page" "$file" || { rm -rf "$dir"; return 1; }
        jq -e 'type=="array" and all(.[]; type=="object" and (.draft|type)=="boolean" and (.tag_name|type)=="string" and (.assets|type)=="array" and ((.published_at|type)=="string" or .published_at==null))' "$file" >/dev/null || { rm -rf "$dir"; xl_note 'Release API 响应无效。'; return 1; }
        count=$(jq length "$file")
        if [[ -n $catalog ]]; then
            jq -c '.[]|select(.draft==false and .published_at!=null)|{tag_name,published_at,prerelease}' "$file" >> "$catalog" || { rm -rf "$dir"; return 1; }
        fi
        jq -c '[.[]|select(.draft==false and .published_at!=null)]|sort_by(.published_at)|last' "$file" > "$dir/best-$page.json" || { rm -rf "$dir"; return 1; }
        rm -f -- "$file"
        (( count == 100 )) || break
        (( page += 1 )); (( page < 1000 )) || xl_die 'Release 分页数量异常。'
    done
    if ! jq -es '[.[]|select(.!=null)]|sort_by(.published_at)|last // empty' "$dir/"best-*.json > "$destination"; then
        rm -rf -- "$dir"; rm -f -- "$destination"; return 2
    fi
    rm -rf -- "$dir"
}
xl_verify_asset() {
    local asset=$1 archive=$2 digest
    digest=$(jq -r '.digest // ""' <<< "$asset")
    [[ $digest =~ ^sha256:([a-fA-F0-9]{64})$ ]] || xl_die '官方资产缺少有效的 SHA-256 摘要；停止更新。'
    digest=${digest#sha256:}
    [[ $(xl_hash "$archive") == "${digest,,}" ]] || xl_die '下载摘要不符；停止更新。'
}
xl_core_edit() (
    local gen=$1 stage release_status
    stage=$(mktemp -d "$XL_STATE/core-check.XXXXXXXX")
    trap 'rm -rf -- "$stage"' EXIT
    xl_note '检查官方 Xray 最新版本（含预发布）…'
    if xl_release_fetch XTLS/Xray-core "$stage/release.json"; then :; else
        release_status=$?
        if (( release_status == 2 )); then xl_die 'XTLS/Xray-core 没有可用的已发布 Release。'; fi
        xl_die '获取 XTLS/Xray-core Release 失败。'
    fi
    xl_core_install_release "$stage/release.json" "$gen"
)
xl_core_install_release() (
    local release_file=$1 gen=$2 release asset tag arch stage path version
    stage=$(mktemp -d "$XL_STATE/core-download.XXXXXXXX")
    trap 'rm -rf -- "$stage"' EXIT
    release=$(cat "$release_file"); tag=$(jq -r .tag_name <<< "$release"); arch=$(xl_arch)
    jq -e '.draft==false and .published_at!=null' <<< "$release" >/dev/null || xl_die '不是已发布的官方 Release。'
    [[ $tag =~ ^v[0-9][0-9A-Za-z.-]+$ ]] || xl_die '官方发布版本格式无效。'
    asset=$(jq -ce --arg name "Xray-linux-$arch.zip" '.assets[] | select(.name==$name)' <<< "$release") || xl_die "发布 $tag 缺少 $arch 资产。"
    xl_note "[1/4] 下载 Xray $tag（$arch）…"
    xl_download "$(jq -r .browser_download_url <<< "$asset")" "$stage/core.zip"
    xl_note '[2/4] 校验 SHA-256、解压并验证二进制版本…'
    xl_verify_asset "$asset" "$stage/core.zip"
    unzip -p "$stage/core.zip" xray > "$stage/xray"; chmod 700 "$stage/xray"
    version=$("$stage/xray" version | head -n 1)
    [[ $version == "Xray ${tag#v} "* ]] || xl_die "二进制版本与官方发布不符：$tag"
    xl_note '[3/4] 使用新核心检查当前配置…'
    timeout 30 "$stage/xray" run -test -config "$gen/config.json" >&2 || xl_die '新核心不接受当前配置，保留旧核心。'
    path="$XL_STATE/cores/$tag-$arch-$(xl_hash "$stage/xray")"
    [[ -e $path ]] || mv "$stage/xray" "$path"
    ln -sfn "$path" "$gen/core"
    cp "$release_file" "$gen/core-release.json"
    xl_note "已校验官方核心 $tag。"
    xl_note '[4/4] 提交核心与配置；服务正在运行时会重启，失败自动回滚…'
)
xl_core_update() (
    local action=$1 target='' yes=0 stage latest current answer tag
    shift
    while (( $# )); do
        case $1 in
            --yes) yes=1;;
            latest|v[0-9]*|[0-9]*) [[ -z $target ]] || xl_die '只能指定一个目标版本。'; target=$1;;
            *) xl_die '用法：xl core check | xl core update [latest|v版本] [--yes]';;
        esac
        shift
    done
    xl_root; xl_need jq curl
    xl_current >/dev/null
    stage=$(mktemp -d)
    trap 'rm -rf -- "$stage"' EXIT
    current=$(xl_installed_core_version)
    xl_note "当前 Xray：$current"
    xl_note "当前核心文件：$(readlink -f "$XL_STATE/current/core")"
    xl_release_fetch XTLS/Xray-core "$stage/release.json" "$stage/catalog.jsonl" || xl_die '检查官方版本失败；未修改当前核心。'
    latest=$(jq -r .tag_name "$stage/release.json")
    xl_note "最新发布：$latest（$(jq -r 'if .prerelease then "预发布" else "正式版" end' "$stage/release.json")）"
    if [[ $action == check ]]; then
        [[ $current != "${latest#v}" ]] || xl_note '当前已是最新发布版本。'
        return 0
    fi
    if (( yes == 0 )) && [[ ! -t 0 ]]; then xl_die '非交互更新需显式指定 --yes；可先运行 xl core check。'; fi
    if [[ -z $target ]] && (( yes == 0 )); then
        xl_note '近期版本（按发布时间排序）：'
        jq -sr 'sort_by(.published_at)|reverse|.[:10][]|"  \(.tag_name)  \(.published_at)  \(if .prerelease then "预发布" else "正式版" end)"' "$stage/catalog.jsonl" >&2
        xl_prompt '目标版本（输入版本号，或 latest；0 取消）' target "$latest" || { xl_note '已取消更新。'; return 0; }
        [[ $target != 0 ]] || { xl_note '已取消更新。'; return 0; }
    fi
    target=${target:-latest}
    if [[ $target == latest ]]; then target=$latest; fi
    [[ $target == v* ]] || target="v$target"
    [[ $target =~ ^v[0-9][0-9A-Za-z.-]+$ ]] || xl_die '目标版本格式无效。'
    if [[ $target != "$latest" ]]; then
        xl_download "https://api.github.com/repos/XTLS/Xray-core/releases/tags/$target" "$stage/release.json" || xl_die "无法获取目标版本 $target。"
    fi
    tag=$(jq -r .tag_name "$stage/release.json")
    [[ $tag == "$target" ]] || xl_die '目标版本与发布信息不符。'
    jq -e --arg name "Xray-linux-$(xl_arch).zip" '.draft==false and .published_at!=null and any(.assets[]; .name==$name and (.digest|type)=="string" and (.digest|test("^sha256:[a-fA-F0-9]{64}$")))' "$stage/release.json" >/dev/null || xl_die '目标发布缺少当前架构或有效摘要。'
    if [[ $current == "${target#v}" ]]; then xl_note "当前已是 $target，无需更新。"; return 0; fi
    xl_note "准备将 Xray $current → $target（$(jq -r 'if .prerelease then "预发布" else "正式版" end' "$stage/release.json")）。运行中的服务将重启。"
    if (( yes == 0 )); then
        xl_prompt '确认安装此版本？y/N' answer N || { xl_note '已取消更新。'; return 0; }
        case $answer in y|Y|yes|YES) ;; *) xl_note '已取消更新。'; return 0;; esac
    fi
    xl_lock xl_transaction xl_core_install_release "$stage/release.json"
    xl_note "Xray-core 更新成功，当前版本：$(xl_installed_core_version)。"
    xl_note "核心文件：$(readlink -f "$XL_STATE/current/core")"
)
xl_script_archive_validate() {
    local archive=$1
    tar -tzf "$archive" | awk '/^\// || /(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' || xl_die '脚本归档路径不安全。'
    tar -tvzf "$archive" | awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {bad=1} END {exit bad}' || xl_die '脚本包不允许软链接、硬链接或设备文件。'
}
xl_script_source_branch() {
    local repository=$1 stage=$2 branch=${3:-main}
    [[ $branch =~ ^[A-Za-z0-9._/-]+$ && $branch != /* && $branch != */ && $branch != *..* ]] || xl_die '分支或标签名称无效。'
    xl_note "从 $repository 的 $branch 源码更新…"
    xl_download "https://codeload.github.com/$repository/tar.gz/$branch" "$stage/source.tar.gz" || xl_die '下载源码归档失败。'
    printf '%s' "$branch"
}
xl_script_validate() {
    local app=$1 script version
    for script in xl VERSION README.md install.sh install-local.sh; do
        [[ -f $app/$script ]] || xl_die "脚本归档缺少 $script。"
    done
    for script in common environment service certificate release state nodes export relay forward argo interactive menu; do
        [[ -f $app/lib/$script.sh ]] || xl_die "脚本归档缺少 lib/$script.sh。"
    done
    for script in model client create mihomo import; do
        [[ -f $app/lib/$script.jq ]] || xl_die "脚本归档缺少 lib/$script.jq。"
    done
    sh -n "$app/install.sh" || xl_die '安装入口语法检查失败。'
    for script in "$app/xl" "$app/install-local.sh" "$app/"lib/*.sh; do
        bash -n "$script" || xl_die "脚本语法检查失败：$script"
    done
    version=$(cat "$app/VERSION")
    [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || xl_die '脚本 VERSION 格式无效。'
    [[ $(bash "$app/xl" version) == "$version" ]] || xl_die '候选脚本自检失败。'
    printf '%s' "$version"
}
xl_script_update() (
    local repository=$XL_REPO ref=main stage tag old branch archive version replaced=0 completed=0
    if [[ $# -gt 0 && $1 != --* ]]; then repository=$1; shift; fi
    if (( $# )); then
        [[ $# == 2 && $1 == --ref && -n $2 ]] || xl_die '用法：xl script update [owner/repo] [--ref 分支或标签]'
        ref=$2
    fi
    [[ $repository =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || xl_die '参数为 GitHub owner/repo。'
    stage=$(mktemp -d "$XL_HOME/script-update.XXXXXXXX")
    old="$XL_HOME/app.previous"
    xl_script_cleanup() {
        local rc=$?
        trap - EXIT
        if (( replaced && ! completed )); then
            rm -rf -- "$XL_HOME/app"
            mv "$old" "$XL_HOME/app"
            xl_note '脚本更新失败，已恢复上一份。'
        fi
        rm -rf -- "$stage"
        exit "$rc"
    }
    trap xl_script_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    xl_note "[1/4] 检查脚本更新；当前版本：$(cat "$XL_HOME/app/VERSION")；来源：$repository"
    xl_note '[2/4] 下载脚本源码…'
    branch=$(xl_script_source_branch "$repository" "$stage" "$ref")
    archive="$stage/source.tar.gz"
    xl_note '[3/4] 检查归档、脚本语法和版本…'
    xl_script_archive_validate "$archive"
    mkdir "$stage/app"
    tar -xzf "$archive" --strip-components=1 --no-same-owner -C "$stage/app"
    version=$(xl_script_validate "$stage/app")
    chmod 755 "$stage/app/xl" "$stage/app/install.sh" "$stage/app/install-local.sh"
    tag="$branch（v$version）"
    [[ ! -e $XL_HOME/app.previous ]] || rm -rf -- "$XL_HOME/app.previous"
    xl_note "[4/4] 安装脚本 $tag 到 $XL_HOME/app…"
    mv "$XL_HOME/app" "$old"
    replaced=1
    mv "$stage/app" "$XL_HOME/app"
    [[ $(bash "$XL_HOME/app/xl" version) == "$version" ]] || xl_die '替换后的脚本自检失败。'
    completed=1
    xl_note "脚本已更新至 $tag；上一份保存在 $old。"
)
