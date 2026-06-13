#!/usr/bin/env bash
# shellcheck disable=SC2016

# Debian 12 production baseline bootstrap script.
# This script is intentionally conservative: it asks before risky changes in
# interactive mode, backs up managed files, and stops on the first error.

set -Eeuo pipefail

SCRIPT_VERSION="v1.1"
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

# 当前正在执行的阶段名称，由 phase_start 维护，trap ERR 时一并打印，
# 让脚本中途 die 时用户能立刻定位到出错的模块。
CURRENT_PHASE="initializing"

ASSUME_YES=0
DRY_RUN=0
INTERACTIVE=1

SERVER_ID=""
TARGET_HOSTNAME=""
ROLE=""
ADMIN_USER="admin"
ADMIN_SSH_PUBKEY=""
ADMIN_IP=""
SSH_PORT="2222"
MAX_SESSIONS="10"

CONFIGURE_TIMEZONE=""
TIMEZONE="Asia/Shanghai"
RUN_APT_UPDATE=""
RUN_APT_UPGRADE=""
INSTALL_BASIC_PACKAGES=""
CONFIGURE_SECURITY_UPDATES=""
REBOOT_IF_REQUIRED=""

CREATE_ADMIN_USER=""
CONFIGURE_ADMIN_KEY=""
CONFIGURE_SSH=""
KEEP_ROOT_KEY_LOGIN=""
DISABLE_SSH_PASSWORD=""
RESTRICT_ALLOW_USERS=""
SSH_ADDRESS_FAMILY_INET=""

CONFIGURE_FIREWALL=""
RESTRICT_SSH_SOURCE=""
OPEN_HTTP=""
OPEN_HTTPS=""
EXTRA_TCP_PORTS=""
LOCKDOWN_FIREWALL=""
DISABLE_IPV6=""
ALLOW_TAILSCALE=""

CONFIGURE_FAIL2BAN=""
FAIL2BAN_BANTIME="1h"
FAIL2BAN_FINDTIME="10m"
FAIL2BAN_MAXRETRY="5"

CONFIGURE_SWAP=""
SWAP_SIZE=""
CONFIGURE_LIMITS=""
CONFIGURE_SYSCTL=""
CONFIGURE_CONNTRACK=""
ENABLE_BBR=""
ENABLE_FSTRIM=""
CONFIGURE_JOURNALD=""

INSTALL_DOCKER=""
ADD_ADMIN_TO_DOCKER=""
CONFIGURE_DOCKER_LOGS=""
CREATE_DOCKER_NETWORKS=""

RUN_ACCEPTANCE=""
GENERATE_REPORT=""
REPORT_DIR="/root"
RUN_COLLECT_INFO=""
COLLECT_SCRIPT_URL=""

BACKUP_DIR=""
TIMESTAMP=""

BASIC_PACKAGES=(
  sudo curl wget git vim nano jq htop rsync ca-certificates gnupg lsb-release
  unzip zip tar lsof net-tools dnsutils tcpdump
  iotop iftop nload ncdu
  iptables iptables-persistent netfilter-persistent fail2ban chrony
  unattended-upgrades apt-listchanges
)

usage() {
  cat <<'EOF'
用法：
  init-debian12-production-baseline.sh
  init-debian12-production-baseline.sh --server-id node01 --hostname node01 --admin-ip 203.0.113.10 --install-docker yes
  init-debian12-production-baseline.sh --server-id node01 --hostname node01 --admin-ip 203.0.113.10 --install-docker yes --yes

默认行为：
  - 不带 --yes 时进入交互式向导，已传参数会作为默认值。
  - 带 --yes 时按参数和角色默认值非交互执行。
  - 带 --dry-run 时只展示将执行的动作，不修改系统。

核心参数：
  --server-id <id>                 服务器编号，例如 node01。
  --hostname <name>                主机名，例如 node01。
  --role <role>                    角色：lightweight-docker-test、docker-app-node、storage-nfs-node、basic-secure-server。
  --admin-user <user>              管理用户，默认 admin。
  --admin-ssh-pubkey <key>         管理用户 SSH 公钥。不要传私钥。
  --admin-ip <ip/cidr[,...]>       允许访问 SSH 的管理来源 IP，可逗号分隔多个，例如 203.0.113.10 或 203.0.113.10/32,198.51.100.20。
  --ssh-port <port>                SSH 端口，默认 2222。
  --keep-root-key-login yes|no     是否保留 root 的 SSH key 登录（prohibit-password）。默认按角色推荐 yes。
  --disable-ssh-password yes|no    是否禁用 SSH 密码登录（含键盘交互）。默认按角色推荐 yes。
  --swap-size <size>               swap 大小，例如 2G、512M。

模块开关：
  --install-docker yes|no          是否安装 Docker Engine。
  --create-docker-networks yes|no  是否创建 nginx-network 和 backend-network。
  --disable-ipv6 yes|no            是否禁用 IPv6，默认按角色推荐。
  --enable-bbr yes|no              是否启用 BBR。
  --lockdown-firewall yes|no       是否最终设置 INPUT DROP。
  --open-http yes|no               是否开放 80/tcp。
  --open-https yes|no              是否开放 443/tcp。
  --extra-tcp-ports <ports>        额外开放 TCP 端口，逗号分隔，例如 8080,8443。
  --allow-tailscale yes|no         是否在防火墙中放行 tailscale0 网卡。不会安装 Tailscale。
  --run-collect-info yes|no        是否在最后下载并运行采集脚本。需要同时提供 --collect-script-url。
  --collect-script-url <url>       collect-server-info.sh 的 raw URL。

执行控制：
  --dry-run                        只打印动作，不执行修改。
  --yes                            非交互执行。仅在你确认控制台/SSH 应急入口可用时使用。
  --non-interactive                不询问，但没有 --yes 时仍会在最终确认处停止。
  -h, --help                       显示帮助。

安全边界：
  - 只支持 Debian 12。
  - 所有托管配置写入前备份到 /root/server-init-backup-<timestamp>/。
  - SSH 和防火墙是高风险模块；交互模式会要求明确确认。
  - 关闭密码登录时，脚本会校验至少保留一条 key 登录通道（admin 公钥或 root key 登录），否则拒绝执行，避免锁死。
  - 防火墙模块对 INPUT 链是权威式管理：每次执行都会 flush 并按脚本模型重建 INPUT，手工添加的 INPUT 规则会被清掉。
  - IPv6 入站默认不开放任何服务端口（仅放行 lo 与 ESTABLISHED，收紧后 v6 INPUT DROP）；如需 IPv6 对外服务请自行扩展。
  - 不保存密码、token、cookie、私钥或证书私钥。
EOF
}

log() {
  printf '%s\n' "$*" >&2
}

info() {
  log "[INFO] $*"
}

warn() {
  log "[WARN] $*"
}

die() {
  log "[ERROR] $*"
  if [ -n "${CURRENT_PHASE:-}" ] && [ "$CURRENT_PHASE" != "initializing" ]; then
    log "[ERROR] 中断阶段：$CURRENT_PHASE"
  fi
  if [ -n "${BACKUP_DIR:-}" ] && [ -d "$BACKUP_DIR" ]; then
    log "[ERROR] 备份目录：$BACKUP_DIR"
  fi
  exit 1
}

# 标记当前阶段，trap ERR 会用到。把模块边界显式化，方便排障。
phase_start() {
  CURRENT_PHASE="$1"
  info "==> 阶段：$CURRENT_PHASE"
}

# trap ERR 处理器：脚本中途 die 时打印失败行、退出码、当前阶段、备份目录，
# 并提示后续如何接管（人工继续、回滚或重跑）。
on_error() {
  local exit_code=$?
  local failed_line="${BASH_LINENO[0]:-unknown}"
  local failed_command="${BASH_COMMAND:-unknown}"
  log ""
  log "============================================================"
  log "[ERROR] 脚本在阶段 '$CURRENT_PHASE' 中断"
  log "[ERROR] 失败行号：$failed_line"
  log "[ERROR] 失败命令：$failed_command"
  log "[ERROR] 退出码：  $exit_code"
  if [ -n "${BACKUP_DIR:-}" ] && [ -d "$BACKUP_DIR" ]; then
    log "[ERROR] 备份目录：$BACKUP_DIR"
    log "[ERROR] 已修改的文件原始内容保存在该目录下，可用于人工回滚。"
  fi
  log ""
  log "建议处理顺序："
  log "  1. 不要关闭当前 SSH 会话；如果是 SSH/防火墙阶段失败，立刻新开一个会话验证可登录。"
  log "  2. 检查上面的失败命令和阶段，定位问题（apt 网络、磁盘空间、权限等）。"
  log "  3. 如果已经过了 firewall_open_ports 但 firewall_lockdown 之前失败，"
  log "     iptables 此时是 INPUT ACCEPT，端口已放行但未收紧，处于安全过渡状态。"
  log "  4. 修复问题后可重新执行脚本（多数模块写了幂等保护），或手动按 SOP 接管剩余步骤。"
  log "============================================================"
  exit "$exit_code"
}

