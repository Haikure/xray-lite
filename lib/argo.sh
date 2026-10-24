#!/usr/bin/env bash
xl_argo_install() {
    local stage arch asset path
    stage=$(mktemp -d "$XL_STATE/cloudflared.XXXXXXXX")
    case $(xl_arch) in 64) arch=amd64;; arm64-v8a) arch=arm64;; arm32-v7a) arch=arm;; esac
    xl_release_fetch cloudflare/cloudflared "$stage/release.json"
    asset=$(jq -ce --arg name "cloudflared-linux-$arch" '.assets[]|select(.name==$name)' "$stage/release.json") || xl_die '最新 cloudflared 缺少此架构。'
    xl_download "$(jq -r .browser_download_url <<< "$asset")" "$stage/cloudflared"
    xl_verify_asset "$asset" "$stage/cloudflared"
    chmod 700 "$stage/cloudflared"; "$stage/cloudflared" version
    path="$XL_STATE/cloudflared-$(xl_hash "$stage/cloudflared")"
    mv "$stage/cloudflared" "$path"; ln -sfn "$path" "$XL_STATE/cloudflared"
    rm -rf "$stage"
}
xl_argo_attach_edit() {
    local id=$1 spec=$2 gen=$3 net kind hostname tunnel credentials
    xl_node_exists "$gen" "$id"
    [[ -x $XL_STATE/cloudflared ]] || xl_die '先运行 xl argo install。'
    net=$(jq -r --arg tag "xl-$id" '.inbounds[]|select(.tag==$tag)|.streamSettings.method // .streamSettings.network' "$gen/config.json")
    [[ $net == ws || $net == websocket ]] || xl_die 'Argo 入口需要 VLESS-WS 或 Trojan-WS。'
    jq -e --arg tag "xl-$id" '.inbounds[]|select(.tag==$tag)|.protocol=="vless" or .protocol=="trojan"' "$gen/config.json" >/dev/null || xl_die 'Argo 协议不支持。'
    kind=$(jq -r '.kind // "quick"' <<< "$spec")
    [[ $kind == quick || $kind == fixed ]] || xl_die '隧道类型为 quick 或 fixed。'
    if [[ $kind == fixed ]]; then
        hostname=$(jq -r '.hostname // ""' <<< "$spec"); tunnel=$(jq -r '.tunnel_id // ""' <<< "$spec"); credentials=$(jq -r '.credentials // ""' <<< "$spec")
        xl_address "$hostname" && [[ $tunnel =~ ^[0-9a-fA-F-]{36}$ ]] || xl_die '固定隧道需要 hostname、tunnel_id 和 credentials。'
        jq -e --arg id "$tunnel" '.TunnelID==$id and (.TunnelSecret|length)>0 and (.AccountTag|length)>0' "$credentials" >/dev/null || xl_die '固定隧道凭据无效。'
        mkdir -p "$gen/argo"; cp "$credentials" "$gen/argo/$id.credentials.json"; chmod 600 "$gen/argo/$id.credentials.json"
        spec=$(jq --arg credentials "$gen/argo/$id.credentials.json" '.credentials=$credentials' <<< "$spec")
    fi
    xl_jq "$gen/meta.json" --arg id "$id" --argjson spec "$spec" '.argo[$id]=$spec|.argo[$id].kind=(.argo[$id].kind // "quick")'
}
xl_argo_delete_edit() { local id=$1 gen=$2; xl_jq "$gen/meta.json" --arg id "$id" 'del(.argo[$id])'; }
xl_argo_stop() {
    local file pid actual count
    for file in "$XL_RUN/"argo-*.pid; do
        [[ -f $file ]] || continue
        read -r pid < "$file"
        if [[ $pid =~ ^[0-9]+$ ]]; then
            actual=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
            if [[ $actual == "$XL_STATE/cloudflared-"* ]]; then
                kill -TERM "$pid" 2>/dev/null || true
                for count in {1..30}; do kill -0 "$pid" 2>/dev/null || break; [[ $(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null) == Z ]] && break; sleep .1; done
                if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
            fi
        fi
        rm -f "$file"
    done
}
xl_argo_reconcile() {
    local gen=$1 id spec kind port security sni cert args hostname tunnel
    xl_argo_stop
    while IFS= read -r id; do
        spec=$(jq -c --arg id "$id" '.argo[$id]' "$gen/meta.json"); kind=$(jq -r .kind <<< "$spec")
        port=$(jq -r --arg tag "xl-$id" '.inbounds[]|select(.tag==$tag)|.port' "$gen/config.json")
        security=$(jq -r --arg tag "xl-$id" '.inbounds[]|select(.tag==$tag)|.streamSettings.security' "$gen/config.json")
        args=(tunnel --no-autoupdate)
        local origin='http'; [[ $security != tls ]] || origin=https
        if [[ $kind == quick ]]; then
            args+=(--url "$origin://127.0.0.1:$port")
            if [[ $security == tls ]]; then
                sni=$(jq -r --arg tag "xl-$id" '.inbounds[]|select(.tag==$tag)|.streamSettings.tlsSettings.serverName' "$gen/config.json")
                cert=$(jq -r --arg tag "xl-$id" '.inbounds[]|select(.tag==$tag)|.streamSettings.tlsSettings.certificates[0].certificateFile' "$gen/config.json")
                args+=(--origin-server-name "$sni" --origin-ca-pool "$cert")
            fi
        else
            hostname=$(jq -r .hostname <<< "$spec"); tunnel=$(jq -r .tunnel_id <<< "$spec")
            jq -n --arg tunnel "$tunnel" --arg credentials "$(jq -r .credentials <<< "$spec")" --arg host "$hostname" --arg origin "$origin://127.0.0.1:$port" \
                '{tunnel:$tunnel,"credentials-file":$credentials,ingress:[{hostname:$host,service:$origin},{service:"http_status:404"}]}' > "$XL_RUN/argo-$id.json"
            if [[ $security == tls ]]; then
                sni=$(jq -r --arg tag "xl-$id" '.inbounds[]|select(.tag==$tag)|.streamSettings.tlsSettings.serverName' "$gen/config.json")
                cert=$(jq -r --arg tag "xl-$id" '.inbounds[]|select(.tag==$tag)|.streamSettings.tlsSettings.certificates[0].certificateFile' "$gen/config.json")
                xl_jq "$XL_RUN/argo-$id.json" --arg sni "$sni" --arg cert "$cert" '.ingress[0].originRequest={originServerName:$sni,caPool:$cert}'
            fi
            args+=(--config "$XL_RUN/argo-$id.json" run "$tunnel")
        fi
        if [[ -f $XL_STATE/logs/argo-$id.log ]]; then mv -f "$XL_STATE/logs/argo-$id.log" "$XL_STATE/logs/argo-$id.log.1"; fi
        : > "$XL_STATE/logs/argo-$id.log"
        nohup "$XL_STATE/cloudflared" "${args[@]}" >> "$XL_STATE/logs/argo-$id.log" 2>&1 < /dev/null 9>&- &
        printf '%s\n' "$!" > "$XL_RUN/argo-$id.pid"
        sleep 1
        kill -0 "$(cat "$XL_RUN/argo-$id.pid")" 2>/dev/null || { tail -n 15 "$XL_STATE/logs/argo-$id.log" >&2; return 1; }
    done < <(jq -r '.argo|keys[]' "$gen/meta.json")
}
xl_argo_endpoint() {
    local id=$1 gen=$2 kind hostname
    kind=$(jq -r --arg id "$id" '.argo[$id].kind // "none"' "$gen/meta.json")
    [[ $kind != none ]] || return 0
    if [[ $kind == fixed ]]; then jq -r --arg id "$id" '.argo[$id].hostname' "$gen/meta.json"
    else
        hostname=$(sed -nE 's/.*https:\/\/([a-z0-9-]+\.trycloudflare\.com).*/\1/p' "$XL_STATE/logs/argo-$id.log" 2>/dev/null | tail -n 1)
        [[ -n $hostname ]] || { xl_note '临时隧道尚未获得域名，请启动服务后再查看。'; return 1; }
        printf '%s\n' "$hostname"
    fi
}
