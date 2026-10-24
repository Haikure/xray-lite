#!/usr/bin/env bash
xl_menu_header() {
    local version status count=0 init
    version=$(cat "$XL_APP/VERSION"); init=$(xl_init_system)
    status='尚未安装'
    if [[ -f $XL_STATE/current/config.json ]]; then
        count=$(jq '.inbounds|map(select(.tag|startswith("xl-")))|length' "$XL_STATE/current/config.json")
        status='已停止'; if xl_service_alive; then status='运行中'; fi
    fi
    if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} ]]; then printf '\033[1;36m'; fi
    printf '\n════════════════════════════════════════════════\n'
    printf '  xray-lite v%s · 官方 Xray-core\n' "$version"
    printf '  Haikure/xray-lite\n'
    printf '  服务：%s  节点：%s  模式：%s\n' "$status" "$count" "$init"
    printf '════════════════════════════════════════════════\n'
    if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} ]]; then printf '\033[0m'; fi
    cat <<'EOF'
  节点管理
   1 添加节点       2 Argo 隧道       3 查看节点
   4 删除节点       5 修改节点      20 批量创建
  服务管理
   6 重启服务       7 停止服务       8 运行状态
   9 实时日志      10 定时重启      22 启动服务
  配置与维护
  11 DNS/时间诊断  12 配置检查      13 脚本更新
  14 DNS 设置      15 核心更新      16 NAT 设置
  17 卸载          23 回滚
  进阶功能
  18 中转/导入     19 端口转发      21 批量 YAML

   0 退出