trap on_error ERR

is_yes() {
  case "${1:-}" in
    y|Y|yes|YES|Yes|true|TRUE|1|是) return 0 ;;
    *) return 1 ;;
  esac
}

is_no() {
  case "${1:-}" in
    n|N|no|NO|No|false|FALSE|0|否) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_yes_no() {
  local value="${1:-}"
  if is_yes "$value"; then
    printf 'yes'
  elif is_no "$value"; then
    printf 'no'
  else
    die "布尔参数只能是 yes 或 no，当前值：$value"
  fi
}

set_bool_var() {
  local name="$1"
  local value="$2"
  printf -v "$name" '%s' "$(normalize_yes_no "$value")"
}

validate_role() {
  case "${1:-}" in
    lightweight-docker-test|docker-app-node|storage-nfs-node|basic-secure-server) return 0 ;;
    *) die "未知服务器角色：${1:-空}。允许值：lightweight-docker-test、docker-app-node、storage-nfs-node、basic-secure-server。" ;;
  esac
}

validate_port() {
  local value="$1"
  case "$value" in
    ''|*[!0-9]*) die "端口必须是数字：$value" ;;
  esac
  if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
    die "端口必须在 1-65535 范围内：$value"
  fi
}

# 校验单个 IPv4 octet 是否在 0-255
validate_ipv4_octets() {
  local ip="$1"
  local IFS='.'
  # shellcheck disable=SC2206
  local parts=($ip)
  if [ "${#parts[@]}" -ne 4 ]; then
    return 1
  fi
  local p
  for p in "${parts[@]}"; do
    case "$p" in
      ''|*[!0-9]*) return 1 ;;
    esac
    if [ "$p" -lt 0 ] || [ "$p" -gt 255 ]; then
      return 1
    fi
  done
  return 0
}

# 校验 IPv4 或 IPv4/CIDR：octet 0-255、CIDR 0-32
validate_ipv4_or_cidr() {
  local value="$1"
  local label="${2:-IPv4/CIDR}"
  if [ -z "$value" ]; then
    die "$label 不能为空。"
  fi
  local ip="$value"
  local cidr=""
  case "$value" in
    */*)
      ip="${value%%/*}"
      cidr="${value##*/}"
      ;;
  esac
  if ! validate_ipv4_octets "$ip"; then
    die "$label 不是合法的 IPv4 地址：$value"
  fi
  if [ -n "$cidr" ]; then
    case "$cidr" in
      ''|*[!0-9]*) die "$label 的 CIDR 必须是数字：$value" ;;
    esac
    if [ "$cidr" -lt 0 ] || [ "$cidr" -gt 32 ]; then
      die "$label 的 CIDR 必须在 0-32 范围内：$value"
    fi
  fi
}

# 校验逗号分隔的端口列表（不修改 IFS，只用参数展开）
validate_extra_tcp_ports() {
  local list="$1"
  if [ -z "$list" ]; then
    return 0
  fi
  local rest="$list"
  local item
  while [ -n "$rest" ]; do
    case "$rest" in
      *,*) item="${rest%%,*}"; rest="${rest#*,}" ;;
      *)   item="$rest"; rest="" ;;
    esac
    # 去掉首尾空白
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    if [ -n "$item" ]; then
      validate_port "$item"
    fi
  done
}

# 校验逗号分隔的管理来源 IP/CIDR 列表，逐个复用 validate_ipv4_or_cidr
validate_admin_ips() {
  local list="$1"
  local label="${2:-IPv4/CIDR}"
  local rest="$list"
  local item
  while [ -n "$rest" ]; do
    case "$rest" in
      *,*) item="${rest%%,*}"; rest="${rest#*,}" ;;
      *)   item="$rest"; rest="" ;;
    esac
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    if [ -n "$item" ]; then
      validate_ipv4_or_cidr "$item" "$label"
    fi
  done
}

# 校验 swap 大小格式：数字 + 可选单个 K/M/G 后缀，示例 512M、2G
validate_swap_size() {
  local value="$1"
  if ! [[ "$value" =~ ^[1-9][0-9]*[KMGkmg]?$ ]]; then
    die "swap 大小格式无效：$value（示例：512M、2G）"
  fi
}

# 校验管理用户 SSH 公钥：拒绝误传私钥，非公钥形态仅告警
validate_admin_pubkey() {
  local key="$1"
  case "$key" in
    *"PRIVATE KEY"*)
      die "--admin-ssh-pubkey 看起来是私钥，拒绝写入。请只传 SSH 公钥（如 ssh-ed25519 ...）。"
      ;;
  esac
  if ! printf '%s' "$key" | grep -qE '(ssh-(rsa|ed25519|dss)|ecdsa-sha2|sk-(ssh|ecdsa))'; then
    warn "--admin-ssh-pubkey 不像常见的 SSH 公钥格式，请确认无误（仍将按原样写入）。"
  fi
}

# 防锁死兜底：关闭密码登录时，必须至少保留一条可用的 key 登录通道
check_login_path_safety() {
  if ! is_yes "$CONFIGURE_SSH" || ! is_yes "$DISABLE_SSH_PASSWORD"; then
    return
  fi

  local admin_key_ok=0
  if is_yes "$CREATE_ADMIN_USER" && is_yes "$CONFIGURE_ADMIN_KEY" && [ -n "$ADMIN_SSH_PUBKEY" ]; then
    admin_key_ok=1
  fi

  local root_key_ok=0
  if is_yes "$KEEP_ROOT_KEY_LOGIN"; then
    if [ "$DRY_RUN" -eq 1 ]; then
      # dry-run 可能非 root / 非目标机，读不到 /root，宽松放行并提醒，避免误杀
      root_key_ok=1
      warn "dry-run：未实际校验 /root/.ssh/authorized_keys，请确认 root 已配置 SSH 公钥，否则关闭密码登录后可能锁死。"
    elif [ -s /root/.ssh/authorized_keys ] && grep -qE '(ssh-(rsa|ed25519|dss)|ecdsa-sha2|sk-(ssh|ecdsa))' /root/.ssh/authorized_keys 2>/dev/null; then
      root_key_ok=1
    fi
  fi

  if [ "$admin_key_ok" -ne 1 ] && [ "$root_key_ok" -ne 1 ]; then
    die "已选择禁用 SSH 密码登录，但没有任何可用的 key 登录通道，继续会锁死自己。请任选其一修复：
  - 提供管理用户公钥：--admin-ssh-pubkey '<your-pubkey>'（并保持创建管理用户与写入 key）；
  - 保留 root key 登录：--keep-root-key-login yes，且确保 /root/.ssh/authorized_keys 已有有效公钥；
  - 暂不禁用密码登录：--disable-ssh-password no。"
  fi

  if [ "$admin_key_ok" -ne 1 ] && [ "$root_key_ok" -eq 1 ]; then
    warn "未配置管理用户 SSH 公钥，禁用密码登录后将仅能通过 root key 登录。建议尽快为管理用户配置公钥。"
  fi
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --server-id)
        SERVER_ID="${2:-}"
        shift 2
        ;;
      --hostname)
        TARGET_HOSTNAME="${2:-}"
        shift 2
        ;;
      --role)
        ROLE="${2:-}"
        validate_role "$ROLE"
        shift 2
        ;;
      --admin-user)
        ADMIN_USER="${2:-}"
        shift 2
        ;;
      --admin-ssh-pubkey)
        ADMIN_SSH_PUBKEY="${2:-}"
        shift 2
        ;;
      --admin-ip)
        ADMIN_IP="${2:-}"
        shift 2
        ;;
      --keep-root-key-login)
        set_bool_var KEEP_ROOT_KEY_LOGIN "${2:-}"
        shift 2
        ;;
      --disable-ssh-password)
        set_bool_var DISABLE_SSH_PASSWORD "${2:-}"
        shift 2
        ;;
      --ssh-port)
        SSH_PORT="${2:-}"
        validate_port "$SSH_PORT"
        shift 2
        ;;
      --swap-size)
        SWAP_SIZE="${2:-}"
        shift 2
        ;;
      --install-docker)
        set_bool_var INSTALL_DOCKER "${2:-}"
        shift 2
        ;;
      --create-docker-networks)
        set_bool_var CREATE_DOCKER_NETWORKS "${2:-}"
        shift 2
        ;;
      --disable-ipv6)
        set_bool_var DISABLE_IPV6 "${2:-}"
        shift 2
        ;;
      --enable-bbr)
        set_bool_var ENABLE_BBR "${2:-}"
        shift 2
        ;;
      --lockdown-firewall)
        set_bool_var LOCKDOWN_FIREWALL "${2:-}"
        shift 2
        ;;
      --open-http)
        set_bool_var OPEN_HTTP "${2:-}"
        shift 2
        ;;
      --open-https)
        set_bool_var OPEN_HTTPS "${2:-}"
        shift 2
        ;;
      --extra-tcp-ports)
        EXTRA_TCP_PORTS="${2:-}"
        shift 2
        ;;
      --allow-tailscale)
        set_bool_var ALLOW_TAILSCALE "${2:-}"
        shift 2
        ;;
      --run-collect-info)
        set_bool_var RUN_COLLECT_INFO "${2:-}"
        shift 2
        ;;
      --collect-script-url)
        COLLECT_SCRIPT_URL="${2:-}"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --yes)
        ASSUME_YES=1
        INTERACTIVE=0
        shift
        ;;
      --non-interactive)
        INTERACTIVE=0
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "未知参数：$1"
        ;;
    esac
  done
}

