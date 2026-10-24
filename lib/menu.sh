#!/usr/bin/env bash
xl_help() {
    cat <<'EOF'
xray-lite：官方 Xray-core 管理器（需要容器内 root）
xl                                      中文菜单
xl env | diagnose | check                环境 / DNS 与时间 / 检查配置
xl node add --file spec.json             创建节点（也支持 --protocol vless --port 10001 ...）
xl node list | show ID | delete ID       节点列表 / 查看链接及 YAML / 删除
xl node set ID --file patch.json         修改指定字段，保留当前配置其他字段
xl batch nodes.json                     批量创建，任一失败则整批回滚
xl export ID|all yaml|link|xray|json      即时导出（all 仅支持 yaml）
xl cert ID /absolute/fullchain /absolute/key   检查并更换证书
xl nat show | set nat.json              NAT 公网与容器端点声明
xl start | stop | restart | status | logs
xl run                                 前台 Xray（容器入口）
xl supervise                           前台监管，含定时重启与日志轮转
xl schedule MINUTES | tick              定时重启（0 关闭）/ 定时器入口
xl config show | apply config.json      查看 / 检查并应用完整配置
xl dns dns.json                        修改 Xray DNS（对象格式）
xl core update | rollback              官方最新核心（含预发布）/ 恢复前一版本
xl script update owner/repo             校验 Release 资产后更新脚本
xl relay import ID outbound.json        导入 Xray 出口对象
xl relay link ID link.txt               导入第三方分享链接
xl relay token-export NODE passfile     输出项目加密 Token
xl relay token-import ID token.txt passfile
xl relay list | delete ID | route NODE OUTBOUND|direct|block
xl forward set ID --file rule.json      创建或修改 TCP/UDP 转发
xl forward list | delete ID | engine ID xray|nftables
xl argo install | add NODE --file tunnel.json | delete NODE | list
xl uninstall --yes                     卸载本项目服务、程序和数据
EOF
}
xl_core_offline_edit() {
    local release_file=$1 archive=$2 gen=$3 asset tag path version
    jq -e '.draft==false and (.tag_name|type)=="string"' "$release_file" >/dev/null || xl_die '离线文件必须为官方单个非草稿 Release JSON。'
    tag=$(jq -r .tag_name "$release_file")
    [[ $tag =~ ^v[0-9][0-9A-Za-z.-]+$ ]] || xl_die 'Release 版本格式无效。'
    asset=$(jq -ce --arg name "Xray-linux-$(xl_arch).zip" '.assets[]|select(.name==$name)' "$release_file") || xl_die '此发布缺少对应架构。'
    xl_verify_asset "$asset" "$archive"
    path="$gen/core.tmp"; unzip -p "$archive" xray > "$path"; chmod 700 "$path"
    version=$("$path" version | head -n 1); [[ $version == "Xray ${tag#v} "* ]] || xl_die '二进制版本不符。'
    local destination="$XL_STATE/cores/$tag-$(xl_arch)-$(xl_hash "$path")"
    mv "$path" "$destination"; ln -sfn "$destination" "$gen/core"; cp "$release_file" "$gen/core-release.json"
}
xl_bootstrap() {
    xl_state_init
    local start=1 offline=0 release='' archive=''
    while (( $# )); do
        case $1 in --no-start) start=0; shift;; --offline) [[ $# -ge 3 ]] || xl_die '--offline release.json core.zip'; offline=1; release=$2; archive=$3; shift 3;; *) xl_die "安装参数无效：$1";; esac
    done
    xl_service_install
    XL_TX_START=$start
    if (( offline )); then xl_transaction xl_core_offline_edit "$release" "$archive"; else xl_transaction xl_core_edit; fi
}
xl_schedule() {
    xl_transaction xl_schedule_edit "$1"
    if [[ $1 == 0 ]]; then
        if command -v crontab >/dev/null; then
            local cronfile; cronfile=$(mktemp "$XL_STATE/cron.XXXXXXXX")
            { crontab -l 2>/dev/null || true; } | sed '/# xray-lite$/d' > "$cronfile"
            crontab "$cronfile"; rm -f "$cronfile"
        fi
        return
    fi
    if command -v crontab >/dev/null; then
        local file; file=$(mktemp "$XL_STATE/cron.XXXXXXXX")
        { crontab -l 2>/dev/null | sed '/# xray-lite$/d' || true; printf '* * * * * XL_HOME=%s XL_STATE=%s XL_RUN=%s XL_SERVICE_MODE=%s /bin/bash %s/app/xl tick >> %s/logs/tick.log 2>&1 # xray-lite\n' "$XL_HOME" "$XL_STATE" "$XL_RUN" "$XL_SERVICE_MODE" "$XL_HOME" "$XL_STATE"; } > "$file"
        crontab "$file"; rm -f "$file"
        xl_note '已写入每分钟 crontab；请确保 cron 服务正在运行。'
    else xl_note '未安装 cron；运行 xl supervise 或由容器调度器每分钟调用 xl tick。'; fi
}
xl_supervise() {
    xl_lock xl_service_start
    trap 'xl_lock xl_service_stop; exit' INT TERM EXIT
    while :; do sleep 30 & wait $!; xl_lock xl_tick; if ! xl_service_alive; then xl_lock xl_service_start; fi; done
}
xl_uninstall() {
    [[ ${1:-} == --yes ]] || xl_die '卸载会删除本项目配置、密钥和程序；确认后使用 xl uninstall --yes。'
    local dir
    for dir in "$XL_STATE" "$XL_RUN" "$XL_HOME"; do [[ -f $dir/.xray-lite-owned && $(cat "$dir/.xray-lite-owned") == xray-lite ]] || xl_die "拒绝删除非项目目录：$dir"; done
    xl_service_stop
    case $(xl_init_system) in systemd) systemctl disable xray-lite; rm -f /etc/systemd/system/xray-lite.service; systemctl daemon-reload;; openrc) rc-update del xray-lite default; rm -f /etc/init.d/xray-lite;; esac
    if command -v nft >/dev/null && nft list table inet xray_lite >/dev/null 2>&1; then nft delete table inet xray_lite; fi
    if command -v crontab >/dev/null; then local file; file=$(mktemp); { crontab -l 2>/dev/null || true; } | sed '/# xray-lite$/d' > "$file"; crontab "$file"; rm -f "$file"; fi
    [[ $(readlink -f "$XL_LINK") != "$XL_HOME/app/xl" ]] || rm -f "$XL_LINK"
    rm -rf -- "$XL_STATE" "$XL_RUN" "$XL_HOME"
    xl_note 'xray-lite 已卸载。'
}
xl_prompt() { local label=$1 name=$2 fallback=${3:-}; read -r -p "$label${fallback:+ [$fallback]}：" "$name"; [[ -n ${!name} ]] || printf -v "$name" '%s' "$fallback"; }
xl_node_interactive() {
    local choice protocol transport security name address port sni spec
    cat <<'EOF'
1 VLESS TCP Reality Vision     2 VLESS TCP TLS Vision
3 VLESS WS TLS                4 VLESS gRPC TLS
5 VLESS gRPC Reality          6 VLESS XHTTP TLS
7 VLESS XHTTP Reality         8 Trojan TCP TLS
9 Trojan WS TLS              10 Trojan gRPC TLS
11 Trojan gRPC Reality       12 Trojan XHTTP TLS
13 Trojan XHTTP Reality      14 Hysteria2
15 Shadowsocks               16 SOCKS5
17 纯 VLESS TCP（由当前核心检查限制）
EOF
    xl_prompt 选择 choice 1
    case $choice in
        1) protocol=vless; transport=tcp; security=reality;; 2) protocol=vless; transport=tcp; security=tls;;
        3) protocol=vless; transport=ws; security=tls;; 4) protocol=vless; transport=grpc; security=tls;;
        5) protocol=vless; transport=grpc; security=reality;; 6) protocol=vless; transport=xhttp; security=tls;;
        7) protocol=vless; transport=xhttp; security=reality;; 8) protocol=trojan; transport=tcp; security=tls;;
        9) protocol=trojan; transport=ws; security=tls;; 10) protocol=trojan; transport=grpc; security=tls;;
        11) protocol=trojan; transport=grpc; security=reality;; 12) protocol=trojan; transport=xhttp; security=tls;;
        13) protocol=trojan; transport=xhttp; security=reality;; 14) protocol=hysteria; transport=hysteria; security=tls;;
        15) protocol=shadowsocks; transport=tcp; security=none;; 16) protocol=socks; transport=tcp; security=none;;
        17) protocol=vless; transport=tcp; security=none;; *) xl_note '选择无效'; return 1;; esac
    xl_prompt 名称 name "$protocol-$transport"
    xl_prompt 公网IP或域名 address
    xl_prompt 容器监听端口 port 10001
    xl_prompt SNI sni "${address:-www.microsoft.com}"
    spec=$(jq -cn --arg protocol "$protocol" --arg transport "$transport" --arg security "$security" --arg name "$name" --arg public_address "$address" --arg port "$port" --arg sni "$sni" '{protocol:$protocol,transport:$transport,security:$security,name:$name,public_address:$public_address,port:$port,sni:$sni}')
    bash "$XL_APP/xl" node add --file <(printf '%s\n' "$spec")
}
xl_menu() {
    local choice id file action
    while :; do
        cat <<'EOF'

xray-lite · 官方 Xray-core
1 添加节点     2 Argo 隧道     3 查看节点     4 删除节点
5 修改节点     6 重启服务     7 停止服务     8 运行状态
9 实时日志    10 定时重启    11 DNS/时间诊断 12 配置检查
13 脚本更新   14 DNS 设置    15 核心更新    16 NAT 设置
17 卸载       18 中转/导入   19 端口转发    20 批量创建
21 批量 YAML  22 启动服务    23 回滚        0 退出
EOF
        read -r -p '请选择：' choice || return 0
        case $choice in
            0) return;; 1) (xl_node_interactive) || true;;
            2) xl_prompt '操作 install/add/delete/list' action list; case $action in install|list) bash "$XL_APP/xl" argo "$action" || true;; add) xl_prompt 节点ID id; xl_prompt 隧道JSON文件 file; bash "$XL_APP/xl" argo add "$id" --file "$file" || true;; delete) xl_prompt 节点ID id; bash "$XL_APP/xl" argo delete "$id" || true;; esac;;
            3|4|5) xl_read xl_node_list; xl_prompt 节点ID id; case $choice in 3) bash "$XL_APP/xl" node show "$id" || true;; 4) bash "$XL_APP/xl" node delete "$id" || true;; 5) xl_prompt 修改JSON文件 file; bash "$XL_APP/xl" node set "$id" --file "$file" || true;; esac;;
            6) bash "$XL_APP/xl" restart || true;; 7) bash "$XL_APP/xl" stop || true;; 8) bash "$XL_APP/xl" status || true;; 9) bash "$XL_APP/xl" logs || true;;
            10) xl_prompt '间隔分钟，0关闭' id 0; bash "$XL_APP/xl" schedule "$id" || true;;
            11) bash "$XL_APP/xl" diagnose || true;; 12) bash "$XL_APP/xl" check || true;;
            13) xl_prompt 'GitHub owner/repo' id; bash "$XL_APP/xl" script update "$id" || true;;
            14) xl_prompt DNS配置JSON文件 file; bash "$XL_APP/xl" dns "$file" || true;;
            15) bash "$XL_APP/xl" core update || true;; 16) xl_prompt NAT配置JSON文件 file; bash "$XL_APP/xl" nat set "$file" || true;;
            17) xl_prompt '输入 DELETE 删除本项目所有数据' id; [[ $id != DELETE ]] || { xl_main uninstall --yes; return; };;
            18) xl_prompt '操作 import/link/token-import/route/delete/list' action list; case $action in list) bash "$XL_APP/xl" relay list || true;; route) xl_prompt 入口节点ID id; xl_prompt 出口ID或direct file; bash "$XL_APP/xl" relay route "$id" "$file" || true;; import|link) xl_prompt 出口ID id; xl_prompt 文件 file; bash "$XL_APP/xl" relay "$action" "$id" "$file" || true;; delete) xl_prompt 出口ID id; bash "$XL_APP/xl" relay delete "$id" || true;; token-import) local pass; xl_prompt 出口ID id; xl_prompt Token文件 file; xl_prompt 口令文件 pass; bash "$XL_APP/xl" relay token-import "$id" "$file" "$pass" || true;; esac;;
            19) xl_prompt '操作 set/delete/engine/list' action list; case $action in list) bash "$XL_APP/xl" forward list || true;; set) xl_prompt 规则ID id; xl_prompt 规则JSON文件 file; bash "$XL_APP/xl" forward set "$id" --file "$file" || true;; delete) xl_prompt 规则ID id; bash "$XL_APP/xl" forward delete "$id" || true;; engine) xl_prompt 规则ID id; xl_prompt 引擎xray或nftables file; bash "$XL_APP/xl" forward engine "$id" "$file" || true;; esac;;
            20) xl_prompt 节点数组JSON文件 file; bash "$XL_APP/xl" batch "$file" || true;; 21) bash "$XL_APP/xl" export all yaml || true;; 22) bash "$XL_APP/xl" start || true;; 23) bash "$XL_APP/xl" rollback || true;;
            *) xl_note '选择无效。';;
        esac
    done
}
xl_main() {
    local command=${1:-menu} action spec
    (( $# == 0 )) || shift
    case $command in
        help|--help|-h) xl_help;; version|--version) cat "$XL_APP/VERSION";; env) xl_environment;; diagnose) xl_diagnose;;
        menu) xl_root; xl_menu;; run) xl_run;; supervise) xl_supervise;;
        argo-sync) xl_root; xl_argo_reconcile "$(xl_current)";; argo-stop) xl_root; xl_argo_stop;;
        bootstrap) xl_lock xl_bootstrap "$@";;
        start|stop|restart) xl_lock "xl_service_$command";; status) xl_read xl_service_status;; logs) xl_service_logs;; check) xl_read xl_check;;
        node)
            action=${1:-list}; shift || true
            case $action in list) xl_read xl_node_list;; show) xl_read xl_node_show "${1:?节点 ID}";;
                add) spec=$(xl_opts "$@"); xl_lock xl_transaction xl_node_add_edit "$spec";;
                set) local id=${1:?节点 ID}; shift; spec=$(xl_opts "$@"); xl_lock xl_transaction xl_node_update_edit "$id" "$spec";;
                delete) xl_lock xl_transaction xl_node_delete_edit "${1:?节点 ID}";; *) xl_die '节点操作无效。';; esac;;
        batch) xl_lock xl_transaction xl_batch_edit "${1:?JSON 文件}";;
        export) xl_read xl_export "${1:?节点 ID 或 all}" "${2:-yaml}";;
        cert) [[ $# == 3 ]] || xl_die '用法：xl cert ID cert key'; xl_lock xl_transaction xl_cert_replace_edit "$@";;
        nat) case ${1:-show} in show) xl_read xl_show_json meta '.nat';; set) xl_lock xl_transaction xl_nat_edit "${2:?NAT 文件}";; *) xl_die 'NAT 操作无效';; esac;;
        config) case ${1:-show} in show) xl_read xl_show_json config '.';; apply) xl_lock xl_transaction xl_config_edit "${2:?配置文件}";; *) xl_die '配置操作无效';; esac;;
        dns) xl_lock xl_transaction xl_dns_edit "${1:?DNS JSON 文件}";; schedule) xl_lock xl_schedule "${1:?分钟}";; tick) xl_lock xl_tick;;
        core) [[ ${1:-} == update ]] || xl_die '用法：xl core update'; xl_lock xl_transaction xl_core_edit;;
        rollback) xl_lock xl_transaction xl_rollback_edit;;
        script) [[ ${1:-} == update ]] || xl_die '用法：xl script update owner/repo'; xl_lock xl_script_update "${2:?GitHub owner/repo}";;
        relay)
            action=${1:-list}; shift || true
            case $action in list) xl_read xl_show_json config '{outbounds:.outbounds,rules:.routing.rules}';;
                import) xl_lock xl_transaction xl_relay_import_edit "${1:?出口 ID}" "${2:?出口 JSON}";;
                link) xl_lock xl_transaction xl_relay_link_edit "${1:?出口 ID}" "${2:?链接文件}";;
                token-export) xl_read xl_token_export "${1:?节点 ID}" "${2:?口令文件}";;
                token-import) xl_lock xl_transaction xl_relay_token_edit "${1:?出口 ID}" "${2:?Token 文件}" "${3:?口令文件}";;
                route) xl_lock xl_transaction xl_route_edit "${1:?入口 ID}" "${2:?出口 ID}";;
                delete) xl_lock xl_transaction xl_relay_delete_edit "${1:?出口 ID}";; *) xl_die '中转操作无效。';; esac;;
        forward)
            action=${1:-list}; shift || true
            case $action in list) xl_read xl_show_json meta '.forwards';; set) local id=${1:?规则 ID}; shift; spec=$(xl_opts "$@"); xl_lock xl_transaction xl_forward_put_edit "$id" "$spec";;
                delete) xl_lock xl_transaction xl_forward_delete_edit "${1:?规则 ID}";; engine) xl_lock xl_transaction xl_forward_engine_edit "${1:?规则 ID}" "${2:?引擎}";; *) xl_die '转发操作无效。';; esac;;
        argo)
            action=${1:-list}; shift || true
            case $action in install) xl_lock xl_argo_install;; list) xl_read xl_show_json meta '.argo';;
                add) local id=${1:?节点 ID}; shift; spec=$(xl_opts "$@"); xl_lock xl_transaction xl_argo_attach_edit "$id" "$spec";;
                delete) xl_lock xl_transaction xl_argo_delete_edit "${1:?节点 ID}";; *) xl_die 'Argo 操作无效。';; esac;;
        uninstall) xl_lock xl_uninstall "$@";; *) xl_die "未知命令：$command；运行 xl help";;
    esac
}
xl_show_json() { local file=$1 query=$2; jq "$query" "$XL_GEN/$file.json"; }
