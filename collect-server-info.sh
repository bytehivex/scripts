#!/usr/bin/env bash
# shellcheck disable=SC2016

# 只读 Linux 服务器基础信息采集脚本。
# 默认生成 Markdown 报告，并对公网 IP、MAC、Machine ID 等敏感信息做保守脱敏。

set -u

SCRIPT_VERSION="v1.2"
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
# 固定为 C locale，让不同机器的工具输出格式稳定、便于横向对比（不影响脚本内中文字面）
export LC_ALL=C
# 单条采集命令的超时秒数，防止 docker daemon 卡死、journalctl 扫大日志等场景挂起整个采集。
# 可用环境变量覆盖：COLLECT_CMD_TIMEOUT=120 ./collect-server-info.sh ...
CMD_TIMEOUT="${COLLECT_CMD_TIMEOUT:-60}"
TIMEOUT_BIN=""
SERVER_ID=""
OUTPUT_DIR="./server-info-reports"
MASK_SENSITIVE=1
INCLUDE_PUBLIC_IP=0
INCLUDE_NETWORK_PROBE=0
INTERACTIVE=0
REPORT_FILE=""
IS_ROOT=0

usage() {
  cat <<'EOF'
用法：
  collect-server-info.sh --server-id node01 [--output-dir ./reports]

参数：
  --server-id <id>          服务器编号，例如 node01、node02。
  --output-dir <dir>        报告输出目录，默认 ./server-info-reports。
  --include-public-ip       采集公网出口 IP，默认仍会脱敏为 a.b.*.*。
  --include-network-probe   执行轻量外部网络探测：公网 IP、DNS、ping。默认关闭。
  --no-mask                 不脱敏公网 IP、MAC、Machine ID 等信息。仅限私有保存报告时使用。
  --interactive             交互式填写 server-id、输出目录和外部探测选项。
  --version                 显示脚本版本。
  -h, --help                显示帮助。

环境变量：
  COLLECT_CMD_TIMEOUT       单条采集命令的超时秒数，默认 60。命令超时会记录退出码 124 并继续采集。

安全边界：
  - 脚本只读采集，不安装软件、不修改配置、不重启服务。
  - 默认不采集完整公网 IP，不读取 SSH 私钥、token、cookie、证书私钥。
  - 默认脱敏依赖 perl；Debian 12 通常自带 perl。
  - 默认不执行外部测速；网络质量请使用 NodeQuality / Check.Place 等专项报告补充。
EOF
}

log() {
  printf '%s\n' "$*" >&2
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-n}"
  local answer=""
  read -r -p "$prompt" answer || true
  answer="${answer:-$default}"
  case "$answer" in
    y|Y|yes|YES|Yes|是) return 0 ;;
    *) return 1 ;;
  esac
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --server-id)
        if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
          log "错误：--server-id 需要一个非空值。"
          exit 2
        fi
        SERVER_ID="$2"
        shift 2
        ;;
      --output-dir)
        if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
          log "错误：--output-dir 需要一个非空值。"
          exit 2
        fi
        OUTPUT_DIR="$2"
        shift 2
        ;;
      --include-public-ip)
        INCLUDE_PUBLIC_IP=1
        shift
        ;;
      --include-network-probe)
        INCLUDE_NETWORK_PROBE=1
        INCLUDE_PUBLIC_IP=1
        shift
        ;;
      --no-mask)
        MASK_SENSITIVE=0
        shift
        ;;
      --interactive)
        INTERACTIVE=1
        shift
        ;;
      --version)
        printf '%s\n' "$SCRIPT_VERSION"
        exit 0
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log "未知参数：$1"
        usage
        exit 2
        ;;
    esac
  done
}

interactive_config() {
  local input=""

  if [ -z "$SERVER_ID" ]; then
    read -r -p "服务器编号，例如 node01：" input || true
    SERVER_ID="$input"
  fi

  read -r -p "报告输出目录 [${OUTPUT_DIR}]：" input || true
  OUTPUT_DIR="${input:-$OUTPUT_DIR}"

  if ask_yes_no "是否采集公网出口 IP？默认会脱敏 [y/N]：" "n"; then
    INCLUDE_PUBLIC_IP=1
  fi

  if ask_yes_no "是否执行轻量外部网络探测？包含 ping/DNS [y/N]：" "n"; then
    INCLUDE_NETWORK_PROBE=1
    INCLUDE_PUBLIC_IP=1
  fi

  if ask_yes_no "是否关闭脱敏？仅限报告不进公开仓库时使用 [y/N]：" "n"; then
    MASK_SENSITIVE=0
  fi
}

