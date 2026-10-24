def tls:
  if .security=="reality" then
    {tls:true,"client-fingerprint":.client_fingerprint,
     "reality-opts":{"public-key":.public_key,"short-id":.short_id,"support-x25519mlkem768":true}}
  elif .security=="tls" then
    if .cert.status=="invalid" then error("证书无效："+.cert.reason) else
    {tls:true,"skip-cert-verify":.cert.skip_verify,"client-fingerprint":.client_fingerprint} +
    (if .cert.fingerprint!="" then {fingerprint:.cert.fingerprint} else {} end) +
    (if (.alpn|length)>0 then {alpn:.alpn} else {} end) end
  else {} end;
def xhttp:
  .xhttp as $x |
  if ($x.extra // {}|keys - ["noGRPCHeader","xPaddingBytes","scMaxEachPostBytes","scMinPostsIntervalMs"]|length)>0
     or ($x|keys - ["path","host","mode","extra","headers","noGRPCHeader","xPaddingBytes","scMaxEachPostBytes","scMinPostsIntervalMs"]|length)>0 then error("此 XHTTP 扩展无法无损转换为 Mihomo，使用 Xray JSON") else
  {path:($x.path // "/"),host:($x.host // ""),mode:($x.mode // "auto")} +
  (if $x.headers!=null then {headers:$x.headers} else {} end) +
  (if $x.noGRPCHeader!=null then {"no-grpc-header":$x.noGRPCHeader} else {} end) +
  (if $x.xPaddingBytes!=null then {"x-padding-bytes":$x.xPaddingBytes} else {} end) +
  (if $x.extra.noGRPCHeader!=null then {"no-grpc-header":$x.extra.noGRPCHeader} else {} end) +
  (if $x.extra.xPaddingBytes!=null then {"x-padding-bytes":$x.extra.xPaddingBytes} else {} end) +
  (if $x.extra.scMaxEachPostBytes!=null then {"sc-max-each-post-bytes":$x.extra.scMaxEachPostBytes} else {} end) +
  (if $x.extra.scMinPostsIntervalMs!=null then {"sc-min-posts-interval-ms":$x.extra.scMinPostsIntervalMs} else {} end) end;
. as $n |
if .protocol!="hysteria" and ((.finalmask.tcp // [])|length)>0 then error("Mihomo 无法表达该 TCP finalmask，使用 Xray JSON") else . end |
if any(.finalmask.udp[]?;.type!="salamander" and .type!="udphop") then error("Mihomo 无法表达该 UDP finalmask，使用 Xray JSON") else . end |
if .grpc.multiMode==true then error("Mihomo 无法表达 gRPC multiMode，使用 Xray JSON") else . end |
{name:.name,server:.server,port:.port} +
if .protocol=="vless" or .protocol=="trojan" then
  if .protocol=="trojan" and .transport=="xhttp" then error("Mihomo 仅支持 VLESS-XHTTP；Trojan-XHTTP 使用 Xray JSON") else
  (if .protocol=="vless" then {type:"vless",uuid:.uuid,udp:true} + (if .flow!="" then {flow:.flow} else {} end)
   else {type:"trojan",password:.password,udp:true} end) + tls +
  (if .sni!="" then (if .protocol=="vless" then {servername:.sni} else {sni:.sni} end) else {} end) +
  (if .transport=="ws" then {network:"ws","ws-opts":{path:(.ws.path // "/"),headers:(.ws.headers // {})}}
   elif .transport=="grpc" then {network:"grpc","grpc-opts":{"grpc-service-name":(.grpc.serviceName // "")}}
   elif .transport=="xhttp" then {network:"xhttp","xhttp-opts":xhttp}
   elif .transport=="tcp" then {network:"tcp"}
   else error("Mihomo 无法表达该传输："+.transport) end) end
elif .protocol=="hysteria" then
  if .cert.status=="invalid" then error("证书无效："+.cert.reason) else
  {type:"hysteria2",password:.password,sni:.sni,"skip-cert-verify":.cert.skip_verify,fingerprint:.cert.fingerprint} +
  (if (.public_ports|length)>1 then {ports:(.public_ports|map(tostring)|join(","))} else {} end) +
  (if .obfs_password!="" then {obfs:"salamander","obfs-password":.obfs_password} else {} end) +
  (if .up>0 then {up:.up} else {} end) + (if .down>0 then {down:.down} else {} end) end
elif .protocol=="shadowsocks" then {type:"ss",cipher:.cipher,password:.password,udp:true}
elif .protocol=="socks" then {type:"socks5",username:.username,password:.password,udp:.udp}
else error("Mihomo 不支持该协议："+.protocol) end