default_if_empty() {
  local name="$1"
  local value="$2"
  if [ -z "${!name:-}" ]; then
    printf -v "$name" '%s' "$value"
  fi
}

role_defaults() {
  if [ -z "$ROLE" ]; then
    ROLE="lightweight-docker-test"
  fi
  validate_role "$ROLE"

  default_if_empty CONFIGURE_TIMEZONE yes
  default_if_empty RUN_APT_UPDATE yes
  default_if_empty RUN_APT_UPGRADE yes
  default_if_empty INSTALL_BASIC_PACKAGES yes
  default_if_empty CONFIGURE_SECURITY_UPDATES yes
  default_if_empty REBOOT_IF_REQUIRED no

  default_if_empty CREATE_ADMIN_USER yes
  default_if_empty CONFIGURE_ADMIN_KEY yes
  default_if_empty CONFIGURE_SSH yes
  default_if_empty KEEP_ROOT_KEY_LOGIN yes
  default_if_empty DISABLE_SSH_PASSWORD yes
  default_if_empty RESTRICT_ALLOW_USERS yes
  default_if_empty SSH_ADDRESS_FAMILY_INET yes

  default_if_empty CONFIGURE_FIREWALL yes
  default_if_empty RESTRICT_SSH_SOURCE yes
  default_if_empty DISABLE_IPV6 yes
  default_if_empty ALLOW_TAILSCALE no

  default_if_empty CONFIGURE_FAIL2BAN yes
  default_if_empty CONFIGURE_SWAP yes
  default_if_empty CONFIGURE_LIMITS yes
  default_if_empty CONFIGURE_SYSCTL yes
  default_if_empty ENABLE_BBR yes
  default_if_empty ENABLE_FSTRIM yes
  default_if_empty CONFIGURE_JOURNALD yes

  default_if_empty ADD_ADMIN_TO_DOCKER yes
  default_if_empty CONFIGURE_DOCKER_LOGS yes
  default_if_empty RUN_ACCEPTANCE yes
  default_if_empty GENERATE_REPORT yes
  default_if_empty RUN_COLLECT_INFO no

  case "$ROLE" in
    lightweight-docker-test)
      default_if_empty SWAP_SIZE 2G
      default_if_empty INSTALL_DOCKER yes
      default_if_empty CREATE_DOCKER_NETWORKS yes
      default_if_empty OPEN_HTTP yes
      default_if_empty OPEN_HTTPS yes
      default_if_empty LOCKDOWN_FIREWALL yes
      default_if_empty CONFIGURE_CONNTRACK yes
      ;;
    docker-app-node)
      default_if_empty SWAP_SIZE 4G
      default_if_empty INSTALL_DOCKER yes
      default_if_empty CREATE_DOCKER_NETWORKS yes
      default_if_empty OPEN_HTTP yes
      default_if_empty OPEN_HTTPS yes
      default_if_empty LOCKDOWN_FIREWALL yes
      default_if_empty CONFIGURE_CONNTRACK yes
      ;;
    storage-nfs-node)
      default_if_empty SWAP_SIZE 2G
      default_if_empty INSTALL_DOCKER no
      default_if_empty CREATE_DOCKER_NETWORKS no
      default_if_empty OPEN_HTTP no
      default_if_empty OPEN_HTTPS no
      default_if_empty LOCKDOWN_FIREWALL yes
      default_if_empty CONFIGURE_CONNTRACK no
      ;;
    basic-secure-server)
      default_if_empty SWAP_SIZE 2G
      default_if_empty INSTALL_DOCKER no
      default_if_empty CREATE_DOCKER_NETWORKS no
      default_if_empty OPEN_HTTP no
      default_if_empty OPEN_HTTPS no
      default_if_empty LOCKDOWN_FIREWALL yes
      default_if_empty CONFIGURE_CONNTRACK no
      ;;
  esac
}

ask_value() {
  local name="$1"
  local prompt="$2"
  local default_value="$3"
  local current="${!name:-}"
  local suggested="${current:-$default_value}"
  local answer=""
  read -r -p "$prompt [$suggested]: " answer || true
  printf -v "$name" '%s' "${answer:-$suggested}"
}

ask_bool() {
  local name="$1"
  local prompt="$2"
  local default_value="$3"
  local current="${!name:-}"
  local suggested="${current:-$default_value}"
  local answer=""
  read -r -p "$prompt (yes/no) [$suggested]: " answer || true
  answer="${answer:-$suggested}"
  set_bool_var "$name" "$answer"
}

choose_role_interactive() {
  if [ -n "$ROLE" ]; then
    return
  fi
  cat >&2 <<'EOF'
请选择服务器角色：
  1) lightweight-docker-test  轻量 Docker 测试节点
  2) docker-app-node          主 Docker 应用节点
  3) storage-nfs-node         存储/NFS 节点，本脚本第一版不自动配置 NFS
  4) basic-secure-server      只做基础安全加固
EOF
  local answer=""
  read -r -p "角色 [1]: " answer || true
  case "${answer:-1}" in
    1) ROLE="lightweight-docker-test" ;;
    2) ROLE="docker-app-node" ;;
    3) ROLE="storage-nfs-node" ;;
    4) ROLE="basic-secure-server" ;;
    *) die "未知角色选项：$answer" ;;
  esac
}

