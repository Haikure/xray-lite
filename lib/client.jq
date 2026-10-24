def stream:
  . as $n |
  .stream |
  del(.tlsSettings.certificates,.realitySettings.privateKey,.realitySettings.serverNames,.realitySettings.shortIds,.realitySettings.target,.realitySettings.dest,.realitySettings.xver,.sockopt.acceptProxyProtocol) |
  if $n.security=="reality" then .realitySettings={serverName:$n.sni,fingerprint:$n.client_fingerprint,publicKey:$n.public_key,shortId:$n.short_id,spiderX:"/"}
  elif $n.security=="tls" then
    if $n.cert.status=="invalid" then error("证书无效："+$n.cert.reason) else
    .tlsSettings.serverName=$n.sni | del(.tlsSettings.allowInsecure) |
    (if $n.cert.fingerprint!="" then .tlsSettings.pinnedPeerCertSha256=$n.cert.fingerprint else . end) end
  else . end;
. as $n |
{tag:("xl-out-"+.id),protocol:.protocol,
 settings:(if .protocol=="vless" then {vnext:[{address:.server,port:.port,users:[{id:.uuid,encryption:"none",flow:.flow}]}]}
   elif .protocol=="trojan" then {servers:[{address:.server,port:.port,password:.password}]}
   elif .protocol=="hysteria" then {version:2,address:.server,port:.port}
   elif .protocol=="shadowsocks" then {servers:[{address:.server,port:.port,method:.cipher,password:.password}]}
   elif .protocol=="socks" then {servers:[{address:.server,port:.port,users:[{user:.username,pass:.password}]}]}
   else error("不支持的协议") end),streamSettings:stream} |
if $n.protocol=="hysteria" then .streamSettings.hysteriaSettings.auth=$n.password |
  if ($n.public_ports|length)>1 then
  .streamSettings.finalmask.udp=((.streamSettings.finalmask.udp // [] | map(select(.type!="udphop"))) +
      [{type:"udphop",settings:{mode:"intervalRemote",interval:30,remotePorts:($n.public_ports|map(tostring)|join(","))}}])
  else . end
else . end
