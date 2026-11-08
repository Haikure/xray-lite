#!/usr/bin/env bash
xl_service_alive() {
    case $(xl_init_system) in
        systemd) systemctl is-active --quiet xray-lite;;
        openrc) rc-service xray-lite status >/dev/null 2>&1;;
        direct)
            [[ -r $XL_RUN/core.pid ]] || return 1
            local pid actual
            read -r pid < "$XL_RUN/core.pid"
            [[ $pid =~ ^[0-9]+$ && -r /proc/$pid/cmdline ]] || return 1
            actual=$(readlink "/proc/$pid/exe" 2>/dev/null) || return 1
            [[ $actual == "$XL_STATE/cores/"* ]] && kill -0 "$pid" 2>/dev/null
            ;;
    esac
}
xl_direct_stop() {
    local pid count
    if xl_service_alive; then
        read -r pid < "$XL_RUN/core.pid"; kill -TERM "$pid" 2>/dev/null || true
        for count in {1..50}; do kill -0 "$pid" 2>/dev/null || break; [[ $(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null) == Z ]] && break; sleep .1; done
        if kill -0 "$pid" 2>/dev/null && [[ $(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null) != Z ]]; then kill -KILL "$pid" 2>/dev/null || true; fi
    fi
    rm -f "$XL_RUN/core.pid" "$XL_RUN/confirmed"
}
xl_logs_rotate() {
    local log="$XL_STATE/logs/core.log"
    if [[ -f $log && $(wc -c < "$log") -gt 1048576 ]]; then tail -c 1048576 "$log" > "$log.1"; : > "$log"; fi
    local argo
    for argo in "$XL_STATE/logs/"argo-*.log "$XL_STATE/logs/tick.log"; do
        [[ -f $argo ]] || continue
        if [[ $(wc -c < "$argo") -gt 1048576 ]]; then tail -c 1048576 "$argo" > "$argo.1"; : > "$argo"; fi
    done
}
xl_run() {
    xl_root; xl_runtime_env
    local gen baseline; gen=$(xl_current); baseline=$(xl_runtime_digest "$gen")
    [[ -x $gen/core ]] || xl_die '核心尚未安装。'
    xl_prepare_dir "$XL_RUN"
    printf '%s\n' "$$" > "$XL_RUN/core.pid"
    ( sleep 1; if kill -0 "$$" 2>/dev/null && [[ $(xl_current) == "$gen" && $(xl_runtime_digest "$gen") == "$baseline" ]]; then printf '%s\n' "$baseline" > "$XL_RUN/confirmed"; fi ) 9>&- &
    exec "$gen/core" run -config "$gen/config.json"
}
xl_direct_start() {
    xl_service_alive && return 0
    xl_logs_rotate
    nohup bash "$XL_APP/xl" run >> "$XL_STATE/logs/core.log" 2>&1 < /dev/null 9>&- &
    local pid=$!
    sleep 1
    kill -0 "$pid" 2>/dev/null && xl_service_alive || { tail -n 25 "$XL_STATE/logs/core.log" >&2; return 1; }
}
xl_service_stop() {
    xl_argo_stop
    case $(xl_init_system) in systemd) systemctl stop xray-lite;; openrc) rc-service xray-lite stop;; direct) xl_direct_stop;; esac
    rm -f "$XL_RUN/confirmed"
}
xl_service_start() {
    local gen baseline; gen=$(xl_current); baseline=$(xl_runtime_digest "$gen")
    xl_validate "$gen" || return 1
    xl_forward_apply "$gen" || return 1
    case $(xl_init_system) in systemd) systemctl start xray-lite;; openrc) rc-service xray-lite start;; direct) xl_direct_start;; esac || return 1
    sleep 1
    xl_service_alive || { xl_note '服务启动失败'; return 1; }
    if [[ $(xl_init_system) == direct ]]; then xl_argo_reconcile "$gen" || return 1; fi
    if [[ $(xl_runtime_digest "$gen") == "$baseline" ]]; then printf '%s\n' "$baseline" > "$XL_RUN/confirmed"; fi
}
xl_service_restart() { xl_service_stop || return 1; xl_service_start; }
xl_service_status() {
    printf '服务模式：%s\n%s\n' "$(xl_init_system)" "$(xl_runtime_state "$(xl_current)")"
    printf '脚本目录：%s/app\n核心入口：%s/current/core\n核心文件：%s\n配置文件：%s/current/config.json\n' "$XL_HOME" "$XL_STATE" "$(readlink -f "$(xl_core)")" "$XL_STATE"
    "$(xl_core)" version
}
xl_service_logs() {
    case $(xl_init_system) in systemd) journalctl -u xray-lite -n 60 -f;; *) tail -n 60 -F "$XL_STATE/logs/core.log";; esac
}
xl_service_install() {
    case $(xl_init_system) in
        systemd)
            cat > /etc/systemd/system/xray-lite.service <<EOF
[Unit]
Description=xray-lite official Xray core
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/bin/bash $XL_HOME/app/xl run
ExecStartPost=/bin/bash $XL_HOME/app/xl argo-sync
ExecStopPost=/bin/bash $XL_HOME/app/xl argo-stop
Environment=XL_HOME=$XL_HOME XL_STATE=$XL_STATE XL_RUN=$XL_RUN XL_SERVICE_MODE=systemd
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
UMask=0077
[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload; systemctl enable xray-lite
            ;;
        openrc)
            cat > /etc/init.d/xray-lite <<EOF
#!/sbin/openrc-run
description="xray-lite official Xray core"
command="/bin/bash"
command_args="$XL_HOME/app/xl run"
command_background=true
pidfile="$XL_RUN/openrc.pid"
output_log="$XL_STATE/logs/core.log"
error_log="$XL_STATE/logs/core.log"
export XL_HOME=$XL_HOME XL_STATE=$XL_STATE XL_RUN=$XL_RUN XL_SERVICE_MODE=openrc
depend() { need net; }
start_post() { /bin/bash $XL_HOME/app/xl argo-sync; }
stop_post() { /bin/bash $XL_HOME/app/xl argo-stop; }
EOF
            chmod 755 /etc/init.d/xray-lite; rc-update add xray-lite default
            ;;
        direct) xl_note "无可用 init；容器启动命令可设为：$XL_LINK run";;
    esac
}
xl_schedule_edit() {
    local minutes=$1 gen=$2
    [[ $minutes =~ ^[0-9]+$ ]] && (( minutes <= 525600 )) || xl_die '分钟数应为 0..525600；0 表示禁用。'
    xl_jq "$gen/meta.json" --argjson m "$minutes" '.restart_minutes=$m'
}
xl_tick() {
    local minutes now last=0
    xl_logs_rotate
    minutes=$(jq -r '.restart_minutes' "$(xl_current)/meta.json")
    [[ $minutes -gt 0 ]] || return 0
    now=$(date +%s); [[ -f $XL_RUN/last-restart ]] && read -r last < "$XL_RUN/last-restart"
    if (( now - last >= minutes * 60 )); then xl_service_restart; printf '%s\n' "$now" > "$XL_RUN/last-restart"; fi
}
xl_diagnose() {
    printf 'UTC 时间：%s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')"
    command -v timedatectl >/dev/null && timedatectl status 2>/dev/null || true
    printf '\nDNS：\n'; cat /etc/resolv.conf
    if command -v getent >/dev/null; then getent ahosts github.com || xl_note 'DNS 解析失败'; fi
    xl_environment
}
