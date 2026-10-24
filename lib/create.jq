def truth: .==true or .=="true";
$spec as $o |
($o.protocol // "vless") as $protocol |
($o.transport // (if $protocol=="hysteria" then "hysteria" else "tcp" end)) as $net |
($o.security // (if $protocol=="shadowsocks" or $protocol=="socks" then "none" elif $protocol=="hysteria" or $protocol=="trojan" then "tls" else "reality" end)) as $sec |
{tag:("xl-"+$id),listen:($o.listen // "0.0.0.0"),port:($o.port|tonumber),protocol:$protocol,
 settings:(if $protocol=="vless" then {clients:[{id:$uuid,flow:($o.flow // (if $net=="tcp" and $sec!="none" then "xtls-rprx-vision" else "" end))}],decryption:($o.decryption // "none")}
   elif $protocol=="trojan" then {clients:[{password:$password}]}
   elif $protocol=="hysteria" then {version:2,clients:[{auth:$password}]}
   elif $protocol=="shadowsocks" then {method:($o.cipher // "2022-blake3-aes-128-gcm"),password:$password,network:"tcp,udp"}
   elif $protocol=="socks" then {auth:"password",accounts:[{user:($o.username // "xl"),pass:$password}],udp:(($o.udp // false)|truth),ip:($o.listen // "0.0.0.0")}
   else error("不支持的协议") end)} |
if $protocol=="shadowsocks" or $protocol=="socks" then . else
 .streamSettings={network:$net,security:$sec} |
 if $sec=="reality" then .streamSettings.realitySettings={show:false,target:($o.target // (($o.sni // "www.microsoft.com")+":443")),serverNames:[($o.sni // "www.microsoft.com")],privateKey:$private,shortIds:[($o.short_id // $short)]}
 elif $sec=="tls" then .streamSettings.tlsSettings={serverName:$sni,alpn:(if $net=="hysteria" then ["h3"] elif $net=="ws" then ["http/1.1"] else ["h2","http/1.1"] end),certificates:[{certificateFile:$cert,keyFile:$key}]}
 elif $sec!="none" then error("不支持的安全层") else . end |
 if $net=="ws" then .streamSettings.wsSettings={path:($o.path // "/xl"),host:($o.host // $sni)}
 elif $net=="grpc" then .streamSettings.grpcSettings={serviceName:($o.service_name // "xl")}
 elif $net=="xhttp" then .streamSettings.xhttpSettings={path:($o.path // "/xl"),host:($o.host // $sni),mode:($o.mode // "auto")}
 elif $net=="hysteria" then .streamSettings.hysteriaSettings={version:2}
 else . end
end