interactive_config() {
  if [ "$INTERACTIVE" -ne 1 ]; then
    return
  fi

  choose_role_interactive
  role_defaults

  ask_value SERVER_ID "服务器编号" "${SERVER_ID:-node01}"
  ask_value TARGET_HOSTNAME "主机名" "${TARGET_HOSTNAME:-$(hostname -s 2>/dev/null || hostname)}"
  ask_value ADMIN_USER "管理用户" "$ADMIN_USER"
  ask_value SSH_PORT "SSH 端口" "$SSH_PORT"
  validate_port "$SSH_PORT"
  ask_value ADMIN_IP "允许 SSH 的管理来源 IP/CIDR，留空表示不限制来源" "$ADMIN_IP"

  ask_bool CONFIGURE_TIMEZONE "是否设置时区为 $TIMEZONE" "$CONFIGURE_TIMEZONE"
  ask_bool RUN_APT_UPDATE "是否执行 apt update" "$RUN_APT_UPDATE"
  ask_bool RUN_APT_UPGRADE "是否执行 apt upgrade" "$RUN_APT_UPGRADE"
  ask_bool INSTALL_BASIC_PACKAGES "是否安装基础工具包" "$INSTALL_BASIC_PACKAGES"
  ask_bool CONFIGURE_SECURITY_UPDATES "是否配置 unattended-upgrades 仅自动安装安全更新" "$CONFIGURE_SECURITY_UPDATES"
  ask_bool REBOOT_IF_REQUIRED "如果系统提示需要重启，是否立即重启" "$REBOOT_IF_REQUIRED"

  ask_bool CREATE_ADMIN_USER "是否创建/修复管理用户并加入 sudo" "$CREATE_ADMIN_USER"
  ask_bool CONFIGURE_ADMIN_KEY "是否配置管理用户 SSH public key" "$CONFIGURE_ADMIN_KEY"
  if is_yes "$CONFIGURE_ADMIN_KEY"; then
    if [ -z "$ADMIN_SSH_PUBKEY" ]; then
      read -r -p "管理用户 SSH public key，留空则跳过写入: " ADMIN_SSH_PUBKEY || true
    else
      ask_value ADMIN_SSH_PUBKEY "管理用户 SSH public key" "$ADMIN_SSH_PUBKEY"
    fi
  fi

  ask_bool CONFIGURE_SSH "是否写入 SSH 安全基线" "$CONFIGURE_SSH"
  ask_bool KEEP_ROOT_KEY_LOGIN "是否保留 root SSH key 登录" "$KEEP_ROOT_KEY_LOGIN"
  ask_bool DISABLE_SSH_PASSWORD "是否禁用 SSH 密码登录" "$DISABLE_SSH_PASSWORD"
  ask_bool RESTRICT_ALLOW_USERS "是否限制 AllowUsers 为 $ADMIN_USER root" "$RESTRICT_ALLOW_USERS"
  ask_bool SSH_ADDRESS_FAMILY_INET "是否让 SSH 只监听 IPv4 AddressFamily inet" "$SSH_ADDRESS_FAMILY_INET"

  ask_bool DISABLE_IPV6 "是否禁用 IPv6" "$DISABLE_IPV6"
  ask_bool CONFIGURE_FIREWALL "是否配置 iptables 防火墙" "$CONFIGURE_FIREWALL"
  ask_bool RESTRICT_SSH_SOURCE "SSH 是否限制来源 IP" "$RESTRICT_SSH_SOURCE"
  ask_bool OPEN_HTTP "是否开放 80/tcp" "$OPEN_HTTP"
  ask_bool OPEN_HTTPS "是否开放 443/tcp" "$OPEN_HTTPS"
  ask_value EXTRA_TCP_PORTS "额外开放 TCP 端口，逗号分隔，留空表示无" "$EXTRA_TCP_PORTS"
  ask_bool ALLOW_TAILSCALE "是否放行 tailscale0 网卡流量，不安装 Tailscale" "$ALLOW_TAILSCALE"
  ask_bool LOCKDOWN_FIREWALL "是否最终设置 INPUT DROP" "$LOCKDOWN_FIREWALL"

  ask_bool CONFIGURE_FAIL2BAN "是否安装并配置 Fail2ban sshd jail" "$CONFIGURE_FAIL2BAN"
  ask_value FAIL2BAN_BANTIME "Fail2ban bantime" "$FAIL2BAN_BANTIME"
  ask_value FAIL2BAN_FINDTIME "Fail2ban findtime" "$FAIL2BAN_FINDTIME"
  ask_value FAIL2BAN_MAXRETRY "Fail2ban maxretry" "$FAIL2BAN_MAXRETRY"

  ask_bool CONFIGURE_SWAP "是否配置 swap" "$CONFIGURE_SWAP"
  ask_value SWAP_SIZE "swap 大小" "$SWAP_SIZE"
  ask_bool CONFIGURE_LIMITS "是否配置 systemd/PAM limits" "$CONFIGURE_LIMITS"
  ask_bool CONFIGURE_SYSCTL "是否配置 sysctl 生产基线" "$CONFIGURE_SYSCTL"
  ask_bool CONFIGURE_CONNTRACK "是否配置 nf_conntrack_max=262144" "$CONFIGURE_CONNTRACK"
  ask_bool ENABLE_BBR "是否启用 BBR" "$ENABLE_BBR"
  ask_bool ENABLE_FSTRIM "是否启用 fstrim.timer" "$ENABLE_FSTRIM"
  ask_bool CONFIGURE_JOURNALD "是否配置 journald 日志大小限制" "$CONFIGURE_JOURNALD"

  ask_bool INSTALL_DOCKER "是否安装 Docker Engine" "$INSTALL_DOCKER"
  if is_yes "$INSTALL_DOCKER"; then
    ask_bool ADD_ADMIN_TO_DOCKER "是否将 $ADMIN_USER 加入 docker 组" "$ADD_ADMIN_TO_DOCKER"
    ask_bool CONFIGURE_DOCKER_LOGS "是否配置 Docker json-file 日志轮转" "$CONFIGURE_DOCKER_LOGS"
    ask_bool CREATE_DOCKER_NETWORKS "是否创建 nginx-network 和 backend-network" "$CREATE_DOCKER_NETWORKS"
  fi

  ask_bool RUN_ACCEPTANCE "是否执行最终验收命令" "$RUN_ACCEPTANCE"
  ask_bool GENERATE_REPORT "是否生成本地验收报告" "$GENERATE_REPORT"
  ask_value REPORT_DIR "验收报告目录" "$REPORT_DIR"
  ask_bool RUN_COLLECT_INFO "是否下载并运行线上 collect-server-info.sh" "$RUN_COLLECT_INFO"
  if is_yes "$RUN_COLLECT_INFO"; then
    ask_value COLLECT_SCRIPT_URL "collect-server-info.sh raw URL" "$COLLECT_SCRIPT_URL"
  fi
}

validate_config() {
  validate_role "$ROLE"
  validate_port "$SSH_PORT"

  if [ -z "$SERVER_ID" ]; then
    die "--server-id 不能为空。"
  fi
  if [ -z "$TARGET_HOSTNAME" ]; then
    die "--hostname 不能为空。"
  fi
  if [ -z "$ADMIN_USER" ]; then
    die "--admin-user 不能为空。"
  fi
  if is_yes "$CONFIGURE_FIREWALL" && is_yes "$RESTRICT_SSH_SOURCE" && [ -z "$ADMIN_IP" ]; then
    die "已选择限制 SSH 来源，但 --admin-ip 为空。请传入管理 IP/CIDR，或设置 --lockdown-firewall no / --admin-ip 留空并在向导中关闭限制。"
  fi
  # 校验 ADMIN_IP 格式：支持逗号分隔多个 IPv4 / IPv4/CIDR，octet 0-255、CIDR 0-32
  if [ -n "$ADMIN_IP" ]; then
    validate_admin_ips "$ADMIN_IP" "--admin-ip"
  fi
  # 在执行任何 iptables 操作之前完整校验额外端口列表
  validate_extra_tcp_ports "$EXTRA_TCP_PORTS"
  # swap 大小格式提前校验，避免跑到 configure_swap 才 fallocate 失败
  if is_yes "$CONFIGURE_SWAP"; then
    validate_swap_size "$SWAP_SIZE"
  fi
  # 管理用户公钥形态校验：拒绝误传私钥
  if is_yes "$CONFIGURE_ADMIN_KEY" && [ -n "$ADMIN_SSH_PUBKEY" ]; then
    validate_admin_pubkey "$ADMIN_SSH_PUBKEY"
  fi
  # --yes 模式下校验 ADMIN_IP 是否与当前 SSH 来源一致；
  # SSH_CLIENT 在非 SSH 会话或某些 sudo 配置下可能未设置，此处用 :- 默认值避免 set -u 报错。
  if [ "$ASSUME_YES" -eq 1 ] && is_yes "$CONFIGURE_FIREWALL" && is_yes "$RESTRICT_SSH_SOURCE" && [ -n "$ADMIN_IP" ]; then
    local ssh_client_var="${SSH_CLIENT:-}"
    local current_ssh_ip="${ssh_client_var%% *}"
    if [ -z "$current_ssh_ip" ]; then
      warn "SSH_CLIENT 未设置（非 SSH 会话或 sudo 未透传），跳过 admin-ip 与当前来源 IP 的一致性校验。"
      warn "请确认 --admin-ip ($ADMIN_IP) 是真正的管理 IP；不一致会在收紧防火墙后锁死自己。"
    else
      # 当前来源 IP 命中逗号分隔列表里任一 admin IP（去掉 CIDR 后按裸 IP 比对）即通过
      local matched=0
      local rest="$ADMIN_IP" item bare
      while [ -n "$rest" ]; do
        case "$rest" in
          *,*) item="${rest%%,*}"; rest="${rest#*,}" ;;
          *)   item="$rest"; rest="" ;;
        esac
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        bare="${item%%/*}"
        if [ "$current_ssh_ip" = "$bare" ]; then
          matched=1
          break
        fi
      done
      if [ "$matched" -ne 1 ]; then
        warn "当前 SSH 来源 IP ($current_ssh_ip) 不在 --admin-ip ($ADMIN_IP) 列表中！"
        warn "如果防火墙收紧后当前会话断开，你可能无法重新登录。"
        warn "请确认供应商控制台可用，或取消并修改 --admin-ip。"
      fi
    fi
  fi
  if is_yes "$RUN_COLLECT_INFO" && [ -z "$COLLECT_SCRIPT_URL" ]; then
    die "已选择运行采集脚本，但 --collect-script-url 为空。"
  fi
  # 防锁死兜底：关闭密码登录时必须保留至少一条 key 登录通道
  check_login_path_safety
}