sanitize_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

redact_stream() {
  if [ "$MASK_SENSITIVE" -eq 0 ]; then
    cat
    return
  fi

  # main() 已保证开启脱敏时 perl 必然存在；不提供弱化的 sed 降级，
  # 避免将来逻辑变动时静默降级成"看起来脱敏了、实际没脱干净"。
  perl -pe '
      s#\b([a-z][a-z0-9+.-]*://)(?:[^/\s:@]+(?::[^/\s@]*)?|:[^/\s@]+)@#${1}[redacted-credential]@#ig;
      s/\b((?:authorization)\s*:\s*(?:bearer|basic)\s+)["\x27]?[^\s"\x27&;]+/${1}[redacted]/ig;
      s/\b((?:set-cookie|cookie)\s*:\s*)[^\r\n]+/${1}[redacted]/ig;
      s/\b((?:password|passwd|token|secret|auth[_-]?key|access[_-]?key|secret[_-]?key|private[_-]?key|client[_-]?secret|cookie)\s*[=:]\s*)["\x27]?[^\s"\x27&;]+["\x27]?/${1}[redacted]/ig;
      s/(^|[\s"\x27])(--(?:password|passwd|token|secret|auth-key|access-key|secret-key|private-key|client-secret|cookie)(?:=|\s+))["\x27]?[^\s"\x27&;]+/${1}${2}[redacted]/ig;
      s/\b([0-9a-f]{2}:){5}[0-9a-f]{2}\b/[redacted-mac]/ig;
      s/\b(Machine ID:\s*)[0-9a-f-]+\b/$1[redacted]/ig;
      s/\b(Boot ID:\s*)[0-9a-f-]+\b/$1[redacted]/ig;
      s/(?<![\w:])(?=[0-9a-f:]*::)(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}(?![\w:])/[redacted-ipv6]/ig;
      s/(?<![\w:])(?:[0-9a-f]{1,4}:){3,7}[0-9a-f]{1,4}(?![\w:])/[redacted-ipv6]/ig;
      s/\b(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\b/
        my ($a,$b,$c,$d)=($1,$2,$3,$4);
        if ($a > 255 || $b > 255 || $c > 255 || $d > 255) {
          "$a.$b.$c.$d";
        } elsif ($a == 10 || $a == 127 || $a == 0 || $a >= 224 ||
                 ($a == 172 && $b >= 16 && $b <= 31) ||
                 ($a == 192 && $b == 168) ||
                 ($a == 169 && $b == 254) ||
                 ($a == 100 && $b >= 64 && $b <= 127)) {
          "$a.$b.$c.$d";
        } else {
          "$a.$b.*.*";
        }
      /gex;
    '
}

append() {
  printf '%s\n' "$*" >> "$REPORT_FILE"
}

blank() {
  printf '\n' >> "$REPORT_FILE"
}

section() {
  blank
  append "## $1"
  blank
}

subsection() {
  blank
  append "### $1"
  blank
}

code_start() {
  append '```text'
}

code_end() {
  append '```'
  blank
}

# 带超时地执行单条采集命令。没有 timeout 命令时直接执行（脚本仍可用，只是失去防挂起保护）。
run_with_timeout() {
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$CMD_TIMEOUT" bash -c "$1"
  else
    bash -c "$1"
  fi
}

run_cmd() {
  local title="$1"
  local cmd="$2"
  local status=0
  subsection "$title"
  append "命令：\`$cmd\`"
  blank
  code_start
  run_with_timeout "$cmd" 2>&1 | redact_stream >> "$REPORT_FILE"
  status=${PIPESTATUS[0]}
  code_end
  if [ "$status" -eq 124 ] && [ -n "$TIMEOUT_BIN" ]; then
    append "> 命令超过 ${CMD_TIMEOUT}s 被终止（退出码 124），采集继续。"
    blank
  elif [ "$status" -ne 0 ]; then
    append "> 命令退出码：$status"
    blank
  fi
}

run_if_command() {
  local command_name="$1"
  local title="$2"
  local cmd="$3"
  if command -v "$command_name" >/dev/null 2>&1; then
    run_cmd "$title" "$cmd"
  else
    subsection "$title"
    append "未安装或不可用：\`$command_name\`。"
    blank
  fi
}

run_file() {
  local title="$1"
  local path="$2"
  subsection "$title"
  if [ -r "$path" ]; then
    append "文件：\`$path\`"
    blank
    code_start
    sed -n '1,220p' "$path" 2>&1 | redact_stream >> "$REPORT_FILE"
    code_end
  else
    append "文件不存在或不可读：\`$path\`。"
    blank
  fi
}

safe_ls() {
  local title="$1"
  shift
  subsection "$title"
  code_start
  for path in "$@"; do
    if [ -e "$path" ]; then
      ls -ld "$path" 2>&1
    else
      printf 'missing: %s\n' "$path"
    fi
  done | redact_stream >> "$REPORT_FILE"
  code_end
}

write_header() {
  local host="${1:-unknown}"
  append "# Linux 服务器基础信息采集报告"
  blank
  append "| 项目 | 值 |"
  append "| --- | --- |"
  append "| 服务器编号 | \`${SERVER_ID}\` |"
  append "| 主机名 | \`${host}\` |"
  append "| 脚本版本 | \`${SCRIPT_VERSION}\` |"
  append "| 本地采集时间 | \`$(date '+%Y-%m-%d %H:%M:%S %Z %z' 2>/dev/null)\` |"
  append "| UTC 采集时间 | \`$(date -u '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null)\` |"
  append "| 执行用户 | \`$(id 2>/dev/null | redact_stream)\` |"
  append "| Root 权限 | \`$([ "$IS_ROOT" -eq 1 ] && printf 'yes' || printf 'no')\` |"
  append "| 脱敏 | \`$([ "$MASK_SENSITIVE" -eq 1 ] && printf 'enabled' || printf 'disabled')\` |"
  append "| 公网 IP 采集 | \`$([ "$INCLUDE_PUBLIC_IP" -eq 1 ] && printf 'enabled' || printf 'disabled')\` |"
  append "| 外部网络探测 | \`$([ "$INCLUDE_NETWORK_PROBE" -eq 1 ] && printf 'enabled' || printf 'disabled')\` |"
  blank
  append "> 本报告由只读脚本生成。默认脱敏公网 IP、IPv6、MAC、Machine ID 和 URL 内嵌凭据；不会读取 SSH 私钥、token、cookie 或证书私钥。"
  if [ "$IS_ROOT" -ne 1 ]; then
    append "> 当前不是 root 权限，防火墙、NFS、Docker、部分 systemd 和日志信息可能采集不完整。"
  fi
  blank
}

collect_meta_and_system() {
  section "1. 系统基础信息"
  run_cmd "系统版本" "if [ -r /etc/os-release ]; then sed -n '1,120p' /etc/os-release; else echo '/etc/os-release not found'; fi"
  run_cmd "内核版本" "uname -a"
  run_if_command hostnamectl "主机信息" "hostnamectl"
  run_if_command timedatectl "时间同步状态" "timedatectl"
  run_cmd "运行时间" "uptime; who -b 2>/dev/null || true"
  run_if_command systemd-detect-virt "虚拟化检测" "systemd-detect-virt -v || true"
}

collect_cpu() {
  section "2. CPU 信息"
  run_if_command lscpu "CPU 拓扑" "lscpu"
  run_cmd "CPU 核心数" "nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || true"
  run_cmd "CPU 漏洞缓解状态" 'if [ -d /sys/devices/system/cpu/vulnerabilities ]; then for f in /sys/devices/system/cpu/vulnerabilities/*; do printf "%s: " "$(basename "$f")"; sed -n "1p" "$f"; done; else echo "no vulnerabilities directory"; fi'
}

collect_memory() {
  section "3. 内存与 Swap"
  run_if_command free "内存摘要" "free -h"
  run_if_command swapon "Swap 状态" "swapon --show --bytes; echo; swapon --show"
  run_cmd "关键 meminfo 字段" "grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree|Dirty|Writeback):' /proc/meminfo 2>/dev/null || true"
}

collect_disk() {
  section "4. 磁盘、文件系统与挂载"
  run_if_command lsblk "块设备与文件系统" "lsblk -o NAME,KNAME,TYPE,FSTYPE,FSVER,LABEL,UUID,SIZE,FSAVAIL,FSUSE%,MOUNTPOINTS"
  run_if_command df "文件系统容量" "df -hT"
  run_if_command df "inode 使用情况" "df -ih"
  run_if_command findmnt "当前挂载参数" "findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS"
  run_if_command lsblk "Discard/TRIM 支持" "lsblk --discard"
  run_file "fstab 非注释内容" "/etc/fstab"
  safe_ls "常见数据与挂载目录" "/opt" "/srv" "/data" "/mnt"
}

collect_network() {
  section "5. 网络基础信息"
  run_if_command ip "网卡地址摘要" "ip -br addr"
  run_if_command ip "路由表" "ip route show table main; echo; ip -6 route show table main 2>/dev/null || true"
  run_cmd "DNS 配置" "resolvectl status 2>/dev/null || sed -n '1,120p' /etc/resolv.conf 2>/dev/null || true"
  run_if_command ss "监听端口" "ss -tulpen"
  run_if_command ss "Socket 摘要" "ss -s"
  run_if_command iptables "iptables IPv4 规则" "iptables -S; echo; iptables -L -n -v --line-numbers"
  run_if_command ip6tables "ip6tables IPv6 规则" "ip6tables -S; echo; ip6tables -L -n -v --line-numbers"
  run_if_command nft "nftables 规则摘要" "nft list ruleset"
  run_if_command ufw "UFW 状态" "ufw status verbose"

  if [ "$INCLUDE_PUBLIC_IP" -eq 1 ]; then
    run_if_command curl "公网出口 IP" "printf 'api.ipify.org: '; curl -fsS --max-time 5 https://api.ipify.org || true; echo; printf 'ifconfig.me: '; curl -fsS --max-time 5 https://ifconfig.me/ip || true; echo"
  else
    subsection "公网出口 IP"
    append "默认跳过。需要时使用 \`--include-public-ip\`；默认仍会脱敏公网 IP。"
    blank
  fi

  if [ "$INCLUDE_NETWORK_PROBE" -eq 1 ]; then
    run_if_command getent "DNS 解析探测" "getent hosts debian.org cloudflare.com google.com || true"
    run_if_command ping "轻量 ping 探测" "ping -c 4 -W 3 1.1.1.1; echo; ping -c 4 -W 3 8.8.8.8"
  else
    subsection "外部网络探测"
    append "默认跳过。网络质量、回程、流媒体和黑名单建议使用 NodeQuality / Check.Place 专项报告补充。"
    blank
  fi
}

collect_security() {
  section "6. 安全与访问基线"
  run_cmd "SSH 服务状态" "systemctl status ssh --no-pager 2>/dev/null || systemctl status sshd --no-pager 2>/dev/null || echo 'ssh/sshd service not found'"
  run_if_command sshd "sshd 生效配置摘要" "sshd -T 2>/dev/null | grep -Ei '^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|permitemptypasswords|authorizedkeysfile|allowusers|allowgroups|x11forwarding|clientaliveinterval|clientalivecountmax|maxauthtries|maxsessions|loglevel|tcpkeepalive)\\b' || true"
  run_cmd "SSH 配置文件中的关键项" 'for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do [ -r "$f" ] || continue; echo "# $f"; grep -Ei "^\s*(Port|PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|PubkeyAuthentication|PermitEmptyPasswords|AuthorizedKeysFile|AllowUsers|AllowGroups|X11Forwarding|ClientAliveInterval|ClientAliveCountMax|MaxAuthTries|MaxSessions|LogLevel|TCPKeepAlive)\b" "$f" || true; echo; done'
  run_cmd "root 与普通用户摘要" 'while IFS=: read -r user _ uid gid _ home shell; do if [ "$uid" -eq 0 ] || [ "$uid" -ge 1000 ]; then printf "%s:uid=%s:gid=%s:home=%s:shell=%s\n" "$user" "$uid" "$gid" "$home" "$shell"; fi; done < /etc/passwd'
  run_cmd "管理用户组信息" 'for user in $(awk -F: "\$3 >= 1000 {print \$1}" /etc/passwd); do echo "# $user"; id "$user" 2>/dev/null || true; done; echo; echo "# sudo 组成员"; getent group sudo 2>/dev/null || true; echo; echo "# docker 组成员"; getent group docker 2>/dev/null || true'
  run_cmd "sudoers 文件列表" "ls -l /etc/sudoers /etc/sudoers.d 2>/dev/null || true"
  run_cmd "SSH authorized_keys 文件权限" "find /root/.ssh /home -maxdepth 3 -type f -name authorized_keys -printf '%M %u %g %s %p\\n' 2>/dev/null || true"
  run_cmd "fail2ban 状态" "systemctl status fail2ban --no-pager 2>/dev/null || true; echo; fail2ban-client status 2>/dev/null || true"
  run_cmd "fail2ban sshd jail 详细状态" "fail2ban-client status sshd 2>/dev/null || echo 'fail2ban or sshd jail not available'"
  run_cmd "IPv6 禁用状态" "sysctl net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6 net.ipv6.conf.lo.disable_ipv6 2>/dev/null || true; echo; ss -tulpen -6 2>/dev/null || true"
  run_cmd "sysctl 生产基线参数" "sysctl net.core.somaxconn fs.file-max vm.swappiness net.ipv4.tcp_congestion_control net.netfilter.nf_conntrack_max net.ipv4.tcp_max_syn_backlog vm.dirty_ratio vm.dirty_background_ratio fs.inotify.max_user_watches 2>/dev/null || true"
}

collect_packages() {
  section "7. 包管理与更新状态"
  run_cmd "APT 源摘要" 'for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do [ -r "$f" ] || continue; echo "# $f"; sed -n "1,160p" "$f" | sed "/^[[:space:]]*#/d;/^[[:space:]]*$/d"; echo; done'
  run_if_command apt "可更新包摘要" "apt list --upgradable 2>/dev/null | sed -n '1,120p'"
  run_if_command dpkg "关键软件包状态" "dpkg -l | grep -E '^(ii)\\s+(linux-image|openssh-server|docker|docker-ce|docker-ce-cli|containerd|nfs-common|nfs-kernel-server|netdata|prometheus|grafana|fail2ban|unattended-upgrades|chrony|iptables|nftables)' || true"
  run_cmd "unattended-upgrades 状态" "systemctl status unattended-upgrades --no-pager 2>/dev/null || true; echo; systemctl list-timers 'apt*' --no-pager 2>/dev/null || true; echo; test -f /var/run/reboot-required && cat /var/run/reboot-required || echo 'no /var/run/reboot-required'"
  run_cmd "unattended-upgrades 配置文件" "test -r /etc/apt/apt.conf.d/51unattended-upgrades-security-only && cat /etc/apt/apt.conf.d/51unattended-upgrades-security-only || echo '/etc/apt/apt.conf.d/51unattended-upgrades-security-only not found'"
}

collect_services() {
  section "8. 运行服务、进程与异常状态"
  run_if_command systemctl "失败服务" "systemctl --failed --no-pager"
  run_if_command systemctl "运行中的 systemd 服务" "systemctl list-units --type=service --state=running --no-pager --plain"
  run_cmd "资源占用 Top 进程" "ps -eo pid,user,comm,%cpu,%mem,rss,args --sort=-%mem | sed -n '1,30p'; echo; ps -eo pid,user,comm,%cpu,%mem,rss,args --sort=-%cpu | sed -n '1,30p'"
}

collect_docker() {
  section "9. Docker 状态"
  if ! command -v docker >/dev/null 2>&1; then
    append "Docker 未安装或 \`docker\` 命令不可用。"
    blank
    return
  fi

  run_cmd "Docker 版本" "docker version"
  run_cmd "Docker 系统信息摘要" "docker info 2>/dev/null | grep -Ei '^( Server Version| Storage Driver| Docker Root Dir| Logging Driver| Cgroup Driver| Cgroup Version| Kernel Version| Operating System| OSType| Architecture| CPUs| Total Memory| Live Restore Enabled| Default Runtime| Runtimes| Swarm| Security Options| Registry)' || docker info"
  run_cmd "Docker daemon.json 配置" "test -r /etc/docker/daemon.json && cat /etc/docker/daemon.json || echo '/etc/docker/daemon.json not found'"
  run_cmd "Docker 服务状态" "systemctl status docker --no-pager 2>/dev/null || true"
  run_cmd "容器列表" "docker ps -a --format 'table {{.Names}}\\t{{.Image}}\\t{{.Status}}\\t{{.Ports}}'"
  run_cmd "Docker 网络" 'docker network ls; echo; networks=$(docker network ls -q); if [ -n "$networks" ]; then docker network inspect $networks --format "{{.Name}} {{range .Containers}}{{.Name}} {{end}}" 2>/dev/null || true; fi'
  run_cmd "Docker volume 列表" "docker volume ls"
  run_cmd "容器 publish 端口检查" "docker ps --format 'table {{.Names}}\\t{{.Ports}}'"
  run_cmd "Docker socket 挂载检查" 'ids=$(docker ps -q); if [ -z "$ids" ]; then echo "no running containers"; else docker inspect $ids --format "{{.Name}} {{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}" | grep -F "/var/run/docker.sock" || echo "no docker.sock mount found"; fi'
}

collect_nfs() {
  section "10. NFS 状态"
  run_if_command dpkg "NFS 软件包" "dpkg -l | grep -E '^(ii)\\s+(nfs-common|nfs-kernel-server)' || true"
  run_cmd "NFS Server 服务状态" "systemctl status nfs-server --no-pager 2>/dev/null || true"
  run_if_command exportfs "NFS export" "exportfs -v"
  run_cmd "NFSv4 版本状态" "if [ -r /proc/fs/nfsd/versions ]; then cat /proc/fs/nfsd/versions; else echo '/proc/fs/nfsd/versions not found'; fi"
  run_if_command findmnt "当前 NFS 挂载" "findmnt -t nfs,nfs4"
  run_cmd "NFS/RPC 监听端口" "ss -tulpen 2>/dev/null | grep -Ei 'nfs|rpc|2049|111' || true"
  run_if_command rpcinfo "RPC 注册表" "rpcinfo -p"
}

collect_monitoring() {
  section "11. 监控组件状态"
  run_cmd "常见监控服务状态" 'for svc in netdata prometheus grafana-server node_exporter uptime-kuma; do echo "# $svc"; systemctl is-enabled "$svc" 2>/dev/null || true; systemctl is-active "$svc" 2>/dev/null || true; systemctl status "$svc" --no-pager 2>/dev/null | sed -n "1,18p" || true; echo; done'
  run_cmd "常见监控端口监听" "ss -tulpen 2>/dev/null | grep -E '(:3000|:3001|:9090|:9100|:19999|:9093|:9115)' || true"
  if command -v docker >/dev/null 2>&1; then
    run_cmd "监控相关容器" "docker ps -a --format 'table {{.Names}}\\t{{.Image}}\\t{{.Status}}\\t{{.Ports}}' | grep -Ei 'uptime|kuma|netdata|prometheus|grafana|exporter|alertmanager' || true"
  fi
}

collect_logs() {
  section "12. 日志与异常摘要"
  run_if_command journalctl "journald 磁盘使用" "journalctl --disk-usage"
  run_cmd "journald 配置" "test -r /etc/systemd/journald.conf.d/99-server-baseline.conf && cat /etc/systemd/journald.conf.d/99-server-baseline.conf || echo '/etc/systemd/journald.conf.d/99-server-baseline.conf not found'"
  run_if_command systemctl "fstrim 定时器状态" "systemctl list-timers fstrim.timer --no-pager"
  run_if_command journalctl "最近错误日志" "journalctl -p err -n 80 --no-pager"
  run_if_command journalctl "内核警告和错误" "journalctl -k -p warning -n 80 --no-pager"
  run_if_command journalctl "关键异常关键词" "journalctl --since '7 days ago' --no-pager 2>/dev/null | grep -Ei 'oom|out of memory|i/o error|stale file handle|nfs|no space left|read-only file system|segfault|failed password|authentication failure' | sed -n '1,160p' || true"
  run_if_command last "重启记录" "last -x reboot shutdown | sed -n '1,20p'"
}

collect_summary() {
  section "13. 人工复核清单"
  append "- [ ] 系统版本、内核、虚拟化类型与供应商面板一致。"
  append "- [ ] CPU、内存、swap 与预期一致；如无 swap，应按需配置或记录原因。"
  append "- [ ] 根盘、数据盘和各挂载点符合当前服务器角色。"
  append "- [ ] DNS、默认路由、监听端口和防火墙规则符合规划。"
  append "- [ ] SSH 仅开放预期端口和认证方式；没有未知用户、未知 authorized_keys 或未知 sudoers。"
  append "- [ ] 如安装 Docker，应确认普通业务容器不随意 publish 公网端口，公网入口经反向代理统一收敛。"
  append "- [ ] 按规划不应运行 Docker 的节点，如发现 Docker，应单独评估原因。"
  append "- [ ] NFS 只在受信内网开放，依赖远端存储的应用启动前必须检查挂载。"
  append "- [ ] 监控、备份、日志轮转和 failed services 需要同步登记到 SOP 或服务器记录。"
  blank
}

main() {
  parse_args "$@"

  if [ "$INTERACTIVE" -eq 1 ]; then
    interactive_config
  fi

  if [ -z "$SERVER_ID" ]; then
    log "错误：必须提供 --server-id，或使用 --interactive。"
    usage
    exit 2
  fi

  if [ -z "$OUTPUT_DIR" ]; then
    log "错误：--output-dir 不能为空。"
    exit 2
  fi

  if [ "$(id -u 2>/dev/null || printf '1')" = "0" ]; then
    IS_ROOT=1
  fi

  if [ "$MASK_SENSITIVE" -eq 0 ]; then
    log "警告：已关闭脱敏。请只把报告保存在私有位置，不要提交到公开仓库。"
  elif ! command -v perl >/dev/null 2>&1; then
    log "错误：默认脱敏需要 perl，但当前系统未找到 perl。"
    log "请安装 perl 后重试；或确认报告只保存在私有位置后使用 --no-mask。"
    exit 1
  fi

  case "$CMD_TIMEOUT" in
    ''|*[!0-9]*)
      log "错误：COLLECT_CMD_TIMEOUT 必须是正整数秒数，当前值：$CMD_TIMEOUT"
      exit 2
      ;;
  esac
  if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN="$(command -v timeout)"
  else
    log "警告：未找到 timeout 命令，单条命令超时保护不可用；个别命令挂起会阻塞采集。"
  fi

  case "$(uname -s 2>/dev/null || printf 'unknown')" in
    Linux*) ;;
    *) log "警告：当前系统看起来不是 Linux，采集结果可能只适合作为脚本语法或用法测试。" ;;
  esac

  if ! mkdir -p "$OUTPUT_DIR" 2>/dev/null; then
    log "错误：无法创建输出目录：$OUTPUT_DIR"
    exit 1
  fi

  local host="unknown"
  host="$(hostname 2>/dev/null || printf 'unknown')"
  local safe_host safe_id timestamp
  safe_host="$(sanitize_name "$host")"
  safe_id="$(sanitize_name "$SERVER_ID")"
  timestamp="$(date '+%Y-%m-%d_%H%M%S' 2>/dev/null || date -u '+%Y-%m-%d_%H%M%S')"
  REPORT_FILE="${OUTPUT_DIR%/}/server-info-${safe_id}-${safe_host}-${timestamp}.md"

  : > "$REPORT_FILE" || {
    log "错误：无法写入报告文件：$REPORT_FILE"
    exit 1
  }
  chmod 600 "$REPORT_FILE" 2>/dev/null || true

  write_header "$host"
  collect_meta_and_system
  collect_cpu
  collect_memory
  collect_disk
  collect_network
  collect_security
  collect_packages
  collect_services
  collect_docker
  collect_nfs
  collect_monitoring
  collect_logs
  collect_summary

  log "采集完成：$REPORT_FILE"
}

main "$@"
