# Mihomo LaunchDaemon 快捷操作
# 由 ~/.zshrc source 加载；使用 mm <子命令>。
# 服务启停需要 sudo；stop 会卸载服务，start 会重新加载。
# stop 不禁用开机自启；enable 启用自启并启动，disable 禁用自启并停止。
# 仅修改 config.yaml 后用 restart；修改 plist 后用 stop 再 start。

mm() {
    local action="${1:-help}"
    local service='system/local.mihomo'
    local plist='/Library/LaunchDaemons/local.mihomo.plist'
    local bin='/usr/local/bin/mihomo'
    local dir="$HOME/.config/mihomo"
    local config="$dir/config.yaml"
    local blue='' green='' red='' reset='' error_red='' error_reset=''
    # 仅交互式终端着色；尊重 NO_COLOR，避免污染管道和重定向。
    if [[ -t 1 && "${TERM:-dumb}" != dumb && -z "${NO_COLOR+x}" ]]; then
        blue=$'\e[34m'
        green=$'\e[32m'
        red=$'\e[31m'
        reset=$'\e[0m'
    fi
    if [[ -t 2 && "${TERM:-dumb}" != dumb && -z "${NO_COLOR+x}" ]]; then
        error_red=$'\e[31m'
        error_reset=$'\e[0m'
    fi
    shift $(( $# > 0 ? 1 : 0 ))

    case "$action" in
        status)
            local service_info launchd_state service_pid disabled_info override
            local run_at_load keep_alive plist_disabled autostart

            print -r -- "${blue}服务：${reset}$service"
            if service_info=$(command launchctl print "$service" 2>&1); then
                launchd_state=$(print -r -- "$service_info" | command awk '/^[[:space:]]*state = / { print $3; exit }')
                service_pid=$(print -r -- "$service_info" | command awk '/^[[:space:]]*pid = / { print $3; exit }')
                if [[ "$launchd_state" == running ]]; then
                    print -r -- "${blue}运行状态：${reset}${green}运行中${reset}"
                else
                    print -r -- "${blue}运行状态：${reset}${red}已加载，未运行（${launchd_state:-未知}）${reset}"
                fi
                [[ -n "$service_pid" ]] && print -r -- "${blue}PID：${reset}$service_pid"
            elif [[ "$service_info" == *'Could not find service'* ]]; then
                print -r -- "${blue}运行状态：${reset}${red}未加载 / 已停止${reset}"
            else
                print -r -- "${blue}运行状态：${reset}${red}未知（无法查询 launchd）${reset}"
                print -u2 -r -- "${error_red}${service_info}${error_reset}"
            fi

            # 自启与当前是否运行无关；launchd 的显式设置优先于 plist 的 Disabled。
            if [[ ! -f "$plist" ]]; then
                autostart='未启用（plist 文件不存在）'
            elif ! command plutil -lint "$plist" >/dev/null 2>&1; then
                autostart='未知（plist 无效或不可读）'
            elif ! disabled_info=$(command launchctl print-disabled system 2>&1); then
                autostart='未知（无法查询 launchd 禁用记录）'
            else
                override=$(print -r -- "$disabled_info" | command awk -v label="${service#system/}" '
                    $1 == "\"" label "\"" && $2 == "=>" {
                        gsub(/[;,]/, "", $3); print $3; exit
                    }')
                plist_disabled=$(command plutil -extract Disabled raw -o - "$plist" 2>/dev/null)
                run_at_load=$(command plutil -extract RunAtLoad raw -o - "$plist" 2>/dev/null)
                keep_alive=$(command plutil -extract KeepAlive raw -o - "$plist" 2>/dev/null)
                if [[ "$override" == disabled || "$override" == true ]]; then
                    autostart='已禁用（launchctl disable）'
                elif [[ "$override" != enabled && "$override" != false && "$plist_disabled" == true ]]; then
                    autostart='已禁用（plist Disabled=true）'
                elif [[ "$run_at_load" == true || "$keep_alive" == true ]]; then
                    autostart='已启用（开机加载并启动）'
                else
                    autostart='未设置自动启动（未启用 RunAtLoad / 无条件 KeepAlive）'
                fi
            fi
            local autostart_color="$red"
            [[ "$autostart" == 已启用* ]] && autostart_color="$green"
            print -r -- "${blue}开机自启：${reset}${autostart_color}${autostart}${reset}"
            ;;
        info)
            command launchctl print "$service"
            ;;
        start)
            if command launchctl print "$service" >/dev/null 2>&1; then
                command sudo launchctl kickstart "$service"
            else
                command sudo launchctl bootstrap system "$plist"
            fi
            ;;
        stop)
            if command launchctl print "$service" >/dev/null 2>&1; then
                command sudo launchctl bootout "$service"
            else
                print -r -- "${blue}Mihomo 服务未加载，无需停止。${reset}"
            fi
            ;;
        restart)
            if command launchctl print "$service" >/dev/null 2>&1; then
                command sudo launchctl kickstart -k "$service"
            else
                command sudo launchctl bootstrap system "$plist"
            fi
            ;;
        enable)
            command sudo launchctl enable "$service" && mm start
            ;;
        disable)
            command sudo launchctl disable "$service" && mm stop
            ;;
        logs|log|errors)
            local log_file="$dir/logs/mihomo.stdout.log"
            [[ "$action" == errors ]] && log_file="$dir/logs/mihomo.stderr.log"
            if [[ -z "$reset" ]]; then
                command tail -n 50 -f "$log_file"
            else
                # 保留 tail 的失败状态；逐行刷新，避免跟踪日志时缓冲延迟。
                setopt localoptions pipefail
                command tail -n 50 -f "$log_file" | command awk \
                    -v blue="$blue" -v green="$green" -v red="$red" -v reset="$reset" '
                    {
                        header = $0
                        body = ""
                        # 只解析 msg= 前的字段，避免误把消息中的 level= 当成日志等级。
                        if (match(header, /(^|[[:space:]])msg=/)) {
                            body = substr(header, RSTART + RLENGTH)
                            header = substr(header, 1, RSTART + RLENGTH - 1)
                        }
                        if (match(header, /(^|[[:space:]])level=("[^"]*"|[^[:space:]]+)/)) {
                            token = substr(header, RSTART, RLENGTH)
                            level = token
                            sub(/^[[:space:]]*level=/, "", level)
                            gsub(/"/, "", level)
                            level = tolower(level)
                            color = ""
                            if (level == "info") color = green
                            else if (level == "debug" || level == "trace") color = blue
                            else if (level ~ /^(warn|warning|error|fatal|panic)$/) color = red
                            if (color != "")
                                header = substr(header, 1, RSTART - 1) color token reset substr(header, RSTART + RLENGTH)
                        }
                        if (match(header, /(^|[[:space:]])time="[^"]*"/))
                            header = substr(header, 1, RSTART - 1) blue substr(header, RSTART, RLENGTH) reset substr(header, RSTART + RLENGTH)
                        gsub(/\[(TCP|UDP)\]/, blue "&" reset, body)
                        print header body
                        fflush()
                    }'
            fi
            ;;
        check|test)
            # 与系统服务使用相同权限，避免读取配置/缓存时权限不一致。
            command sudo "$bin" -t -d "$dir" -f "$config"
            ;;
        config|edit)
            local -a editor_cmd
            editor_cmd=("${(@z)${VISUAL:-${EDITOR:-vi}}}")
            "${editor_cmd[@]}" "$config"
            ;;
        version)
            command "$bin" -v
            ;;
        help|-h|--help)
            print -r -- "用法：${blue}mm <子命令>${reset}
  ${blue}status${reset}    简洁查看运行状态、PID 和开机自启状态
  ${blue}info${reset}      查看 launchd 服务完整信息
  ${blue}start${reset}     加载并启动服务（sudo）
  ${blue}stop${reset}      卸载并停止服务，不禁用开机自启（sudo）
  ${blue}restart${reset}   重启服务；未加载时直接加载（sudo，会短暂断网）
  ${blue}enable${reset}    启用开机自启并立即启动（sudo）
  ${blue}disable${reset}   禁用开机自启并立即停止（sudo，会中断代理）
  ${blue}logs${reset}      彩色跟踪运行日志：info 绿、debug 蓝、warn/error 红
  ${blue}errors${reset}    跟踪标准错误日志，存在等级字段时同样着色
  ${blue}check${reset}     检查 Mihomo 配置，不启动代理（sudo）
  ${blue}config${reset}    用 \$VISUAL / \$EDITOR / vi 编辑配置
  ${blue}version${reset}   查看 Mihomo 版本
  ${blue}help${reset}      显示帮助

${blue}配置：${reset}~/.config/mihomo/config.yaml
${blue}服务：${reset}/Library/LaunchDaemons/local.mihomo.plist
修改配置后：${blue}mm check && mm restart${reset}
修改 plist 后：${blue}mm stop && mm start${reset}
日志跟踪：Ctrl-C 退出；NO_COLOR=1 mm logs 可关闭着色"
            ;;
        *)
            print -u2 -r -- "${error_red}未知子命令：$action；使用 mm help 查看帮助。${error_reset}"
            return 1
            ;;
    esac
}