print_summary() {
  cat <<EOF

即将执行的配置摘要：

基础：
  server-id:              $SERVER_ID
  hostname:               $TARGET_HOSTNAME
  role:                   $ROLE
  dry-run:                $DRY_RUN

系统：
  timezone:               $CONFIGURE_TIMEZONE ($TIMEZONE)
  apt update:             $RUN_APT_UPDATE
  apt upgrade:            $RUN_APT_UPGRADE
  basic packages:         $INSTALL_BASIC_PACKAGES
  security auto updates:  $CONFIGURE_SECURITY_UPDATES
  reboot if required:     $REBOOT_IF_REQUIRED

用户与 SSH：
  admin user:             $ADMIN_USER
  admin SSH key write:    $CONFIGURE_ADMIN_KEY
  ssh baseline:           $CONFIGURE_SSH
  ssh port:               $SSH_PORT
  root key login:         $KEEP_ROOT_KEY_LOGIN
  password login off:     $DISABLE_SSH_PASSWORD
  AllowUsers:             $RESTRICT_ALLOW_USERS
  SSH IPv4 only:          $SSH_ADDRESS_FAMILY_INET

网络与安全：
  disable IPv6:           $DISABLE_IPV6
  firewall:               $CONFIGURE_FIREWALL
  restrict SSH source:    $RESTRICT_SSH_SOURCE
  admin IP/CIDR:          ${ADMIN_IP:-<empty>}
  open 80/tcp:            $OPEN_HTTP
  open 443/tcp:           $OPEN_HTTPS
  extra TCP ports:        ${EXTRA_TCP_PORTS:-<none>}
  allow tailscale0:       $ALLOW_TAILSCALE
  INPUT DROP:             $LOCKDOWN_FIREWALL
  fail2ban:               $CONFIGURE_FAIL2BAN

性能与稳定性：
  swap:                   $CONFIGURE_SWAP ($SWAP_SIZE)
  limits:                 $CONFIGURE_LIMITS
  sysctl baseline:        $CONFIGURE_SYSCTL
  conntrack:              $CONFIGURE_CONNTRACK
  BBR:                    $ENABLE_BBR
  fstrim.timer:           $ENABLE_FSTRIM
  journald limit:         $CONFIGURE_JOURNALD

Docker：
  install Docker:         $INSTALL_DOCKER
  admin docker group:     $ADD_ADMIN_TO_DOCKER
  Docker log rotation:    $CONFIGURE_DOCKER_LOGS
  Docker networks:        $CREATE_DOCKER_NETWORKS

验收：
  acceptance commands:    $RUN_ACCEPTANCE
  local report:           $GENERATE_REPORT ($REPORT_DIR)
  collect-server-info:    $RUN_COLLECT_INFO

EOF
}

confirm_execution() {
  print_summary
  if [ "$ASSUME_YES" -eq 1 ]; then
    warn "已传入 --yes，将按上面配置直接执行。请确认你已有供应商控制台或其他应急入口。"
    return
  fi

  cat >&2 <<'EOF'
高风险提醒：
  - SSH 和防火墙修改可能导致当前会话断开。
  - 执行前请保留当前 SSH 会话，并确认供应商控制台可用。
  - 防火墙收紧前，脚本会再次提醒你新开会话验证。

输入 CONFIRM 继续执行，其他输入退出。
EOF
  local answer=""
  read -r -p "> " answer || true
  if [ "$answer" != "CONFIRM" ]; then
    die "用户取消执行。"
  fi
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

run_shell() {
  local command="$1"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] bash -c %q\n' "$command"
    return 0
  fi
  bash -c "$command"
}

# 只读命令包装：dry-run 下也真实执行，让用户看到当前真实状态。
# 仅用于不修改系统的命令（hostnamectl 不带 set 参数、sysctl 单参数读、iptables -S 等）。
# 失败不视为致命，仅 warn，避免 set -e 中断 dry-run 审核。
run_readonly() {
  # 注意：set -e + ERR trap 下，不能直接 "$@" || handle，否则 trap 仍会触发；
  # 用 if 包裹同时禁用临时的 ERR 传播，并在子 shell 外捕获退出码。
  local rc=0
  "$@" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "[readonly] 命令失败（exit $rc，dry-run 容忍）：$*"
  fi
  return 0
}

require_root() {
  if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$(id -u)" -ne 0 ]; then
      warn "dry-run 模式：当前不是 root，实际执行时需要 root 权限。"
    fi
    return
  fi
  if [ "$(id -u)" -ne 0 ]; then
    die "请用 root 执行，或使用 sudo。"
  fi
}

