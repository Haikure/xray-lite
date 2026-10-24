#!/usr/bin/env bash
xl_arch() {
    case $(uname -m) in
        x86_64|amd64) printf '64';; aarch64|arm64) printf 'arm64-v8a';; armv7*|armhf) printf 'arm32-v7a';;
        *) xl_die "不支持的架构：$(uname -m)";;
    esac
}
xl_init_system() {
    case $XL_SERVICE_MODE in direct|systemd|openrc) printf '%s' "$XL_SERVICE_MODE"; return;; auto) ;; *) xl_die '无效的服务模式';; esac
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null && systemctl show-environment >/dev/null 2>&1; then printf systemd
    elif [[ -d /run/openrc ]] && command -v rc-service >/dev/null && rc-status >/dev/null 2>&1; then printf openrc
    else printf direct; fi
}
xl_memory_limit() {
    local p value limit
    limit=$(awk '/MemTotal:/ {printf "%.0f", $2*1024}' /proc/meminfo)
    for p in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
        if [[ -r $p ]]; then read -r value < "$p"; if [[ $value =~ ^[0-9]+$ ]] && (( value > 0 && value < limit )); then limit=$value; fi; fi
    done
    printf '%s' "$limit"
}
xl_runtime_env() {
    local limit; limit=$(xl_memory_limit)
    export GOMEMLIMIT="$(( limit * 60 / 100 ))B" GOGC=50
}
xl_environment() {
    local cap=0 container=no
    [[ -f /.dockerenv || -f /run/.containerenv ]] && container=yes
    if [[ -r /proc/self/status ]]; then
        local hex; hex=$(awk '/CapEff:/ {print $2}' /proc/self/status)
        (( (16#$hex & 4096) != 0 )) && cap=1
    fi
    jq -n --arg arch "$(xl_arch)" --arg init "$(xl_init_system)" --arg container "$container" --argjson memory "$(xl_memory_limit)" --argjson net_admin "$cap" \
        '{arch:$arch,init:$init,container:$container,memory_limit_bytes:$memory,net_admin:($net_admin==1),host_port_publishing:"容器内无法确认，需在宿主机核对 TCP/UDP 发布"}'
}