EOF
}
xl_prompt_secret() {
    local _secret_label=$1 _secret_target=$2
    if [[ -t 0 ]]; then
        IFS= read -r -s -p "$_secret_label：" "$_secret_target" || return 1
        printf '\n' >&2
    else IFS= read -r "$_secret_target" || return 1; fi
}
xl_menu_file_command() (
    # JSON and passwords travel through a private file, not command arguments.
    local json=$1; shift
    local file; file=$(mktemp)
    trap 'rm -f -- "$file"' EXIT
    printf '%s\n' "$json" > "$file"
    bash "$XL_APP/xl" "$@" --file "$file"
)
xl_pick_node() {
    local _pick_target=$1 _pick_rows _pick_selection _pick_id _pick_index=0 _pick_label _pick_protocol _pick_port
    _pick_rows=$(xl_read xl_node_list) || return 1
    [[ -n $_pick_rows ]] || { xl_note '暂无节点，请先添加。'; return 1; }
    local -a _pick_ids=()
    while IFS=$'\t' read -r _pick_id _pick_label _pick_protocol _pick_port; do
        _pick_ids+=("$_pick_id"); _pick_index=$((_pick_index+1))
        printf '%2s) %s · %s · %s\n' "$_pick_index" "$_pick_label" "$_pick_protocol" "$_pick_port" >&2
    done <<< "$_pick_rows"
    xl_prompt '节点序号（0 返回，也可输入节点 ID）' _pick_selection 0 || return 1
    [[ $_pick_selection != 0 ]] || return 1
    if [[ $_pick_selection =~ ^[0-9]+$ ]]; then
        (( 10#$_pick_selection >= 1 && 10#$_pick_selection <= ${#_pick_ids[@]} )) || { xl_note '节点序号无效。'; return 1; }
        printf -v "$_pick_target" '%s' "${_pick_ids[10#$_pick_selection-1]}"
    else printf -v "$_pick_target" '%s' "$_pick_selection"; fi
}
xl_node_edit_interactive() {
    local id=${1:-} choice field value patch model
    [[ -n $id ]] || xl_pick_node id || return 0
    while :; do
        model=$(xl_read xl_snapshot "$id") || return 1
        printf '\n修改：%s · %s / %s / %s\n' "$(jq -r .name <<< "$model")" "$(jq -r .protocol <<< "$model")" "$(jq -r .transport <<< "$model")" "$(jq -r .security <<< "$model")"
        cat <<'EOF'
 1 名称         2 公网地址     3 监听端口     4 公网端口
 5 UUID         6 密码        7 SOCKS用户名 8 SNI
 9 传输路径    10 Host       11 gRPC服务名 12 证书和私钥
13 Reality目标 14 Short ID   15 Reality私钥
16 SS算法      17 SOCKS UDP  18 HY2上传Mbps 19 HY2下载Mbps
20 Salamander  21 HY2跳跃端口 22 JSON文件   0 返回
EOF
        xl_prompt 选择 choice 0 || return 0
        case $choice in
            0) return 0;;
            1) field=name;; 2) field=public_address;; 3) field=port;; 4) field=public_port;;
            5) field=uuid;; 6) field=password;; 7) field=username;; 8) field=sni;;
            9) field=path;; 10) field=host;; 11) field=service_name;;
            12) local cert key; xl_prompt '完整证书链绝对路径' cert || return 0; xl_prompt '私钥绝对路径' key || return 0; bash "$XL_APP/xl" cert "$id" "$cert" "$key" || true; continue;;
            13) field=target;; 14) field=short_id;; 15) field=private_key;; 16) field=cipher;;
            17) field=udp;; 18) field=up;; 19) field=down;; 20) field=obfs_password;; 21) field=hop_ports;;
            22) xl_prompt '修改 JSON 文件' value || return 0; bash "$XL_APP/xl" node set "$id" --file "$value" || true; continue;;
            *) xl_note '选择无效。'; continue;;
        esac
        case $field in password|private_key|obfs_password) xl_prompt_secret '新值（输入隐藏）' value || return 0;; *) xl_prompt "新值 $field" value || return 0;; esac
        patch=$(jq -cn --arg key "$field" --arg value "$value" '{($key):$value}')
        xl_menu_file_command "$patch" node set "$id" || true
    done
}
xl_forward_interactive() {
    local choice id port target target_port protocol engine spec
    cat <<'EOF'
 1 添加/修改规则   2 查看规则   3 删除规则   4 切换引擎   0 返回
EOF
    xl_prompt 选择 choice 0 || return 0
    case $choice in
        0) return;; 2) bash "$XL_APP/xl" forward list; return;;
        3) xl_prompt 规则ID id || return 0; bash "$XL_APP/xl" forward delete "$id"; return;;
        4) xl_prompt 规则ID id || return 0; xl_prompt '引擎 xray/nftables' engine xray || return 0; bash "$XL_APP/xl" forward engine "$id" "$engine"; return;;
        1) ;; *) xl_note '选择无效。'; return 1;;
    esac
    xl_prompt 规则ID id || return 0
    xl_prompt 监听端口 port 20001 || return 0
    xl_prompt 目标IP或域名 target || return 0
    xl_prompt 目标端口 target_port 443 || return 0
    xl_prompt '协议 tcp/udp/tcp,udp' protocol tcp || return 0
    xl_prompt '引擎 xray/nftables' engine xray || return 0
    spec=$(jq -cn --arg port "$port" --arg target "$target" --arg tp "$target_port" --arg protocol "$protocol" --arg engine "$engine" '{port:$port,target:$target,target_port:$tp,protocol:$protocol,engine:$engine}')
    xl_menu_file_command "$spec" forward set "$id"
}
xl_dns_interactive() (
    local servers file
    xl_prompt 'DNS 地址（逗号分隔）' servers '1.1.1.1,8.8.8.8,localhost' || return 0
    file=$(mktemp); trap 'rm -f -- "$file"' EXIT
    jq -n --arg servers "$servers" '{servers:($servers|split(",")|map(gsub("^ +| +$";"")|select(length>0))),queryStrategy:"UseIP"}' > "$file"
    bash "$XL_APP/xl" dns "$file"
)
xl_nat_interactive() (
    local choice address mappings='[]' local_port public_port protocol file
    printf '\n1 配置 NAT 映射   2 查看当前声明   3 关闭 NAT 模式   0 返回\n'
    xl_prompt 选择 choice 0 || return 0
    case $choice in 0) return;; 2) bash "$XL_APP/xl" nat show; return;; 1|3) ;; *) xl_note '选择无效。'; return 1;; esac
    file=$(mktemp); trap 'rm -f -- "$file"' EXIT
    if [[ $choice == 3 ]]; then printf '%s\n' '{"enabled":false,"address":"","mappings":[]}' > "$file"
    else
        xl_note '请输入全部映射；保存后替换现有 NAT 声明。每个跳跃端口需逐项声明。'
        xl_prompt 公网IP或域名 address || return 0
        while :; do
            xl_prompt '容器监听端口（0 完成）' local_port 0 || return 0
            [[ $local_port != 0 ]] || break
            xl_prompt 公网端口 public_port "$local_port" || return 0
            xl_prompt '协议 tcp/udp/tcp,udp' protocol tcp || return 0
            xl_port "$local_port" && xl_port "$public_port" || { xl_note '端口无效。'; continue; }
            [[ $protocol == tcp || $protocol == udp || $protocol == tcp,udp ]] || { xl_note '协议无效。'; continue; }
            mappings=$(jq -cn --argjson old "$mappings" --argjson local "$local_port" --argjson public "$public_port" --arg protocol "$protocol" '$old + [$protocol|split(",")[]|{local:$local,public:$public,protocol:.}]')
        done
        jq -n --arg address "$address" --argjson mappings "$mappings" '{enabled:true,address:$address,mappings:$mappings}' > "$file"
    fi
    bash "$XL_APP/xl" nat set "$file"
)
xl_argo_interactive() {
    local choice id kind hostname tunnel credentials spec
    printf '\n1 安装/更新 cloudflared   2 添加隧道   3 查看隧道   4 删除隧道   0 返回\n'
    xl_prompt 选择 choice 0 || return 0
    case $choice in 0) return;; 1) bash "$XL_APP/xl" argo install; return;; 3) bash "$XL_APP/xl" argo list; return;; 2|4) ;; *) xl_note '选择无效。'; return 1;; esac
    xl_pick_node id || return 0
    if [[ $choice == 4 ]]; then bash "$XL_APP/xl" argo delete "$id"; return; fi
    xl_prompt '类型 quick（临时）/fixed（固定）' kind quick || return 0
    spec=$(jq -cn --arg kind "$kind" '{kind:$kind}')
    if [[ $kind == fixed ]]; then
        xl_prompt 公网域名 hostname || return 0
        xl_prompt 隧道UUID tunnel || return 0
        xl_prompt 凭据JSON绝对路径 credentials || return 0
        spec=$(jq -cn --arg kind "$kind" --arg hostname "$hostname" --arg tunnel "$tunnel" --arg credentials "$credentials" '{kind:$kind,hostname:$hostname,tunnel_id:$tunnel,credentials:$credentials}')
    fi
    xl_menu_file_command "$spec" argo add "$id"
}
