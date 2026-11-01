#!/usr/bin/env bash
xl_download() {
    local url=$1 destination=$2
    [[ $url == https://* ]] || xl_die '只允许 HTTPS 下载。'
    curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 --retry 2 \
        --silent --show-error "$url" -o "$destination"
}
xl_release_select() {
    jq -e '[.[][] | select(.draft==false and .published_at!=null)] | sort_by(.published_at) | last // error("没有可用发布项")' "$1"
}
xl_release_fetch() {
    local repository=$1 destination=$2 page=1 count file dir
    dir=$(mktemp -d "$XL_STATE/release.XXXXXXXX")
    while :; do
        file="$dir/$page.json"
        xl_download "https://api.github.com/repos/$repository/releases?per_page=100&page=$page" "$file" || { rm -rf "$dir"; return 1; }
        jq -e 'type=="array"' "$file" >/dev/null || { rm -rf "$dir"; xl_die 'Release API 响应无效。'; }
        count=$(jq length "$file")
        jq -c '[.[]|select(.draft==false and .published_at!=null)]|sort_by(.published_at)|last' "$file" > "$dir/best-$page.json"
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
    [[ $(xl_hash "$archive") == "${digest#sha256:}" ]] || xl_die '下载摘要不符；停止更新。'
}
xl_core_edit() {
    local gen=$1 release asset tag arch stage path version release_status
    stage=$(mktemp -d "$XL_STATE/core-download.XXXXXXXX")
    if xl_release_fetch XTLS/Xray-core "$stage/release.json"; then :; else
        release_status=$?
        if (( release_status == 2 )); then xl_die 'XTLS/Xray-core 没有可用的已发布 Release。'; fi
        xl_die '获取 XTLS/Xray-core Release 失败。'
    fi
    release=$(cat "$stage/release.json"); tag=$(jq -r .tag_name <<< "$release"); arch=$(xl_arch)
    [[ $tag =~ ^v[0-9][0-9A-Za-z.-]+$ ]] || xl_die '官方发布版本格式无效。'
    asset=$(jq -ce --arg name "Xray-linux-$arch.zip" '.assets[] | select(.name==$name)' <<< "$release") || xl_die "最新发布 $tag 缺少 $arch 资产。"
    xl_download "$(jq -r .browser_download_url <<< "$asset")" "$stage/core.zip"
    xl_verify_asset "$asset" "$stage/core.zip"
    unzip -p "$stage/core.zip" xray > "$stage/xray"; chmod 700 "$stage/xray"
    version=$("$stage/xray" version | head -n 1)
    [[ $version == "Xray ${tag#v} "* ]] || xl_die "二进制版本与官方发布不符：$tag"
    timeout 30 "$stage/xray" run -test -config "$gen/config.json" >&2 || xl_die '新核心不接受当前配置，保留旧核心。'
    path="$XL_STATE/cores/$tag-$arch-$(xl_hash "$stage/xray")"
    [[ -e $path ]] || mv "$stage/xray" "$path"
    ln -sfn "$path" "$gen/core"
    cp "$stage/release.json" "$gen/core-release.json"
    rm -rf -- "$stage"
    xl_note "已校验官方核心 $tag。"
}
xl_script_archive_validate() {
    local archive=$1
    tar -tzf "$archive" | awk '/^\// || /(^|\/)\.\.($|\/)/ {exit 1}' || xl_die '脚本归档路径不安全。'
    tar -tvzf "$archive" | awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {exit 1}' || xl_die '脚本包不允许软链接、硬链接或设备文件。'
}
xl_script_source_branch() {
    local repository=$1 stage=$2 branch
    xl_download "https://api.github.com/repos/$repository" "$stage/repository.json" || xl_die '获取脚本仓库信息失败。'
    branch=$(jq -er 'select(type=="object" and (.default_branch|type)=="string" and (.default_branch|length)>0)|.default_branch' "$stage/repository.json") || xl_die '仓库没有有效的默认分支。'
    [[ $branch =~ ^[A-Za-z0-9._/-]+$ && $branch != /* && $branch != */ && $branch != *..* ]] || xl_die '仓库默认分支名称无效。'
    xl_download "https://codeload.github.com/$repository/tar.gz/refs/heads/$branch" "$stage/source.tar.gz" || xl_die '下载默认分支源码归档失败。'
    printf '%s' "$branch"
}
xl_script_update() (
    local repository=${1:-$XL_REPO} stage asset tag old release_status source_kind=release branch archive version script
    [[ $repository =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || xl_die '参数为 GitHub owner/repo。'
    stage=$(mktemp -d "$XL_HOME/script-update.XXXXXXXX")
    trap 'rm -rf -- "$stage"' EXIT
    if xl_release_fetch "$repository" "$stage/release.json"; then
        tag=$(jq -r .tag_name "$stage/release.json")
        asset=$(jq -ce '.assets[]|select(.name=="xray-lite.tar.gz")' "$stage/release.json") || xl_die '发布缺少 xray-lite.tar.gz。'
        archive="$stage/app.tar.gz"
        xl_download "$(jq -r .browser_download_url <<< "$asset")" "$archive"
        xl_verify_asset "$asset" "$archive"
    else
        release_status=$?
        (( release_status == 2 )) || xl_die "无法获取 $repository 的 Release。"
        xl_note "$repository 没有可用的已发布 Release，改用默认分支源码归档。"
        branch=$(xl_script_source_branch "$repository" "$stage")
        archive="$stage/source.tar.gz"; source_kind=branch
    fi
    xl_script_archive_validate "$archive"
    mkdir "$stage/app"
    if [[ $source_kind == branch ]]; then tar -xzf "$archive" --strip-components=1 --no-same-owner -C "$stage/app"
    else tar -xzf "$archive" --no-same-owner -C "$stage/app"; fi
    [[ -f $stage/app/xl && -d $stage/app/lib && -f $stage/app/VERSION ]] || xl_die '脚本归档结构无效。'
    sh -n "$stage/app/install.sh"
    for script in "$stage/app/xl" "$stage/app/install-local.sh" "$stage/app/"lib/*.sh; do bash -n "$script"; done
    chmod 755 "$stage/app/xl" "$stage/app/install.sh" "$stage/app/install-local.sh"
    version=$(cat "$stage/app/VERSION")
    [[ $(bash "$stage/app/xl" version) == "$version" ]] || xl_die '候选脚本自检失败。'
    if [[ $source_kind == branch ]]; then tag="$branch（v$version）"; fi
    [[ ! -e $XL_HOME/app.previous ]] || rm -rf -- "$XL_HOME/app.previous"
    old="$XL_HOME/app.previous"; mv "$XL_HOME/app" "$old"
    if ! mv "$stage/app" "$XL_HOME/app"; then mv "$old" "$XL_HOME/app"; xl_die '脚本替换失败，已恢复。'; fi
    xl_note "脚本已更新至 $tag；上一份保存在 $old。"
)
