#!/usr/bin/env bash
xl_cert_inspect() (
    # Always read the currently referenced file, including symlink targets.
    local cert=$1 sni=$2 dir fingerprint fingerprint64 status=invalid reason='' subject issuer not_before='' not_after=''
    dir=$(mktemp -d); trap 'rm -rf -- "$dir"' EXIT
    if [[ ! -r $cert ]]; then reason='证书文件缺失或不可读'
    elif ! openssl x509 -in "$cert" -out "$dir/leaf.pem" 2>"$dir/error"; then reason='证书文件损坏或非 PEM 证书'
    else
        fingerprint=$(openssl x509 -in "$dir/leaf.pem" -outform DER | openssl dgst -sha256 | awk '{print $NF}')
        fingerprint64=$(openssl x509 -in "$dir/leaf.pem" -outform DER | openssl dgst -sha256 -binary | openssl base64 -A)
        not_before=$(openssl x509 -in "$dir/leaf.pem" -noout -startdate); not_before=${not_before#notBefore=}
        not_after=$(openssl x509 -in "$dir/leaf.pem" -noout -enddate); not_after=${not_after#notAfter=}
        awk '/-----BEGIN CERTIFICATE-----/ {n++} n>=2 {print}' "$cert" > "$dir/chain.pem"
        local verify=(-purpose sslserver)
        [[ -s $dir/chain.pem ]] && verify+=(-untrusted "$dir/chain.pem")
        if [[ -z $sni ]]; then reason='配置缺少 SNI'
        else
            if [[ $sni == *:* || $sni =~ ^[0-9.]+$ ]]; then verify+=(-verify_ip "$sni"); else verify+=(-verify_hostname "$sni"); fi
            if openssl verify "${verify[@]}" "$dir/leaf.pem" > "$dir/error" 2>&1; then status=trusted
            else
                reason=$(cat "$dir/error")
                subject=$(openssl x509 -in "$dir/leaf.pem" -noout -subject -nameopt RFC2253); issuer=$(openssl x509 -in "$dir/leaf.pem" -noout -issuer -nameopt RFC2253)
                if [[ ${subject#subject=} == "${issuer#issuer=}" ]] && openssl verify -check_ss_sig -trusted "$dir/leaf.pem" "${verify[@]}" "$dir/leaf.pem" > "$dir/self-error" 2>&1; then
                    status=self_signed; reason='有效自签证书，使用证书固定'
                fi
            fi
        fi
    fi
    jq -n --arg status "$status" --arg reason "$reason" --arg fingerprint "${fingerprint:-}" --arg pin_base64 "${fingerprint64:-}" --arg path "$cert" --arg not_before "$not_before" --arg not_after "$not_after" \
        '{status:$status,reason:$reason,fingerprint:$fingerprint,pin_base64:$pin_base64,path:$path,not_before:$not_before,not_after:$not_after,skip_verify:($status=="self_signed")}'
)
xl_cert_key_check() {
    local cert=$1 key=$2 c k
    c=$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum) || return 1
    k=$(openssl pkey -in "$key" -passin pass: -pubout -outform DER | sha256sum) || return 1
    [[ $c == "$k" ]] || { xl_note '证书与私钥不匹配。'; return 1; }
}
xl_cert_generate() {
    local sni=$1 cert=$2 key=$3 san
    xl_address "$sni" || xl_die '无效的证书 SNI。'
    if [[ $sni == *:* || $sni =~ ^[0-9.]+$ ]]; then san="IP:$sni"; else san="DNS:$sni"; fi
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -sha256 -days 365 -nodes \
        -keyout "$key" -out "$cert" -subj /CN=xray-lite -addext "subjectAltName=$san" -addext 'extendedKeyUsage=serverAuth' -addext 'basicConstraints=critical,CA:FALSE' -addext 'keyUsage=critical,digitalSignature' >/dev/null 2>&1
    chmod 600 "$cert" "$key"
}
xl_validate_certificates() {
    local gen=$1 row cert key sni result
    while IFS= read -r row; do
        cert=$(jq -r '.cert' <<< "$row"); key=$(jq -r '.key' <<< "$row"); sni=$(jq -r '.sni' <<< "$row")
        [[ $cert == /* && $key == /* ]] || xl_die '服务端证书和私钥应使用绝对路径。'
        result=$(xl_cert_inspect "$cert" "$sni")
        [[ $(jq -r .status <<< "$result") != invalid ]] || xl_die "证书无效：$(jq -r .reason <<< "$result")"
        xl_cert_key_check "$cert" "$key" || xl_die '证书密钥检查失败。'
    done < <(jq -c '.inbounds[]|select(.streamSettings.security=="tls")|.streamSettings.tlsSettings as $t|$t.certificates[]|{cert:.certificateFile,key:.keyFile,sni:($t.serverName // "")}' "$gen/config.json")
}
xl_cert_replace_edit() {
    local id=$1 cert=$2 key=$3 gen=$4
    xl_node_exists "$gen" "$id"
    [[ $cert == /* && $key == /* ]] || xl_die '请使用绝对路径。'
    xl_jq "$gen/config.json" --arg id "xl-$id" --arg cert "$cert" --arg key "$key" \
        '(.inbounds[]|select(.tag==$id)|.streamSettings.tlsSettings.certificates)=[{certificateFile:$cert,keyFile:$key}]'
}
xl_reality_public() {
    # Derive with OpenSSL from PKCS#8. The private key never appears in argv.
    local private=$1
    { printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x6e\x04\x22\x04\x20';
      printf '%s' "$private" | tr '_-' '/+' | awk '{printf "%s=",$0}' | openssl base64 -d -A;
    } | openssl pkey -inform DER -pubout -outform DER 2>/dev/null | tail -c 32 | openssl base64 -A | tr '/+' '_-' | tr -d '='
}