require_debian12() {
  if [ ! -r /etc/os-release ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      warn "dry-run 模式：找不到 /etc/os-release，实际执行时需要 Debian 12。"
      return
    fi
    die "找不到 /etc/os-release，无法确认系统版本。"
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  if [ "${ID:-}" != "debian" ] || [ "${VERSION_ID:-}" != "12" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      warn "dry-run 模式：当前系统不是 Debian 12（${PRETTY_NAME:-unknown}），实际执行时会拒绝。"
      return
    fi
    die "第一版只支持 Debian 12。当前系统：${PRETTY_NAME:-unknown}"
  fi
}

prepare_backup_dir() {
  TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
  BACKUP_DIR="/root/server-init-backup-$TIMESTAMP"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "dry-run: would create backup dir $BACKUP_DIR"
    return
  fi
  mkdir -p "$BACKUP_DIR"
  info "备份目录：$BACKUP_DIR"
}

backup_path() {
  local path="$1"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "dry-run: would backup $path"
    return
  fi
  if [ -e "$path" ]; then
    local dest="$BACKUP_DIR/${path#/}"
    mkdir -p "$(dirname "$dest")"
    cp -a "$path" "$dest"
  fi
}

backup_command_output() {
  local name="$1"
  shift
  if [ "$DRY_RUN" -eq 1 ]; then
    info "dry-run: would save command output: $name"
    return
  fi
  "$@" >"$BACKUP_DIR/$name" 2>&1 || true
}

write_file() {
  local path="$1"
  local mode="$2"
  local owner="$3"
  local group="$4"
  local content="$5"

  backup_path "$path"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "dry-run: would write $path"
    printf '%s\n' "$content"
    return
  fi
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" >"$path"
  chmod "$mode" "$path"
  chown "$owner:$group" "$path"
}

ensure_line() {
  local file="$1"
  local line="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "dry-run: would ensure line in $file: $line"
    return
  fi
  touch "$file"
  grep -Fxq "$line" "$file" || printf '%s\n' "$line" >>"$file"
}

configure_hostname() {
  info "配置主机名：$TARGET_HOSTNAME"
  if [ "$(hostnamectl --static 2>/dev/null || hostname)" != "$TARGET_HOSTNAME" ]; then
    run hostnamectl set-hostname "$TARGET_HOSTNAME"
  fi
}

configure_timezone() {
  if ! is_yes "$CONFIGURE_TIMEZONE"; then
    return
  fi
  info "配置时区：$TIMEZONE"
  run timedatectl set-timezone "$TIMEZONE"
}

install_packages() {
  if is_yes "$RUN_APT_UPDATE"; then
    info "执行 apt update"
    run apt-get update
  fi
  if is_yes "$RUN_APT_UPGRADE"; then
    info "执行 apt upgrade"
    run env DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
  fi
  if is_yes "$INSTALL_BASIC_PACKAGES"; then
    info "安装基础工具包"
    run env DEBIAN_FRONTEND=noninteractive apt-get -y install "${BASIC_PACKAGES[@]}"
  fi
}

configure_security_updates() {
  if ! is_yes "$CONFIGURE_SECURITY_UPDATES"; then
    return
  fi
  info "配置 unattended-upgrades 仅自动安装安全更新"
  write_file "/etc/apt/apt.conf.d/20auto-upgrades" 0644 root root \
'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";'

  write_file "/etc/apt/apt.conf.d/51unattended-upgrades-security-only" 0644 root root \
'// Managed by init-debian12-production-baseline.sh
// 顶层 #clear 指令清空 50unattended-upgrades 中默认累积的 Origins-Pattern，
// 然后只追加 security-only 来源。漏掉 #clear，drop-in 只是追加，stable
// updates 等非 security 来源仍会被自动安装。
// 参考：apt.conf(5)，#clear 是顶层指令而不是 list 字符串条目。
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";'

  run systemctl enable --now unattended-upgrades
}

configure_admin_user() {
  if ! is_yes "$CREATE_ADMIN_USER"; then
    return
  fi
  info "创建/修复管理用户：$ADMIN_USER"
  if ! id "$ADMIN_USER" >/dev/null 2>&1; then
    run adduser --disabled-password --gecos "" "$ADMIN_USER"
  fi
  run usermod -aG sudo "$ADMIN_USER"

  if is_yes "$CONFIGURE_ADMIN_KEY" && [ -n "$ADMIN_SSH_PUBKEY" ]; then
    local home_dir=""
    if command -v getent >/dev/null 2>&1; then
      # 用 if 条件包住命令替换：set -euo pipefail 下，getent 找不到用户会返回非 0，
      # 直接 home_dir="$(...)" 会被 set -e 立即退出，走不到下面的 dry-run fallback。
      if home_dir="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"; then
        :
      else
        home_dir=""
      fi
    elif [ "$DRY_RUN" -eq 1 ]; then
      info "dry-run: 当前环境没有 getent（典型如 Windows Git Bash），跳过 home 目录解析。"
    else
      die "找不到 getent 命令，无法解析 $ADMIN_USER 的 home 目录。"
    fi
    if [ -z "$home_dir" ]; then
      if [ "$DRY_RUN" -eq 1 ]; then
        home_dir="/home/$ADMIN_USER"
        info "dry-run: 用户尚不存在或无法解析，假定 home 目录为 $home_dir"
      else
        die "无法找到 $ADMIN_USER 的 home 目录。"
      fi
    fi
    info "写入管理用户 SSH public key"
    if [ "$DRY_RUN" -eq 1 ]; then
      info "dry-run: would append public key to $home_dir/.ssh/authorized_keys"
      return
    fi
    install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$home_dir/.ssh"
    touch "$home_dir/.ssh/authorized_keys"
    chown "$ADMIN_USER:$ADMIN_USER" "$home_dir/.ssh/authorized_keys"
    chmod 600 "$home_dir/.ssh/authorized_keys"
    grep -Fxq "$ADMIN_SSH_PUBKEY" "$home_dir/.ssh/authorized_keys" || printf '%s\n' "$ADMIN_SSH_PUBKEY" >>"$home_dir/.ssh/authorized_keys"
  elif is_yes "$CONFIGURE_ADMIN_KEY"; then
    warn "未提供 ADMIN_SSH_PUBKEY，跳过写入管理用户 SSH key。"
  fi
}

configure_ssh() {
  if ! is_yes "$CONFIGURE_SSH"; then
    return
  fi
  info "写入 SSH 安全基线"
  local permit_root="no"
  if is_yes "$KEEP_ROOT_KEY_LOGIN"; then
    permit_root="prohibit-password"
  fi

  local password_auth="yes"
  local kbd_auth="yes"
  if is_yes "$DISABLE_SSH_PASSWORD"; then
    password_auth="no"
    kbd_auth="no"
  fi

  local address_family=""
  if is_yes "$SSH_ADDRESS_FAMILY_INET"; then
    address_family="AddressFamily inet"
  fi

  local allow_users=""
  if is_yes "$RESTRICT_ALLOW_USERS"; then
    allow_users="AllowUsers $ADMIN_USER root"
  fi

  write_file "/etc/ssh/sshd_config.d/99-server-baseline.conf" 0644 root root \
"# Managed by init-debian12-production-baseline.sh
Port $SSH_PORT
${address_family:+$address_family
}PermitRootLogin $permit_root
PubkeyAuthentication yes
PasswordAuthentication $password_auth
KbdInteractiveAuthentication $kbd_auth
PermitEmptyPasswords no
AuthorizedKeysFile .ssh/authorized_keys
${allow_users:+$allow_users
}MaxAuthTries 3
MaxSessions $MAX_SESSIONS
LoginGraceTime 60
ClientAliveInterval 600
ClientAliveCountMax 2
TCPKeepAlive yes
X11Forwarding no
LogLevel VERBOSE"

  local sshd_bin="/usr/sbin/sshd"
  if command -v sshd >/dev/null 2>&1; then
    sshd_bin="$(command -v sshd)"
  fi
  run "$sshd_bin" -t
  run systemctl reload ssh
}

configure_ipv6() {
  if ! is_yes "$DISABLE_IPV6"; then
    return
  fi
  info "禁用 IPv6"
  write_file "/etc/sysctl.d/99-disable-ipv6.conf" 0644 root root \
'# Managed by init-debian12-production-baseline.sh
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1'
  run sysctl -p /etc/sysctl.d/99-disable-ipv6.conf
}

add_iptables_rule() {
  run iptables -A INPUT "$@"
}

add_ip6tables_rule() {
  run ip6tables -A INPUT "$@"
}

add_extra_tcp_ports() {
  if [ -z "$EXTRA_TCP_PORTS" ]; then
    return
  fi
  local port
  local old_ifs="$IFS"
  IFS=','
  for port in $EXTRA_TCP_PORTS; do
    IFS="$old_ifs"
    port="${port//[[:space:]]/}"
    if [ -n "$port" ]; then
      validate_port "$port"
      info "开放额外 TCP 端口：$port"
      add_iptables_rule -p tcp --dport "$port" -j ACCEPT
    fi
    IFS=','
  done
  IFS="$old_ifs"
}

firewall_open_ports() {
  # 阶段一：在 SSH 配置修改之前，先确保管理端口在 iptables 中放行。
  # 这样即使 sshd reload 后端口变了，防火墙已经准备好了。
  if ! is_yes "$CONFIGURE_FIREWALL"; then
    return
  fi

  info "防火墙阶段一：备份并放行管理端口"
  backup_command_output "iptables-save.before" iptables-save
  backup_command_output "ip6tables-save.before" ip6tables-save

  run iptables -P INPUT ACCEPT
  run iptables -F INPUT
  add_iptables_rule -i lo -j ACCEPT
  add_iptables_rule -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

  if is_yes "$ALLOW_TAILSCALE"; then
    add_iptables_rule -i tailscale0 -j ACCEPT
  fi

  if is_yes "$RESTRICT_SSH_SOURCE"; then
    # 逗号分隔的多个管理来源，逐个放行 SSH 端口
    local ssh_src_rest="$ADMIN_IP" ssh_src
    while [ -n "$ssh_src_rest" ]; do
      case "$ssh_src_rest" in
        *,*) ssh_src="${ssh_src_rest%%,*}"; ssh_src_rest="${ssh_src_rest#*,}" ;;
        *)   ssh_src="$ssh_src_rest"; ssh_src_rest="" ;;
      esac
      ssh_src="${ssh_src//[[:space:]]/}"
      if [ -n "$ssh_src" ]; then
        info "放行 SSH 管理来源：$ssh_src"
        add_iptables_rule -p tcp -s "$ssh_src" --dport "$SSH_PORT" -j ACCEPT
      fi
    done
  else
    add_iptables_rule -p tcp --dport "$SSH_PORT" -j ACCEPT
  fi

  if is_yes "$OPEN_HTTP"; then
    add_iptables_rule -p tcp --dport 80 -j ACCEPT
  fi
  if is_yes "$OPEN_HTTPS"; then
    add_iptables_rule -p tcp --dport 443 -j ACCEPT
  fi
  add_extra_tcp_ports

  # ip6tables：无论是否禁用 IPv6，都同步配置对称规则，避免 IPv6 暴露面
  run ip6tables -P INPUT ACCEPT
  run ip6tables -F INPUT
  add_ip6tables_rule -i lo -j ACCEPT
  add_ip6tables_rule -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

  # 阶段一不设 INPUT DROP，保持 ACCEPT，给后续 SSH 验证留安全窗口
  run netfilter-persistent save
}

