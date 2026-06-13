# scripts

Reusable server and operations scripts for Debian 12 production servers.

两个脚本：服务器信息采集（只读）+ Debian 12 生产环境基线初始化。所有示例均使用占位值（如 `node01`、`203.0.113.10`、端口 `2222`），请按实际环境替换。

## 脚本

| 脚本 | 作用 |
| --- | --- |
| `collect-server-info.sh` | 只读采集 Linux 服务器基础信息（系统/CPU/内存/磁盘/网络/安全/包/服务/Docker/NFS/监控/日志），生成 Markdown 报告；默认对公网 IP、MAC、Machine ID、URL 内嵌凭据脱敏。 |
| `init-debian12-production-baseline.sh` | 从干净 Debian 12 系统执行的生产基线初始化：主机名/时区/更新、管理用户与 SSH 加固、iptables 防火墙、Fail2ban、swap、sysctl/limits、可选 Docker；支持交互向导、参数化与 dry-run。 |

## 获取

```bash
git clone https://github.com/bytehivex/scripts.git
cd scripts

# 或按需单独拉取
curl -fsSL https://raw.githubusercontent.com/bytehivex/scripts/main/collect-server-info.sh -o collect-server-info.sh
curl -fsSL https://raw.githubusercontent.com/bytehivex/scripts/main/init-debian12-production-baseline.sh -o init-debian12-production-baseline.sh
```

## collect-server-info.sh

只读：不安装软件、不改配置、不重启服务。默认脱敏依赖 `perl`（Debian 12 自带）。

```bash
# 基本用法
sudo ./collect-server-info.sh --server-id node01

# 交互式
sudo ./collect-server-info.sh --interactive
```

| 参数 | 说明 |
| --- | --- |
| `--server-id <id>` | 服务器编号（必填，或用 `--interactive`） |
| `--output-dir <dir>` | 报告输出目录，默认 `./server-info-reports` |
| `--include-public-ip` | 采集公网出口 IP（默认仍脱敏为 `a.b.*.*`） |
| `--include-network-probe` | 轻量外部探测（公网 IP / DNS / ping），默认关闭 |
| `--no-mask` | 关闭脱敏（仅限报告私有保存时使用） |
| `--interactive` | 交互式填写 |

报告默认 `chmod 600` 写入 `--output-dir`。非 root 也能跑，但 root 下防火墙、NFS、Docker、systemd 与日志信息更完整。

## init-debian12-production-baseline.sh

> ⚠️ **高风险**：会修改 SSH 与防火墙，可能导致当前会话断开。执行前务必保留当前 SSH 会话、确认供应商控制台可用，并先用 `--dry-run` 审核计划。仅支持 Debian 12，需 root。

```bash
# 1) 先 dry-run 审核执行计划（不改系统）
sudo ./init-debian12-production-baseline.sh --dry-run --yes \
  --server-id node01 --hostname node01 --role lightweight-docker-test \
  --admin-ip 203.0.113.10 --admin-ssh-pubkey "ssh-ed25519 AAAA... you@host"

# 2) 交互向导（推荐首次使用）
sudo ./init-debian12-production-baseline.sh
```

角色（`--role`）：

| 角色 | 用途 |
| --- | --- |
| `lightweight-docker-test` | 轻量 Docker 测试节点（默认） |
| `docker-app-node` | 主 Docker 应用节点 |
| `storage-nfs-node` | 存储/NFS 节点（第一版不自动配置 NFS） |
| `basic-secure-server` | 仅基础安全加固 |

常用参数（完整见 `--help`）：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `--server-id` / `--hostname` | — | 服务器编号 / 主机名 |
| `--role` | `lightweight-docker-test` | 角色，决定各模块默认值 |
| `--admin-user` | `admin` | 管理用户（加入 sudo） |
| `--admin-ssh-pubkey` | — | 管理用户 SSH 公钥（**只传公钥，不要传私钥**） |
| `--admin-ip <ip/cidr[,...]>` | — | 允许 SSH 的管理来源，可逗号分隔多个 |
| `--ssh-port` | `2222` | SSH 端口 |
| `--keep-root-key-login` | 角色默认 | 是否保留 root 的 SSH key 登录 |
| `--disable-ssh-password` | 角色默认 | 是否禁用 SSH 密码登录 |
| `--swap-size` | 角色默认 | swap 大小，如 `2G`、`512M` |
| `--install-docker` | 角色默认 | 是否安装 Docker Engine |
| `--open-http` / `--open-https` | 角色默认 | 是否开放 80 / 443 |
| `--extra-tcp-ports` | — | 额外开放 TCP 端口，逗号分隔 |
| `--lockdown-firewall` | 角色默认 | 是否最终 `INPUT DROP` |
| `--dry-run` | — | 只打印动作，不改系统 |
| `--yes` | — | 非交互执行（确认应急入口可用再用） |

安全设计：

- 所有托管配置写入前备份到 `/root/server-init-backup-<timestamp>/`。
- 防火墙分两阶段：先放行管理端口（INPUT ACCEPT），SSH 验证通过后再 `INPUT DROP`；收紧前交互模式要求输入 `CONFIRM_FIREWALL`。
- 关闭密码登录时，校验至少保留一条 key 登录通道（admin 公钥或 root key），否则拒绝执行，避免锁死。
- 防火墙模块对 `INPUT` 链是权威式：每次执行会 flush 并按脚本模型重建，手工添加的 INPUT 规则会被清掉。
- 不保存密码、token、cookie、私钥或证书私钥。

## 开发

```bash
bash -n <script>.sh
shellcheck <script>.sh
```
