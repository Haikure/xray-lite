#!/usr/bin/env bash
xl_hy_options() {
    local spec=$1 file=$2
    if jq -e 'has("hop_ports")' <<< "$spec" >/dev/null; then
        local ports; ports=$(jq -r .hop_ports <<< "$spec")
        [[ $ports =~ ^[0-9,-]+$ ]] || xl_die '跳跃端口应为端口、逗号或范围。'
        xl_jq "$file" --arg ports "$ports" '.port=$ports'
    fi
    xl_jq "$file" --argjson o "$spec" '
      if $o.up!=null then .streamSettings.finalmask.quicParams.brutalUp=(($o.up|tonumber|tostring)+" mbps") else . end |
      if $o.down!=null then .streamSettings.finalmask.quicParams.brutalDown=(($o.down|tonumber|tostring)+" mbps") else . end |
      if $o.up!=null or $o.down!=null then .streamSettings.finalmask.quicParams.congestion="brutal" else . end |
      if $o.obfs_password!=null then .streamSettings.finalmask.udp=((.streamSettings.finalmask.udp // []|map(select(.type!="salamander"))) +
        (if $o.obfs_password=="" then [] else [{type:"salamander",settings:{password:$o.obfs_password}}] end)) else . end'
}
xl_forward_put_edit() {
    local id=$1 spec=$2 gen=$3 engine protocol listen port target target_port
    engine=$(jq -r '.engine // "xray"' <<< "$spec"); protocol=$(jq -r '.protocol // "tcp"' <<< "$spec")
    listen=$(jq -r '.listen // "0.0.0.0"' <<< "$spec"); port=$(jq -r .port <<< "$spec")
    target=$(jq -r .target <<< "$spec"); target_port=$(jq -r .target_port <<< "$spec")
    [[ $id =~ ^[a-zA-Z0-9_-]+$ ]] || xl_die '规则 ID 只能包含字母数字、横线和下划线。'
    [[ $engine == xray || $engine == nftables ]] || xl_die '转发引擎为 xray 或 nftables。'
    [[ $protocol == tcp || $protocol == udp || $protocol == tcp,udp ]] || xl_die '转发协议为 tcp / udp / tcp,udp。'
    xl_port "$port" && xl_port "$target_port" && xl_address "$target" || xl_die '目标地址或端口无效。'
    if [[ $engine == nftables ]]; then
        xl_need nft getent
        [[ $listen == 0.0.0.0 || $listen == :: ]] || xl_die 'nftables 引擎监听地址使用 0.0.0.0 或 ::。'
        if [[ $target != *:* && ! $target =~ ^[0-9.]+$ ]]; then
            local host=$target
            target=$(getent ahostsv4 "$host" | awk 'NR==1{print $1}') || true
            [[ -n $target ]] || target=$(getent ahostsv6 "$host" | awk 'NR==1{print $1}')
            [[ -n $target ]] || xl_die '无法解析目标域名。'
        fi
        [[ $target =~ ^[0-9a-fA-F:.]+$ ]] || xl_die 'nftables 目标地址格式无效。'
    fi
    xl_jq "$gen/config.json" --arg tag "xlf-$id" '.inbounds|=map(select(.tag!=$tag))'
    if [[ $engine == xray ]]; then
        xl_jq "$gen/config.json" --arg tag "xlf-$id" --arg listen "$listen" --argjson port "$port" --arg target "$target" --argjson target_port "$target_port" --arg protocol "$protocol" \
            '.inbounds += [{tag:$tag,listen:$listen,port:$port,protocol:"dokodemo-door",settings:{address:$target,port:$target_port,network:$protocol}}]'
    fi
    xl_jq "$gen/meta.json" --arg id "$id" --arg engine "$engine" --arg protocol "$protocol" --arg listen "$listen" --argjson port "$port" --arg target "$target" --argjson target_port "$target_port" \
        '.forwards[$id]={engine:$engine,protocol:$protocol,listen:$listen,port:$port,target:$target,target_port:$target_port}'
}
xl_forward_delete_edit() {
    local id=$1 gen=$2
    jq -e --arg id "$id" '.forwards[$id]!=null' "$gen/meta.json" >/dev/null || xl_die '转发规则不存在。'
    xl_jq "$gen/config.json" --arg tag "xlf-$id" '.inbounds|=map(select(.tag!=$tag))'
    xl_jq "$gen/meta.json" --arg id "$id" 'del(.forwards[$id])'
}
xl_forward_engine_edit() {
    local id=$1 engine=$2 gen=$3 spec
    spec=$(jq -ce --arg id "$id" '.forwards[$id] // error("规则不存在")' "$gen/meta.json")
    spec=$(jq --arg engine "$engine" '.engine=$engine' <<< "$spec")
    xl_forward_put_edit "$id" "$spec" "$gen"
}
xl_forward_nft_script() {
    local gen=$1 row protocol port target target_port family
    if nft list table inet xray_lite >/dev/null 2>&1; then printf 'delete table inet xray_lite\n'; fi
    printf 'table inet xray_lite {\n chain prerouting { type nat hook prerouting priority dstnat; policy accept;\n'
    while IFS= read -r row; do
        port=$(jq -r .port <<< "$row"); target=$(jq -r .target <<< "$row"); target_port=$(jq -r .target_port <<< "$row")
        family=ipv4; [[ $target != *:* ]] || family=ipv6
        local protocols; protocols=$(jq -r '.protocol|split(",")[]' <<< "$row")
        local nat_family=ip; [[ $family != ipv6 ]] || nat_family=ip6
        while IFS= read -r protocol; do printf ' fib daddr type local meta nfproto %s %s dport %s ct mark set 0x584c4954 dnat %s to %s\n' "$family" "$protocol" "$port" "$nat_family" "$(xl_hostport "$target" "$target_port")"; done <<< "$protocols"
    done < <(jq -c '.forwards[]|select(.engine=="nftables")' "$gen/meta.json")
    printf '}\n chain postrouting { type nat hook postrouting priority srcnat; policy accept; ct mark 0x584c4954 masquerade; }\n}\n'
}
xl_forward_validate() {
    local gen=$1
    if jq -e 'any(.forwards[];.engine=="nftables")' "$gen/meta.json" >/dev/null; then
        xl_need nft
        nft list tables >/dev/null 2>&1 || xl_die '缺少 NET_ADMIN；请使用 xray 转发引擎。'
        if jq -e 'any(.forwards[];.engine=="nftables" and (.target|contains(":")))' "$gen/meta.json" >/dev/null; then
            [[ $(cat /proc/sys/net/ipv6/conf/all/forwarding) == 1 ]] || xl_die 'nftables 需要宿主机开启 IPv6 转发。'
        fi
        if jq -e 'any(.forwards[];.engine=="nftables" and (.target|contains(":")|not))' "$gen/meta.json" >/dev/null; then
            [[ $(cat /proc/sys/net/ipv4/ip_forward) == 1 ]] || xl_die 'nftables 需要宿主机开启 IPv4 转发。'
        fi
        xl_forward_nft_script "$gen" > "$gen/nftables.conf"
        nft -c -f "$gen/nftables.conf" || xl_die 'nftables 规则检查失败。'
    fi
}
xl_forward_apply() {
    local gen=$1
    if jq -e 'any(.forwards[];.engine=="nftables")' "$gen/meta.json" >/dev/null; then
        xl_forward_nft_script "$gen" > "$gen/nftables.conf" || return 1
        nft -f "$gen/nftables.conf" || return 1
    elif command -v nft >/dev/null && nft list table inet xray_lite >/dev/null 2>&1; then nft delete table inet xray_lite; fi
}