firewall_lockdown() {
  # 阶段二：SSH 配置已生效、管理端口已放行后，收紧默认策略为 INPUT DROP。
  if ! is_yes "$CONFIGURE_FIREWALL"; then
    return
  fi
  if ! is_yes "$LOCKDOWN_FIREWALL"; then
    info "防火墙阶段二：LOCKDOWN_FIREWALL=no，跳过 INPUT DROP。"
    run netfilter-persistent save
    run netfilter-persistent reload
    return
  fi

  if [ "$ASSUME_YES" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
    cat >&2 <<EOF

即将设置 INPUT DROP 收紧防火墙。
请在继续前确认：
  1. 当前 SSH 会话不要关闭。
  2. 供应商控制台可用。
  3. 新 SSH 配置已通过 sshd -t 且 reload 完成。
  4. 管理来源 IP/CIDR 正确：${ADMIN_IP:-<empty>}
  5. 建议新开一个 SSH 会话验证端口 $SSH_PORT 可登录后再继续。

输入 CONFIRM_FIREWALL 继续，其他输入退出。
EOF
    local answer=""
    read -r -p "> " answer || true
    if [ "$answer" != "CONFIRM_FIREWALL" ]; then
      die "用户取消防火墙锁定。"
    fi
  fi

  info "防火墙阶段二：设置 INPUT DROP"
  run iptables -P INPUT DROP
  run iptables -P OUTPUT ACCEPT
  run iptables -P FORWARD DROP

  # ip6tables 同步锁定
  run ip6tables -P INPUT DROP
  run ip6tables -P OUTPUT ACCEPT
  run ip6tables -P FORWARD DROP

  run netfilter-persistent save
  run netfilter-persistent reload
}

configure_fail2ban() {
  if ! is_yes "$CONFIGURE_FAIL2BAN"; then
    return
  fi
  info "配置 Fail2ban sshd jail"
  write_file "/etc/fail2ban/jail.d/sshd.local" 0644 root root \
"[sshd]
enabled = true
backend = systemd
port = $SSH_PORT
filter = sshd
bantime = $FAIL2BAN_BANTIME
findtime = $FAIL2BAN_FINDTIME
maxretry = $FAIL2BAN_MAXRETRY"

  run systemctl enable --now fail2ban
  run systemctl restart fail2ban
}

configure_swap() {
  if ! is_yes "$CONFIGURE_SWAP"; then
    return
  fi
  info "配置 swap：$SWAP_SIZE"
  if swapon --show=NAME --noheadings 2>/dev/null | grep -q .; then
    warn "系统已有启用中的 swap，跳过创建。当前 swap："
    swapon --show >&2 || true
    # 检查 fstab 是否有 swap 条目，没有则提示
    if ! grep -qE '^[^#].*\bswap\b' /etc/fstab 2>/dev/null; then
      warn "注意：/etc/fstab 中没有 swap 条目，重启后 swap 可能丢失。"
      warn "当前活跃 swap 来源：$(swapon --show=NAME --noheadings 2>/dev/null)"
      warn "如需持久化，请手动在 /etc/fstab 中添加对应条目。"
    fi
    return
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "dry-run: would create /swapfile size $SWAP_SIZE"
    return
  fi
  if [ -e /swapfile ]; then
    backup_path /swapfile
    rm -f /swapfile
  fi
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  backup_path /etc/fstab
  # 幂等：只在 fstab 没有 /swapfile 条目时追加
  if ! grep -qE '^/swapfile\b' /etc/fstab 2>/dev/null; then
    printf '%s\n' '/swapfile none swap sw 0 0  # managed-by: init-debian12-production-baseline.sh' >>/etc/fstab
  fi
}

configure_limits() {
  if ! is_yes "$CONFIGURE_LIMITS"; then
    return
  fi
  info "配置 PAM 和 systemd limits"
  write_file "/etc/security/limits.d/99-server-baseline.conf" 0644 root root \
'# Managed by init-debian12-production-baseline.sh
* soft nofile 65535
* hard nofile 65535
* soft nproc 65535
* hard nproc 65535'

  write_file "/etc/systemd/system.conf.d/99-limits.conf" 0644 root root \
'[Manager]
DefaultLimitNOFILE=65535
DefaultLimitNPROC=65535'

  write_file "/etc/systemd/user.conf.d/99-limits.conf" 0644 root root \
'[Manager]
DefaultLimitNOFILE=65535
DefaultLimitNPROC=65535'

  run systemctl daemon-reexec
}

configure_sysctl() {
  if ! is_yes "$CONFIGURE_SYSCTL"; then
    return
  fi
  info "配置 sysctl 生产基线"
  local conntrack_line=""
  if is_yes "$CONFIGURE_CONNTRACK"; then
    conntrack_line=$'\n# Docker/NAT/iptables 场景下提高连接跟踪容量。\nnet.netfilter.nf_conntrack_max = 262144'
  fi

  write_file "/etc/sysctl.d/99-server-baseline.conf" 0644 root root \
"# Managed by init-debian12-production-baseline.sh
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 10000 65535
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024$conntrack_line"

  if is_yes "$ENABLE_BBR"; then
    write_file "/etc/sysctl.d/99-network-bbr.conf" 0644 root root \
'# Managed by init-debian12-production-baseline.sh
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr'
  fi

  run sysctl --system
}

configure_fstrim() {
  if ! is_yes "$ENABLE_FSTRIM"; then
    return
  fi
  info "启用 fstrim.timer"
  run systemctl enable --now fstrim.timer
}

configure_journald() {
  if ! is_yes "$CONFIGURE_JOURNALD"; then
    return
  fi
  info "配置 journald 日志大小限制"
  write_file "/etc/systemd/journald.conf.d/99-server-baseline.conf" 0644 root root \
'[Journal]
SystemMaxUse=1G
SystemKeepFree=1G
MaxRetentionSec=30day'
  run systemctl restart systemd-journald
}

install_docker() {
  if ! is_yes "$INSTALL_DOCKER"; then
    return
  fi
  info "安装 Docker Engine（Docker 官方 apt 源）"
  run install -m 0755 -d /etc/apt/keyrings
  run curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  run chmod a+r /etc/apt/keyrings/docker.asc

  local codename="bookworm"
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    codename="${VERSION_CODENAME:-bookworm}"
  elif [ "$DRY_RUN" -eq 1 ]; then
    info "dry-run: /etc/os-release 不可读，假定 codename=bookworm"
  else
    die "无法读取 /etc/os-release。"
  fi
  local arch
  if command -v dpkg >/dev/null 2>&1; then
    arch="$(dpkg --print-architecture)"
  elif [ "$DRY_RUN" -eq 1 ]; then
    arch="amd64"
    info "dry-run: dpkg 不可用，假定 arch=$arch"
  else
    die "找不到 dpkg。"
  fi
  write_file "/etc/apt/sources.list.d/docker.list" 0644 root root \
"deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $codename stable"

  run apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  local need_restart=0
  if is_yes "$CONFIGURE_DOCKER_LOGS"; then
    local desired_config='{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  }
}'
    if [ ! -f /etc/docker/daemon.json ]; then
      info "写入 Docker daemon.json（首次创建，仅含日志轮转）"
      write_file "/etc/docker/daemon.json" 0644 root root "$desired_config"
      need_restart=1
    else
      local current_config
      current_config="$(cat /etc/docker/daemon.json 2>/dev/null || true)"
      if [ "$current_config" = "$desired_config" ]; then
        info "Docker daemon.json 已是目标配置，跳过写入。"
      else
        # 已有自定义配置（registry-mirrors / proxies / live-restore 等），不覆盖
        warn "/etc/docker/daemon.json 已存在且内容与脚本目标不一致。"
        warn "为避免覆盖你的 registry-mirrors / proxies / live-restore 等自定义配置，已跳过写入。"
        warn "如需追加日志轮转，请手动合并以下字段："
        warn '  "log-driver": "json-file"'
        warn '  "log-opts": { "max-size": "100m", "max-file": "3" }'
        warn "现有文件已备份到 $BACKUP_DIR（如本次为 dry-run 则未备份）。"
        backup_path /etc/docker/daemon.json
      fi
    fi
  fi

  run systemctl enable --now docker
  if [ "$need_restart" -eq 1 ]; then
    info "daemon.json 已更新，重启 Docker。"
    run systemctl restart docker
  fi

  if is_yes "$ADD_ADMIN_TO_DOCKER"; then
    warn "将 $ADMIN_USER 加入 docker 组。注意：docker 组成员等同于宿主机 root 权限。"
    run usermod -aG docker "$ADMIN_USER"
  fi

  if is_yes "$CREATE_DOCKER_NETWORKS"; then
    run_shell "docker network inspect nginx-network >/dev/null 2>&1 || docker network create nginx-network"
    run_shell "docker network inspect backend-network >/dev/null 2>&1 || docker network create backend-network"
  fi
}

