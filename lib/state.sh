#!/usr/bin/env bash
xl_state_init() {
    [[ ! -e $XL_STATE/current ]] || return 0
    local gen="$XL_STATE/generations/initial"
    mkdir -p "$gen" "$XL_STATE/certs" "$XL_STATE/cores" "$XL_STATE/logs"
    printf '%s\n' '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"},{"tag":"block","protocol":"blackhole"}],"routing":{"rules":[]}}' > "$gen/config.json"
    printf '%s\n' '{"schema":1,"nodes":{},"nat":{"enabled":false,"address":"","mappings":[]},"forwards":{},"argo":{},"restart_minutes":0}' > "$gen/meta.json"
    ln -s "$gen" "$XL_STATE/current"
}
xl_switch() { ln -sfn "$1" "$XL_STATE/current.next" && mv -Tf "$XL_STATE/current.next" "$XL_STATE/current"; }
xl_validate() {
    local gen=$1
    xl_validate_json "$gen/config.json"; xl_validate_json "$gen/meta.json"
    jq -e '(.nodes|type)=="object" and (.forwards|type)=="object" and (.argo|type)=="object" and (.nat.enabled|type)=="boolean"' "$gen/meta.json" >/dev/null || xl_die '管理元数据结构无效。'
    jq -e '[.inbounds[].tag]|length== (unique|length)' "$gen/config.json" >/dev/null || xl_die '入站 tag 重复。'
    [[ -x $gen/core ]] || xl_die '核心尚未安装。'
    timeout 30 "$gen/core" run -test -config "$gen/config.json" >&2 || xl_die '官方 Xray 配置检查失败，保留原状态。'
    xl_validate_endpoints "$gen"
    xl_validate_certificates "$gen"
    xl_forward_validate "$gen"
}
xl_runtime_digest() {
    local gen=$1 cert
    {
        cat "$gen/config.json"; xl_hash "$gen/core"
        while IFS= read -r cert; do
            printf '%s\n' "$cert"
            if [[ -r $cert ]]; then xl_hash "$cert"; else printf 'MISSING\n'; fi
        done < <(jq -r '.inbounds[].streamSettings.tlsSettings.certificates[]? | .certificateFile?,.keyFile? | select(type=="string")' "$gen/config.json")
    } | sha256sum | awk '{print $1}'
}
xl_confirm() { xl_runtime_digest "$1" > "$XL_RUN/confirmed.tmp"; mv -f "$XL_RUN/confirmed.tmp" "$XL_RUN/confirmed"; }
xl_runtime_state() {
    if ! xl_service_alive; then printf '未运行';
    elif [[ -r $XL_RUN/confirmed && $(cat "$XL_RUN/confirmed") == "$(xl_runtime_digest "$1")" ]]; then printf '运行态已确认';
    else printf '运行态尚未确认（磁盘配置、核心或证书已变化）'; fi
}
xl_transaction() (
    # Called under the global lock. EXIT also handles signals and partial failures.
    set -Eeuo pipefail
    local old gen switched=0 running=0 success=0
    old=$(xl_current); gen=$(mktemp -d "$XL_STATE/generations/gen.XXXXXXXX")
    cp -a "$old/." "$gen/"
    xl_service_alive && running=1
    xl_recover() {
        local rc=$?
        trap - EXIT INT TERM
        if (( success == 0 && switched == 1 )); then
            xl_note '应用失败，恢复上一份配置、元数据、核心和转发规则。'
            xl_service_stop || true
            xl_switch "$old"
            xl_forward_apply "$old" || xl_note '恢复转发规则失败，请检查 nftables。'
            if (( running )); then xl_service_restart || xl_note '恢复旧服务失败，请检查 xl logs。'; fi
        fi
        if (( success == 0 )); then rm -rf -- "$gen"; fi
        exit "$rc"
    }
    trap xl_recover EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    "$@" "$gen"
    xl_validate "$gen"
    switched=1; xl_switch "$gen"
    xl_forward_apply "$gen"
    if (( running )); then xl_service_restart; elif [[ ${XL_TX_START:-0} == 1 ]]; then xl_service_start; fi
    printf '%s\n' "$old" > "$XL_STATE/previous"
    success=1
    xl_note '修改已应用。'
)
xl_rollback_edit() { local gen=$1 target; target=$(cat "$XL_STATE/previous"); [[ -d $target && $target == "$XL_STATE/generations/"* ]] || xl_die '无可用回滚版本。'; rm -rf -- "$gen"; mkdir -m 700 "$gen"; cp -a "$target/." "$gen/"; }
xl_check() { xl_validate "$XL_GEN"; printf '配置检查通过；%s\n' "$(xl_runtime_state "$XL_GEN")"; }
