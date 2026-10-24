# Xray config is authoritative. Only presentation and public endpoints use metadata.
def users: .settings.clients // .settings.users // [];
def transport:
  (.streamSettings.method // .streamSettings.network // "raw") |
  if .=="raw" then "tcp" elif .=="websocket" then "ws" elif .=="splithttp" then "xhttp" else . end;
def ports:
  if type=="number" then if .>=1 and .<=65535 and .==floor then [.] else error("端口超出范围") end else
    split(",") | map(split("-")|map(tonumber)|
      if all(.[];.>=1 and .<=65535 and .==floor) and (length==1 or (length==2 and .[0]<=.[1])) then
        if length==1 then . else [range(.[0];.[1]+1)] end else error("端口范围无效") end) | add
  end;
def wire:
  if .protocol=="hysteria" then ["udp"]
  elif .protocol=="shadowsocks" then ((.settings.network // "tcp,udp")|split(","))
  elif .protocol=="socks" and .settings.udp==true then ["tcp","udp"]
  elif .protocol=="dokodemo-door" then ((.settings.network // "tcp")|split(","))
  else ["tcp"] end;
def snapshot($meta;$id):
  .inbounds[] | select(.tag==("xl-"+$id)) | . as $i |
  $meta.nodes[$id] as $m |
  ($i.port|ports) as $ports |
  if ($ports|length)>1 and $m.public_port!=null then error("端口范围的公网端口应通过 NAT mappings 声明") else . end |
  ($i|wire) as $wire |
  [ $ports[] as $p | if $meta.nat.enabled then
      [$meta.nat.mappings[]|select(.local==$p and (.protocol as $w|$wire|index($w)!=null))] as $maps |
      if ($maps|length)!=($wire|length) then error("当前监听端口缺少已声明的 TCP/UDP NAT 映射") else
      if ($maps|map(.public)|unique|length)!=1 then error("同一节点的 TCP/UDP 公网端口不同，客户端无法表达") else $maps[0].public end end
    else ($m.public_port // $p) end ] as $public |
  ($i.streamSettings // {}) as $s |
  ($s.tlsSettings // {}) as $tls |
  ($s.realitySettings // {}) as $r |
  ($i|users) as $users |
  {id:$id,name:($m.name // $id),protocol:$i.protocol,listen:($i.listen // "0.0.0.0"),ports:$ports,
   server:(($m.public_address // $meta.nat.address // "")|ltrimstr("[")|rtrimstr("]")),port:$public[0],public_ports:$public,
   transport:($i|transport),security:($s.security // "none"),
   uuid:($users[0].id // ""),password:($users[0].password // $users[0].auth // $i.settings.password // $i.settings.accounts[0].pass // ""),
   username:($i.settings.accounts[0].user // ""),flow:($users[0].flow // ""),
   cipher:($i.settings.method // ""),udp:($wire|index("udp")!=null),
   sni:(if $s.security=="reality" then $r.serverNames[0] // "" else $tls.serverName // "" end),
   alpn:($tls.alpn // []),short_id:($r.shortIds[0] // ""),private_key:($r.privateKey // ""),
   certificate:($tls.certificates[0].certificateFile // ""),key_file:($tls.certificates[0].keyFile // ""),
   ws:(($s.wsSettings // {})|.headers.Host=(.host // .headers.Host // "")),grpc:($s.grpcSettings // {}),xhttp:($s.xhttpSettings // $s.splithttpSettings // {}),
   hysteria:($s.hysteriaSettings // {}),finalmask:($s.finalmask // {}),
   stream:$s,inbound:$i,user_count:($users|length),client_fingerprint:"chrome"};