append_cmd_report() {
  local report="$1"
  local title="$2"
  local command="$3"
  {
    printf '\n### %s\n\n' "$title"
    printf '命令：`%s`\n\n' "$command"
    printf '```text\n'
    bash -c "$command" 2>&1 || true
    printf '```\n'
  } >>"$report"
}

run_acceptance_checks() {
  if ! is_yes "$RUN_ACCEPTANCE"; then
    return
  fi
  info "执行最终验收命令（只读，dry-run 下也会执行以展示当前真实状态）"
  run_readonly hostnamectl
  run_readonly systemctl --failed --no-pager
  run_readonly swapon --show
  run_readonly sysctl vm.swappiness
  run_readonly sysctl fs.file-max
  run_readonly sysctl net.core.somaxconn
  run_readonly sysctl net.ipv4.tcp_max_syn_backlog
  if is_yes "$CONFIGURE_CONNTRACK"; then
    run_readonly sysctl net.netfilter.nf_conntrack_max
  fi
  if is_yes "$ENABLE_BBR"; then
    run_readonly sysctl net.ipv4.tcp_congestion_control
  fi
  run_readonly iptables -S INPUT
  if is_yes "$CONFIGURE_FAIL2BAN"; then
    run_readonly fail2ban-client status sshd
  fi
  if is_yes "$INSTALL_DOCKER"; then
    run_readonly docker version
    run_readonly docker compose version
    run_readonly docker info
    run_readonly docker network ls
  fi
}

generate_report() {
  if ! is_yes "$GENERATE_REPORT"; then
    return
  fi
  info "生成本地验收报告"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "dry-run: would generate report in $REPORT_DIR"
    return
  fi
  mkdir -p "$REPORT_DIR"
  local report="$REPORT_DIR/server-init-report-$SERVER_ID-$TARGET_HOSTNAME-$TIMESTAMP.md"
  {
    printf '# Server Init Report\n\n'
    printf '| Item | Value |\n'
    printf '| --- | --- |\n'
    printf '| server_id | `%s` |\n' "$SERVER_ID"
    printf '| hostname | `%s` |\n' "$TARGET_HOSTNAME"
    printf '| role | `%s` |\n' "$ROLE"
    printf '| script_version | `%s` |\n' "$SCRIPT_VERSION"
    printf '| generated_at | `%s` |\n' "$(date '+%Y-%m-%d %H:%M:%S %Z %z')"
    printf '| backup_dir | `%s` |\n' "$BACKUP_DIR"
  } >"$report"

  append_cmd_report "$report" "系统版本" "cat /etc/os-release"
  append_cmd_report "$report" "主机信息" "hostnamectl"
  append_cmd_report "$report" "启动失败服务" "systemctl --failed --no-pager"
  append_cmd_report "$report" "SSH 生效配置" "sshd -T 2>/dev/null | grep -Ei '^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|authorizedkeysfile|allowusers|maxsessions|addressfamily)\\b' || true"
  append_cmd_report "$report" "防火墙 INPUT" "iptables -S INPUT"
  append_cmd_report "$report" "IPv6 状态" "sysctl net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6 net.ipv6.conf.lo.disable_ipv6 2>/dev/null || true"
  append_cmd_report "$report" "Fail2ban sshd" "fail2ban-client status sshd 2>/dev/null || true"
  append_cmd_report "$report" "Swap" "swapon --show; free -h"
  append_cmd_report "$report" "sysctl 基线" "sysctl net.core.somaxconn net.ipv4.tcp_max_syn_backlog net.ipv4.ip_local_port_range vm.swappiness vm.dirty_ratio vm.dirty_background_ratio fs.file-max fs.inotify.max_user_watches fs.inotify.max_user_instances net.netfilter.nf_conntrack_max net.ipv4.tcp_congestion_control 2>/dev/null || true"
  append_cmd_report "$report" "fstrim.timer" "systemctl list-timers fstrim.timer --no-pager 2>/dev/null || true"
  append_cmd_report "$report" "journald 用量" "journalctl --disk-usage 2>/dev/null || true"
  append_cmd_report "$report" "Docker" "docker version 2>/dev/null; docker compose version 2>/dev/null; docker info 2>/dev/null | grep -Ei 'Logging Driver|Docker Root Dir|Cgroup Driver|Server Version' || true; docker network ls 2>/dev/null || true"
  info "报告路径：$report"
}

run_collect_info() {
  if ! is_yes "$RUN_COLLECT_INFO"; then
    return
  fi
  info "下载并运行 collect-server-info.sh"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "dry-run: would download and run $COLLECT_SCRIPT_URL"
    return
  fi
  local tmp_script="/tmp/collect-server-info.sh"
  curl -fsSL "$COLLECT_SCRIPT_URL" -o "$tmp_script"
  chmod 700 "$tmp_script"
  "$tmp_script" --server-id "$SERVER_ID" --output-dir "$REPORT_DIR"
}

handle_reboot_required() {
  if [ ! -f /var/run/reboot-required ]; then
    return
  fi

  warn "系统提示需要重启："
  cat /var/run/reboot-required >&2 || true
  if [ -r /var/run/reboot-required.pkgs ]; then
    cat /var/run/reboot-required.pkgs >&2 || true
  fi

  if is_yes "$REBOOT_IF_REQUIRED"; then
    warn "即将执行 reboot。"
    run systemctl reboot
  else
    warn "已按配置跳过自动重启，请在维护窗口手动重启。"
  fi
}

print_completion_notes() {
  cat <<EOF

初始化脚本执行完成。

重要后续动作：
  1. 保留当前 SSH 会话，新开一个 SSH 会话验证端口 $SSH_PORT 可登录。
  2. 验证 root 只能 SSH key 登录，密码登录不可用。
  3. 如果安装了 Docker，$ADMIN_USER 需要重新登录后 docker 组权限才生效。
  4. 如果 /var/run/reboot-required 存在，请在维护窗口重启。
  5. 把实际验收结果同步登记到 docs/sop/production.md 或对应服务器记录。

备份目录：
  $BACKUP_DIR

EOF
}

main() {
  phase_start "parse-args"
  parse_args "$@"
  phase_start "require-root"
  require_root
  phase_start "require-debian12"
  require_debian12

  if [ "$INTERACTIVE" -eq 1 ]; then
    phase_start "interactive-config"
    interactive_config
  fi
  phase_start "role-defaults"
  role_defaults
  phase_start "validate-config"
  validate_config
  phase_start "confirm-execution"
  confirm_execution

  phase_start "prepare-backup-dir"
  prepare_backup_dir
  backup_command_output "sshd-T.before" /usr/sbin/sshd -T

  phase_start "hostname"
  configure_hostname
  phase_start "timezone"
  configure_timezone
  phase_start "install-packages"
  install_packages
  phase_start "security-updates"
  configure_security_updates
  phase_start "admin-user"
  configure_admin_user
  phase_start "ipv6"
  configure_ipv6
  phase_start "firewall-open-ports"
  firewall_open_ports
  phase_start "ssh-baseline"
  configure_ssh
  phase_start "fail2ban"
  configure_fail2ban
  phase_start "firewall-lockdown"
  firewall_lockdown
  phase_start "swap"
  configure_swap
  phase_start "limits"
  configure_limits
  phase_start "sysctl"
  configure_sysctl
  phase_start "fstrim"
  configure_fstrim
  phase_start "journald"
  configure_journald
  phase_start "docker"
  install_docker
  phase_start "acceptance-checks"
  run_acceptance_checks
  phase_start "generate-report"
  generate_report
  phase_start "collect-info"
  run_collect_info
  phase_start "reboot-required"
  handle_reboot_required
  phase_start "completed"
  print_completion_notes
}

main "$@"
