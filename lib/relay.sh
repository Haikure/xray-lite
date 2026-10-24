#!/usr/bin/env bash
xl_token_pass() {
    local path=$1
    [[ -f $path && -s $path ]] || xl_die '请提供非空的口令文件。'
    [[ $(stat -c %a "$path") == 600 || $(stat -c %a "$path") == 400 ]] || xl_die '口令文件权限应为 600 或 400。'
}
xl_token_export() (
    local id=$1 passfile=$2 model outbound dir key mac
    xl_token_pass "$passfile"; model=$(xl_snapshot "$id"); outbound=$(xl_client_outbound <<< "$model")
    dir=$(mktemp -d); trap 'rm -rf -- "$dir"' EXIT
    # Encrypt-then-MAC; independent PBKDF2 key and a unique MAC salt.
    openssl rand 8 > "$dir/salt"
    key=$(openssl enc -aes-256-cbc -P -pbkdf2 -iter 200000 -md sha256 -S "$(od -An -tx1 "$dir/salt"|tr -d ' \n')" -pass "file:$passfile" | awk -F= '/^key=/ {print $2}')
    jq -n --arg name "$(jq -r .name <<< "$model")" --argjson outbound "$outbound" '{schema:1,name:$name,outbound:$outbound}' > "$dir/plain"
    openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 -salt -pass "file:$passfile" -in "$dir/plain" -out "$dir/cipher"
    cat "$dir/salt" "$dir/cipher" > "$dir/payload"
    openssl dgst -sha256 -mac HMAC -macopt "hexkey:$key" -binary "$dir/payload" > "$dir/mac"
    printf 'xl1.'; cat "$dir/payload" "$dir/mac" | openssl base64 -A; printf '\n'
)
xl_token_decode() (
    local file=$1 passfile=$2 output=$3 dir length key
    xl_token_pass "$passfile"
    [[ $(wc -c < "$file") -le 1048576 ]] || xl_die 'Token 超过大小限制。'
    [[ $(head -c 4 "$file") == xl1. ]] || xl_die '项目 Token 必须以 xl1. 开头。'
    dir=$(mktemp -d); trap 'rm -rf -- "$dir"' EXIT
    tail -c +5 "$file" | tr -d '\r\n' | openssl base64 -d -A > "$dir/all"
    length=$(wc -c < "$dir/all"); (( length >= 72 )) || xl_die 'Token 被截断。'
    head -c "$((length-32))" "$dir/all" > "$dir/payload"; tail -c 32 "$dir/all" > "$dir/mac"
    key=$(openssl enc -aes-256-cbc -P -pbkdf2 -iter 200000 -md sha256 -S "$(head -c 8 "$dir/payload"|od -An -tx1|tr -d ' \n')" -pass "file:$passfile" | awk -F= '/^key=/ {print $2}')
    openssl dgst -sha256 -mac HMAC -macopt "hexkey:$key" -binary "$dir/payload" > "$dir/expected"
    cmp -s "$dir/mac" "$dir/expected" || xl_die 'Token 认证失败，口令错误或内容被修改。'
    tail -c +9 "$dir/payload" > "$dir/cipher"
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 -pass "file:$passfile" -in "$dir/cipher" -out "$dir/plain"
    jq -e '.schema==1 and (.outbound|type)=="object"' "$dir/plain" >/dev/null || xl_die 'Token 结构无效。'
    jq '.outbound' "$dir/plain" > "$output"
)
xl_relay_import_edit() {
    local id=$1 file=$2 gen=$3
    [[ $id =~ ^[a-zA-Z0-9_-]+$ ]] || xl_die '出口 ID 无效。'
    xl_validate_json "$file"
    jq -e '.protocol=="vless" or .protocol=="trojan" or .protocol=="hysteria" or .protocol=="shadowsocks" or .protocol=="socks" or .protocol=="freedom" or .protocol=="blackhole"' "$file" >/dev/null || xl_die '出口协议不在纯 Xray 支持范围。'
    xl_jq "$gen/config.json" --arg tag "xlo-$id" --slurpfile o "$file" '.outbounds|=map(select(.tag!=$tag)) | .outbounds += [($o[0]|.tag=$tag)]'
}
xl_relay_token_edit() {
    local id=$1 file=$2 pass=$3 gen=$4
    xl_token_decode "$file" "$pass" "$gen/token.tmp"
    xl_relay_import_edit "$id" "$gen/token.tmp" "$gen"
    rm -f "$gen/token.tmp"
}
xl_relay_link_edit() {
    local id=$1 file=$2 gen=$3
    [[ $(wc -c < "$file") -lt 65536 ]] || xl_die '分享链接过长。'
    jq -Rn -f "$XL_APP/lib/import.jq" < "$file" > "$gen/import.tmp"
    xl_relay_import_edit "$id" "$gen/import.tmp" "$gen"
    rm -f "$gen/import.tmp"
}
xl_route_edit() {
    local inbound=$1 outbound=$2 gen=$3
    xl_node_exists "$gen" "$inbound"
    [[ $outbound == direct || $outbound == block ]] || outbound="xlo-$outbound"
    jq -e --arg tag "$outbound" '.outbounds[]|select(.tag==$tag)' "$gen/config.json" >/dev/null || xl_die '出口不存在。'
    xl_jq "$gen/config.json" --arg i "xl-$inbound" --arg o "$outbound" '.routing.rules|=map(select((.inboundTag // []|index($i))==null)) | .routing.rules=[{type:"field",inboundTag:[$i],outboundTag:$o}]+.routing.rules'
}
xl_relay_delete_edit() {
    local id=$1 gen=$2
    jq -e --arg tag "xlo-$id" 'any(.routing.rules[];.outboundTag==$tag)' "$gen/config.json" >/dev/null && xl_die '出口仍有路由引用，请先将入口切回 direct。'
    xl_jq "$gen/config.json" --arg tag "xlo-$id" '.outbounds|=map(select(.tag!=$tag))'
}
