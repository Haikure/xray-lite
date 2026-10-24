#!/usr/bin/env bash
xl_snapshot() {
    local id=$1 gen=${2:-$XL_GEN} model public argo cert='{"status":"none","skip_verify":false,"fingerprint":"","pin_base64":""}'
    xl_node_exists "$gen" "$id"
    model=$(jq -c -L "$XL_APP/lib" --slurpfile m "$gen/meta.json" --arg id "$id" 'include "model"; snapshot($m[0];$id)' "$gen/config.json")
    public=''
    if [[ $(jq -r .security <<< "$model") == reality ]]; then public=$(xl_reality_public "$(jq -r .private_key <<< "$model")"); [[ -n $public ]] || xl_die 'Reality 私钥无效。'; fi
    if [[ $(jq -r .security <<< "$model") == tls ]]; then cert=$(xl_cert_inspect "$(jq -r .certificate <<< "$model")" "$(jq -r .sni <<< "$model")"); fi
    model=$(jq -c --argjson cert "$cert" --arg public "$public" '
      def mbps: if type=="number" then ./125000 elif .==null or .=="" then 0 else ascii_downcase|capture("^(?<n>[0-9.]+) *(?<u>[kmgt]?)(?:b(?:it)?ps|b)$") | (.n|tonumber) * (if .u=="g" then 1000 elif .u=="k" then 0.001 elif .u=="t" then 1000000 else 1 end) end;
      .cert=$cert | .public_key=$public |
      .obfs_password=([.finalmask.udp[]?|select(.type=="salamander")|.settings.password][0] // "") |
      .up=(.finalmask.quicParams.brutalUp|mbps) |
      .down=(.finalmask.quicParams.brutalDown|mbps) |
      del(.private_key,.key_file,.inbound.streamSettings.realitySettings.privateKey)' <<< "$model")
    argo=$(xl_argo_endpoint "$id" "$gen") || return 1
    if [[ -n $argo ]]; then model=$(jq -c --arg host "$argo" '.origin_cert=.cert|.server=$host|.port=443|.public_ports=[443]|.sni=$host|.security="tls"|.alpn=["http/1.1"]|.cert={status:"trusted",skip_verify:false,fingerprint:"",pin_base64:"",reason:"Argo 公网 TLS 由 Cloudflare 管理"}|.ws.headers.Host=$host|.stream.security="tls"|.stream.wsSettings.host=$host|.stream.wsSettings.headers.Host=$host|.stream.tlsSettings.alpn=["http/1.1"]' <<< "$model"); fi
    printf '%s\n' "$model"
}
xl_client_outbound() { jq -f "$XL_APP/lib/client.jq"; }
xl_client_config_model() {
    local outbound; outbound=$(xl_client_outbound)
    jq -n --argjson o "$outbound" '{log:{loglevel:"warning"},inbounds:[{listen:"127.0.0.1",port:10808,protocol:"socks",settings:{udp:true}}],outbounds:[$o]}'
}
xl_client_json() { xl_snapshot "$1" | xl_client_config_model; }
xl_mihomo_object() { jq -e -f "$XL_APP/lib/mihomo.jq"; }
xl_yaml_node() {
    # YAML accepts JSON values; a JSON flow mapping is a valid YAML list item.
    local object
    object=$(xl_mihomo_object) || return 1
    printf -- '- %s\n' "$(jq -c . <<< "$object")"
}
xl_share_model() {
    local model=$1 proto name endpoint password uuid security transport query='' value key
    proto=$(jq -r .protocol <<< "$model"); name=$(xl_uri "$(jq -r .name <<< "$model")")
    endpoint=$(xl_hostport "$(jq -r .server <<< "$model")" "$(jq -r .port <<< "$model")")
    password=$(xl_uri "$(jq -r .password <<< "$model")"); uuid=$(jq -r .uuid <<< "$model")
    security=$(jq -r .security <<< "$model"); transport=$(jq -r .transport <<< "$model")
    case $proto in
        vless|trojan)
            query="security=$security&type=$transport"
            for key in sni flow; do value=$(jq -r --arg k "$key" '.[$k]' <<< "$model"); [[ -z $value ]] || query+="&$key=$(xl_uri "$value")"; done
            if [[ $(jq '.alpn|length' <<< "$model") -gt 0 ]]; then query+="&alpn=$(xl_uri "$(jq -r '.alpn|join(",")' <<< "$model")")"; fi
            if [[ $security == reality ]]; then query+="&pbk=$(xl_uri "$(jq -r .public_key <<< "$model")")&sid=$(jq -r .short_id <<< "$model")&fp=chrome"; fi
            if [[ $security == tls ]]; then
                [[ $(jq -r .cert.status <<< "$model") != invalid ]] || { xl_note "证书无效：$(jq -r .cert.reason <<< "$model")"; return 1; }
                [[ $(jq -r .cert.skip_verify <<< "$model") != true ]] || query+='&allowInsecure=1'
                query+="&fp=chrome"
                [[ -z $(jq -r .cert.fingerprint <<< "$model") ]] || query+="&pinSHA256=$(jq -r .cert.fingerprint <<< "$model")"
            fi
            case $transport in ws) query+="&path=$(xl_uri "$(jq -r '.ws.path // "/"' <<< "$model")")&host=$(xl_uri "$(jq -r '.ws.headers.Host // ""' <<< "$model")")";;
                grpc) query+="&serviceName=$(xl_uri "$(jq -r '.grpc.serviceName // ""' <<< "$model")")";;
                xhttp) query+="&path=$(xl_uri "$(jq -r '.xhttp.path // "/"' <<< "$model")")&host=$(xl_uri "$(jq -r '.xhttp.host // ""' <<< "$model")")&mode=$(jq -r '.xhttp.mode // "auto"' <<< "$model")"; if jq -e '.xhttp.extra!=null' <<< "$model" >/dev/null; then query+="&extra=$(xl_uri "$(jq -c .xhttp.extra <<< "$model")")"; fi;; esac
            [[ $proto == trojan ]] || password=$uuid
            printf '%s://%s@%s?%s#%s\n' "$proto" "$password" "$endpoint" "$query" "$name"
            ;;
        hysteria)
            [[ $(jq -r .cert.status <<< "$model") != invalid ]] || { xl_note "证书无效：$(jq -r .cert.reason <<< "$model")"; return 1; }
            query="sni=$(xl_uri "$(jq -r .sni <<< "$model")")&pinSHA256=$(jq -r .cert.fingerprint <<< "$model")"
            [[ $(jq -r .cert.skip_verify <<< "$model") != true ]] || query+='&insecure=1'
            if [[ $(jq -r .obfs_password <<< "$model") != '' ]]; then query+="&obfs=salamander&obfs-password=$(xl_uri "$(jq -r .obfs_password <<< "$model")")"; fi
            if [[ $(jq '.public_ports|length' <<< "$model") -gt 1 ]]; then query+="&mport=$(xl_uri "$(jq -r '.public_ports|map(tostring)|join(",")' <<< "$model")")"; fi
            printf 'hysteria2://%s@%s/?%s#%s\n' "$password" "$endpoint" "$query" "$name"
            ;;
        shadowsocks)
            value=$(jq -rj '.cipher+":"+.password' <<< "$model" | openssl base64 -A | tr '/+' '_-' | tr -d '=')
            printf 'ss://%s@%s#%s\n' "$value" "$endpoint" "$name";;
        socks) printf 'socks5://%s:%s@%s#%s\n' "$(xl_uri "$(jq -r .username <<< "$model")")" "$password" "$endpoint" "$name";;
        *) xl_note '该协议无分享链接。'; return 1;;
    esac
}
xl_node_show() {
    local id=$1 model; model=$(xl_snapshot "$id")
    jq 'del(.stream,.inbound)' <<< "$model"
    printf '运行状态：%s\n\n分享链接：\n' "$(xl_runtime_state "$XL_GEN")"
    xl_share_model "$model" || true
    printf '\nClash / Mihomo 单节点 YAML：\n'
    if ! xl_yaml_node <<< "$model"; then printf '当前组合无法导出 YAML，请使用分享链接或 Xray JSON。\n'; fi
    printf '\nXray 客户端 JSON：xl export %s xray\n' "$id"
}
xl_export() {
    local id=$1 format=${2:-yaml} model
    if [[ $id == all ]]; then
        [[ $format == yaml ]] || xl_die '批量导出格式为 yaml。'
        local result='' item
        while IFS= read -r item; do
            model=$(xl_snapshot "$item")
            result+="$(xl_yaml_node <<< "$model")"$'\n' || xl_die "节点 $item 无法转换；未输出不完整结果。"
        done < <(jq -r '.nodes|keys[]' "$XL_GEN/meta.json")
        printf '%s' "$result"; return
    fi
    model=$(xl_snapshot "$id")
    case $format in yaml) xl_yaml_node <<< "$model";; link) xl_share_model "$model";; xray) xl_client_config_model <<< "$model";; json) jq 'del(.stream,.inbound)' <<< "$model";; *) xl_die '格式：yaml / link / xray / json';; esac
}
