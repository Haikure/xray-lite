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
    jq -es '[.[]|select(.!=null)]|sort_by(.published_at)|last // error("没有可用发布项")' "$dir/"best-*.json > "$destination"
    rm -rf -- "$dir"
}
xl_verify_asset() {
    local asset=$1 archive=$2 digest
    digest=$(jq -r '.digest // ""' <<< "$asset")
    [[ $digest =~ ^sha256:([a-fA-F0-9]{64})$ ]] || xl_die '官方资产缺少有效的 SHA-256 摘要；停止更新。'
    [[ $(xl_hash "$archive") == "${digest#sha256:}" ]] || xl_die '下载摘要不符；停止更新。'
}
xl_core_edit() {
    local gen=$1 release asset tag arch stage path version
    stage=$(mktemp -d "$XL_STATE/core-download.XXXXXXXX")
    xl_release_fetch XTLS/Xray-core "$stage/release.json"
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
xl_script_update() {
    local repository=$1 stage asset tag old
    [[ $repository =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || xl_die '参数为 GitHub owner/repo。'
    stage=$(mktemp -d "$XL_HOME/script-update.XXXXXXXX")
    xl_release_fetch "$repository" "$stage/release.json"
    tag=$(jq -r .tag_name "$stage/release.json")
    asset=$(jq -ce '.assets[]|select(.name=="xray-lite.tar.gz")' "$stage/release.json") || xl_die '发布缺少 xray-lite.tar.gz。'
    xl_download "$(jq -r .browser_download_url <<< "$asset")" "$stage/app.tar.gz"; xl_verify_asset "$asset" "$stage/app.tar.gz"
    tar -tzf "$stage/app.tar.gz" | awk '/^\// || /(^|\/)\.\.($|\/)/ {exit 1}' || xl_die '归档路径不安全。'
    tar -tvzf "$stage/app.tar.gz" | awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {exit 1}' || xl_die '脚本包不允许软链接、硬链接或设备文件。'
    mkdir "$stage/app"; tar -xzf "$stage/app.tar.gz" --no-same-owner -C "$stage/app"
    [[ -f $stage/app/xl && -d $stage/app/lib && -f $stage/app/VERSION ]] || xl_die '脚本归档结构无效。'
    local script
    for script in "$stage/app/xl" "$stage/app/install.sh" "$stage/app/"lib/*.sh; do bash -n "$script"; done
    chmod 755 "$stage/app/xl" "$stage/app/install.sh"
    [[ $(bash "$stage/app/xl" version) == "$(cat "$stage/app/VERSION")" ]] || xl_die '候选脚本自检失败。'
    [[ ! -e $XL_HOME/app.previous ]] || rm -rf -- "$XL_HOME/app.previous"
    old="$XL_HOME/app.previous"; mv "$XL_HOME/app" "$old"
    if ! mv "$stage/app" "$XL_HOME/app"; then mv "$old" "$XL_HOME/app"; xl_die '脚本替换失败，已恢复。'; fi
    rm -rf -- "$stage"
    xl_note "脚本已更新至 $tag；上一份保存在 $old。"
}
