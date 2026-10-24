# Parse third-party URIs without eval or external interpreters.
def urldecode:
  explode as $a |
  reduce range(0;length) as $i ({out:[],skip:0};
    if .skip>0 then .skip-=1 elif $a[$i]==37 then
      ([$a[$i+1],$a[$i+2]]|implode|ascii_downcase|explode|map(if .>=48 and .<=57 then .-48 elif .>=97 and .<=102 then .-87 else error("百分号编码无效") end)) as $hex |
      .out += [($hex[0]*16+$hex[1])]|.skip=2
    else .out+=[$a[$i]] end) | .out|implode;
input | capture("^(?<scheme>[a-zA-Z0-9]+)://(?<body>[^#]*)(?:#(?<name>.*))?$") as $url |
($url.body|split("?")) as $parts |
($parts[1] // "" | split("&") | map(select(length>0)|split("=")|{key:.[0],value:(.[1:]|join("=")|urldecode)}) | from_entries) as $q |
($parts[0]|rtrimstr("/")|capture("^(?<auth>.*)@(?<host>\\[[^]]+\\]|[^:]+):(?<port>[0-9]+)$")) as $a |
($a.host|ltrimstr("[")|rtrimstr("]")) as $server |
($a.port|tonumber) as $port |
($q.type // "tcp") as $net |
($q.security // (if $url.scheme=="trojan" or $url.scheme=="hysteria2" or $url.scheme=="hy2" then "tls" else "none" end)) as $sec |
{protocol:(if $url.scheme=="ss" then "shadowsocks" elif $url.scheme=="socks5" then "socks" elif $url.scheme=="hy2" or $url.scheme=="hysteria2" then "hysteria" else $url.scheme end),
 settings:(if $url.scheme=="vless" then {vnext:[{address:$server,port:$port,users:[{id:($a.auth|urldecode),encryption:"none",flow:($q.flow // "")}]}]}
 elif $url.scheme=="trojan" then {servers:[{address:$server,port:$port,password:($a.auth|urldecode)}]}
 elif $url.scheme=="hysteria2" or $url.scheme=="hy2" then {version:2,address:$server,port:$port}
 elif $url.scheme=="ss" then ($a.auth|gsub("-";"+")|gsub("_";"/")|@base64d|capture("^(?<method>[^:]+):(?<password>.*)$")) as $ss | {servers:[{address:$server,port:$port,method:$ss.method,password:$ss.password}]}
 elif $url.scheme=="socks5" then ($a.auth|split(":")) as $user | {servers:[{address:$server,port:$port,users:[{user:($user[0]|urldecode),pass:($user[1:]|join(":")|urldecode)}]}]}
 else error("不支持的分享协议："+$url.scheme) end),
 streamSettings:{network:$net,security:$sec}} |
 if $sec=="reality" then .streamSettings.realitySettings={serverName:($q.sni // $server),fingerprint:($q.fp // "chrome"),publicKey:$q.pbk,shortId:($q.sid // "")}
 elif $sec=="tls" then
   if ($q.insecure=="1" or $q.allowInsecure=="1") and ($q.pinSHA256 // "")=="" then error("当前官方 Xray 要求自签证书提供 pinSHA256") else . end |
   .streamSettings.tlsSettings={serverName:($q.sni // $server)} |
   if $q.alpn then .streamSettings.tlsSettings.alpn=($q.alpn|split(",")) else . end |
   if $q.pinSHA256 then .streamSettings.tlsSettings.pinnedPeerCertSha256=$q.pinSHA256 else . end
 else . end |
 if $net=="ws" then .streamSettings.wsSettings={path:($q.path // "/"),host:($q.host // $server)}
 elif $net=="grpc" then .streamSettings.grpcSettings={serviceName:($q.serviceName // "")}
 elif $net=="xhttp" then .streamSettings.xhttpSettings={path:($q.path // "/"),host:($q.host // $server),mode:($q.mode // "auto")} |
   if $q.extra then .streamSettings.xhttpSettings.extra=($q.extra|fromjson) else . end
 else . end |
 if .protocol=="hysteria" then .streamSettings.network="hysteria" | .streamSettings.hysteriaSettings={version:2,auth:($a.auth|urldecode)} |
   if $q.obfs=="salamander" then .streamSettings.finalmask.udp=[{type:"salamander",settings:{password:$q["obfs-password"]}}] else . end |
   if $q.mport then .streamSettings.finalmask.udp=((.streamSettings.finalmask.udp // [])+[{type:"udphop",settings:{mode:"intervalRemote",interval:30,remotePorts:$q.mport}}]) else . end
 else . end
