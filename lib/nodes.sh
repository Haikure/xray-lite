#!/usr/bin/env bash
xl_node_exists() { jq -e --arg id "xl-$2" '.inbounds[]|select(.tag==$id)' "$1/config.json" >/dev/null || xl_die "节点不存在：$2"; }
xl_node_build() {
    local spec=$1 gen=$2 id=${3:-$(xl_id)} protocol net sec uuid password private short sni cert='' key='' cipher
    protocol=$(jq -r '.protocol // "vless"' <<< "$spec")
    [[ $protocol != hysteria2 ]] || { spec=$(jq '.protocol="hysteria"' <<< "$spec"); protocol=hysteria; }
    net=$(jq -r --arg p "$protocol" '.transport // (if $p=="hysteria" then "hysteria" else "tcp" end)' <<< "$spec")
    sec=$(jq -r --arg p "$protocol" '.security // (if $p=="shadowsocks" or $p=="socks" then "none" elif $p=="trojan" or $p=="hysteria" then "tls" else "reality" end)' <<< "$spec")
    spec=$(jq --arg protocol "$protocol" --arg transport "$net" --arg security "$sec" '.protocol=$protocol|.transport=$transport|.security=$security' <<< "$spec")
    case "$protocol/$net/$sec" in
        vless/tcp/reality|vless/tcp/tls|vless/tcp/none|vless/ws/tls|vless/ws/none|vless/grpc/tls|vless/grpc/reality|vless/xhttp/tls|vless/xhttp/reality|trojan/tcp/tls|trojan/ws/tls|trojan/ws/none|trojan/grpc/tls|trojan/grpc/reality|trojan/xhttp/tls|trojan/xhttp/reality|hysteria/hysteria/tls|shadowsocks/tcp/none|socks/tcp/none) ;;
        *) xl_die "不支持的协议组合：$protocol/$net/$sec";;
    esac
    xl_port "$(jq -r '.port // ""' <<< "$spec")" || xl_die '需要有效的监听端口。'
    sni=$(jq -r '.sni // .public_address // "www.microsoft.com"' <<< "$spec")
    sni=${sni#[}; sni=${sni%]}
    xl_address "$sni" || xl_die 'SNI 格式无效。'
    uuid=$(jq -r '.uuid // ""' <<< "$spec"); [[ -n $uuid ]] || uuid=$("$gen/core" uuid)
    password=$(jq -r '.password // ""' <<< "$spec")
    cipher=$(jq -r '.cipher // "2022-blake3-aes-128-gcm"' <<< "$spec")
    if [[ $protocol == shadowsocks ]]; then
        case $cipher in aes-128-gcm|aes-256-gcm|chacha20-ietf-poly1305|xchacha20-ietf-poly1305|2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) ;; *) xl_die '不支持的 Shadowsocks 算法。';; esac
        if [[ -z $password ]]; then case $cipher in 2022-blake3-aes-128-gcm) password=$(openssl rand -base64 16);; 2022-*) password=$(openssl rand -base64 32);; *) password=$(openssl rand -hex 16);; esac; fi
    else [[ -n $password ]] || password=$(openssl rand -hex 16); fi
    private=$(jq -r '.private_key // ""' <<< "$spec"); short=$(openssl rand -hex 8)
    [[ $sec != reality || -n $private ]] || private=$("$gen/core" x25519 | awk '/^PrivateKey:/ {print $2}')
    if [[ $sec == tls ]]; then
        cert=$(jq -r '.certificate // ""' <<< "$spec"); key=$(jq -r '.key_file // ""' <<< "$spec")
        if [[ -z $cert && -z $key ]]; then mkdir -p "$gen/certs"; cert="$gen/certs/$id.pem"; key="$gen/certs/$id.key"; xl_cert_generate "$sni" "$cert" "$key"; fi
        [[ -n $cert && -n $key ]] || xl_die '证书和私钥必须同时提供。'
    fi
    jq -n --argjson spec "$spec" --arg id "$id" --arg uuid "$uuid" --arg password "$password" --arg private "$private" --arg short "$short" --arg sni "$sni" --arg cert "$cert" --arg key "$key" -f "$XL_APP/lib/create.jq" > "$gen/node.tmp"
    if [[ $protocol == hysteria ]]; then xl_hy_options "$spec" "$gen/node.tmp"; fi
    xl_jq "$gen/config.json" --slurpfile node "$gen/node.tmp" '.inbounds += $node'
    xl_jq "$gen/meta.json" --arg id "$id" --argjson o "$spec" '.nodes[$id]={name:($o.name // $id)} + ($o|{public_address,public_port}|with_entries(select(.value!=null))) | if .nodes[$id].public_port then .nodes[$id].public_port|=tonumber else . end'
    rm -f "$gen/node.tmp"
    xl_note "节点 ID：$id"
}
xl_node_add_edit() { local spec=$1 gen=$2; xl_node_build "$spec" "$gen"; }
xl_batch_edit() {
    local file=$1 gen=$2 item
    jq -e 'type=="array" and length>0 and length<=128 and all(.[];type=="object")' "$file" >/dev/null || xl_die '批量文件应为 1..128 个节点对象的数组。'
    while IFS= read -r item; do xl_node_build "$item" "$gen"; done < <(jq -c '.[]' "$file")
}
xl_node_delete_edit() {
    local id=$1 gen=$2
    xl_node_exists "$gen" "$id"
    jq -e --arg id "$id" '.argo[$id]!=null' "$gen/meta.json" >/dev/null && xl_die '请先删除该节点的 Argo 隧道。'
    xl_jq "$gen/config.json" --arg tag "xl-$id" '.inbounds|=map(select(.tag!=$tag)) | .routing.rules|=map(select((.inboundTag // []|index($tag))==null))'
    xl_jq "$gen/meta.json" --arg id "$id" 'del(.nodes[$id])'
}
xl_node_update_edit() {
    # Change only requested fields in the live inbound; retain manual fields.
    local id=$1 patch=$2 gen=$3
    xl_node_exists "$gen" "$id"
    jq -e 'keys - ["name","public_address","public_port","port","listen","uuid","password","username","flow","sni","path","host","service_name","short_id","private_key","target","certificate","key_file","cipher","udp","up","down","obfs_password","hop_ports"] | length==0' <<< "$patch" >/dev/null || xl_die '未知修改字段；结构修改请使用 xl config apply。'
    xl_jq "$gen/config.json" --arg tag "xl-$id" --argjson p "$patch" '
      (.inbounds[]|select(.tag==$tag)) |= (
        if $p.port then .port=($p.port|tonumber) else . end |
        if $p.listen then .listen=$p.listen else . end |
        (if .settings.clients!=null then "clients" else "users" end) as $u |
        (if .streamSettings.xhttpSettings!=null then "xhttpSettings" elif .streamSettings.splithttpSettings!=null then "splithttpSettings" else "xhttpSettings" end) as $xkey |
        if $p.uuid then .settings[$u][0].id=$p.uuid else . end |
        if $p.flow!=null then .settings[$u][0].flow=$p.flow else . end |
        if $p.password then
          if .protocol=="shadowsocks" then .settings.password=$p.password
          elif .protocol=="socks" then .settings.accounts[0].pass=$p.password
          elif .protocol=="hysteria" then .settings[$u][0].auth=$p.password
          else .settings[$u][0].password=$p.password end else . end |
        if $p.username then .settings.accounts[0].user=$p.username else . end |
        if $p.cipher then .settings.method=$p.cipher else . end |
        if $p.udp!=null then .settings.udp=($p.udp==true or $p.udp=="true") else . end |
        if $p.sni then if .streamSettings.security=="reality" then .streamSettings.realitySettings.serverNames[0]=$p.sni else .streamSettings.tlsSettings.serverName=$p.sni end else . end |
        if $p.path then if ((.streamSettings.method // .streamSettings.network) as $net | ["ws","websocket"]|index($net)!=null) then .streamSettings.wsSettings.path=$p.path else .streamSettings[$xkey].path=$p.path end else . end |
        if $p.host then if ((.streamSettings.method // .streamSettings.network) as $net | ["ws","websocket"]|index($net)!=null) then .streamSettings.wsSettings.host=$p.host else .streamSettings[$xkey].host=$p.host end else . end |
        if $p.service_name then .streamSettings.grpcSettings.serviceName=$p.service_name else . end |
        if $p.short_id!=null then .streamSettings.realitySettings.shortIds[0]=$p.short_id else . end |
        if $p.private_key then .streamSettings.realitySettings.privateKey=$p.private_key else . end |
        if $p.target then .streamSettings.realitySettings.target=$p.target else . end |
        if $p.certificate then .streamSettings.tlsSettings.certificates[0].certificateFile=$p.certificate else . end |
        if $p.key_file then .streamSettings.tlsSettings.certificates[0].keyFile=$p.key_file else . end )'
    xl_jq "$gen/meta.json" --arg id "$id" --argjson p "$patch" '.nodes[$id] += ($p|with_entries(select(.key=="name" or .key=="public_address" or .key=="public_port"))) | if .nodes[$id].public_port then .nodes[$id].public_port|=tonumber else . end'
    if jq -e 'has("up") or has("down") or has("obfs_password") or has("hop_ports")' <<< "$patch" >/dev/null; then
        jq --arg tag "xl-$id" '.inbounds[]|select(.tag==$tag)' "$gen/config.json" > "$gen/node.tmp"
        xl_hy_options "$patch" "$gen/node.tmp"
        xl_jq "$gen/config.json" --arg tag "xl-$id" --slurpfile node "$gen/node.tmp" '(.inbounds[]|select(.tag==$tag))=$node[0]'
        rm -f "$gen/node.tmp"
    fi
}
xl_node_list() {
    jq -r --slurpfile m "$XL_GEN/meta.json" '.inbounds[]|select(.tag|startswith("xl-"))|(.tag|ltrimstr("xl-")) as $id|[$id,($m[0].nodes[$id].name // $id),.protocol,(.port|tostring)]|@tsv' "$XL_GEN/config.json"
}
xl_nat_edit() {
    local file=$1 gen=$2
    jq -e 'type=="object" and (.enabled|type)=="boolean" and (.address|type)=="string" and (.mappings|type)=="array" and all(.mappings[];(.protocol=="tcp" or .protocol=="udp") and (.local|type)=="number" and (.public|type)=="number" and .local>=1 and .local<=65535 and .public>=1 and .public<=65535 and .local==(.local|floor) and .public==(.public|floor)) and ([.mappings[]|[.protocol,.local]]|length==(unique|length)) and ([.mappings[]|[.protocol,.public]]|length==(unique|length))' "$file" >/dev/null || xl_die 'NAT 声明无效或存在重复映射。'
    xl_jq "$gen/meta.json" --slurpfile nat "$file" '.nat=$nat[0]'
}
xl_validate_endpoints() {
    local gen=$1 bindings row port proto hex old public='[]' snapshot
    bindings=$(jq -c -L "$XL_APP/lib" --slurpfile m "$gen/meta.json" 'include "model"; [.inbounds[] | . as $i | (.port|ports)[] as $p | ($i|wire)[] as $w | {port:$p,wire:$w}]+[$m[0].forwards[]|select(.engine=="nftables")|.port as $p|(.protocol|split(","))[]|{port:$p,wire:.}]' "$gen/config.json")
    jq -e 'all(.[];.port>=1 and .port<=65535 and .port==(.port|floor)) and (length==(unique|length))' <<< "$bindings" >/dev/null || xl_die '监听端口重复或无效。'
    local id
    while IFS= read -r id; do
        jq -e -L "$XL_APP/lib" --slurpfile m "$gen/meta.json" --arg id "$id" 'include "model"; snapshot($m[0];$id)|.server|length>0' "$gen/config.json" >/dev/null || xl_die "节点 $id 缺少公网地址或映射。"
        snapshot=$(jq -c -L "$XL_APP/lib" --slurpfile m "$gen/meta.json" --arg id "$id" 'include "model"; snapshot($m[0];$id)' "$gen/config.json")
        public=$(jq -cn --argjson old "$public" --argjson s "$snapshot" '$old + [$s.public_ports[] as $p | ($s.inbound|if .protocol=="hysteria" then ["udp"] elif .protocol=="shadowsocks" or (.protocol=="socks" and .settings.udp) then ["tcp","udp"] else ["tcp"] end)[] | {server:$s.server,port:$p,wire:.}]')
    done < <(jq -r '.nodes|keys[]' "$gen/meta.json")
    jq -e 'all(.[];.port>=1 and .port<=65535 and .port==(.port|floor)) and (length==(unique|length))' <<< "$public" >/dev/null || xl_die '公网端口无效或节点公网端点重复。'
    jq -e '.nodes|all(.[]; ((.public_address // "")|test("^[^ /@#?\t\r\n]*$")))' "$gen/meta.json" >/dev/null || xl_die '公网地址格式无效。'
    old=$(xl_current)
    while IFS= read -r row; do
        port=$(jq -r .port <<< "$row"); proto=$(jq -r .wire <<< "$row")
        if xl_service_alive && jq -e -L "$XL_APP/lib" --argjson p "$port" --arg w "$proto" 'include "model"; any(.inbounds[];((.port|ports|index($p))!=null) and ((wire|index($w))!=null))' "$old/config.json" >/dev/null; then continue; fi
        printf -v hex '%04X' "$port"
        if awk -v p="$hex" -v proto="$proto" 'FNR>1 {split($2,a,":"); if(a[2]==p && (proto=="udp" || $4=="0A")) found=1} END {exit !found}' "/proc/net/$proto" "/proc/net/${proto}6" 2>/dev/null; then xl_die "$proto 端口 $port 已被占用。"; fi
    done < <(jq -c '.[]' <<< "$bindings")
}
xl_config_edit() { local file=$1 gen=$2; xl_validate_json "$file"; cp "$file" "$gen/config.json"; }
xl_dns_edit() { local file=$1 gen=$2; xl_validate_json "$file"; xl_jq "$gen/config.json" --slurpfile dns "$file" '.dns=$dns[0]'; }
