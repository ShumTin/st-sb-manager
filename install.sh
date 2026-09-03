#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

if [[ ${EUID} -ne 0 ]]; then
  echo "请使用 root 运行：sudo bash $0"
  exit 1
fi

install -d -m 755 /run/lock
exec 9>/run/lock/proxy-manager-install.lock
if ! flock -n 9; then
  echo "已有另一个安装程序正在运行。"
  exit 1
fi

TEMP_SWAP=0
TEMP_SWAP_CREATED=0
BUILD_ROOT=""
INSTALL_SUCCEEDED=0
SING_BOX_WAS_ACTIVE=0
PROXY_MANAGER_WAS_ACTIVE=0
cleanup_build_environment() {
  if [[ "$TEMP_SWAP" == "1" ]] && swapon --show=NAME --noheadings | grep -qx '/swapfile-proxy-build'; then
    if swapoff /swapfile-proxy-build; then
      TEMP_SWAP=0
    fi
  fi
  if [[ "$TEMP_SWAP_CREATED" == "1" ]] && ! swapon --show=NAME --noheadings | grep -qx '/swapfile-proxy-build'; then
    rm -f /swapfile-proxy-build
    TEMP_SWAP_CREATED=0
  fi
  if [[ "$BUILD_ROOT" == /opt/proxy-build.* && -d "$BUILD_ROOT" ]]; then
    rm -rf -- "$BUILD_ROOT"
    BUILD_ROOT=""
  fi
}

cleanup() {
  cleanup_build_environment
  if [[ "$INSTALL_SUCCEEDED" != "1" ]]; then
    if [[ "$SING_BOX_WAS_ACTIVE" == "1" ]]; then
      systemctl start sing-box >/dev/null 2>&1 || true
    fi
    if [[ "$PROXY_MANAGER_WAS_ACTIVE" == "1" ]]; then
      systemctl start proxy-manager >/dev/null 2>&1 || true
    fi
  fi
}

on_exit() {
  local exit_code=$?
  trap - EXIT ERR
  cleanup
  exit "$exit_code"
}

trap on_exit EXIT
trap 'echo "安装在第 ${LINENO} 行失败，请保留终端报错信息。" >&2' ERR

trim_input() {
  local value=${1//$'\r'/}
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s' "$value"
}

show_install_logo() {
  echo '
   ___________   _____ ____
  / ___/_  __/  / ___// __ )
  \__ \ / /_____\__ \/ __  |
 ___/ // /_____/__/ / /_/ /
/____//_/     /____/_____/'
}

show_install_logo
echo
echo "=== 六协议动态用户管理 + 独立流量/到期策略 + 7天域名审计安装程序 ==="
echo "协议：安装后按需启用 VLESS+REALITY、AnyTLS、Hysteria2、Shadowsocks 2022、TUIC v5、Trojan TLS"
echo "说明：首次安装不启用代理协议；重新安装会使旧订阅失效。"
echo
read -r -p "请输入节点域名（例如 node.example.com）: " DOMAIN
read -r -p "请输入用于 Let's Encrypt 的真实邮箱: " EMAIL
read -r -p "请输入 VPS 标称带宽 Mbps（1 Gbps 填 1000，直接回车默认 1000）: " BANDWIDTH
DOMAIN=$(trim_input "$DOMAIN")
EMAIL=$(trim_input "$EMAIL")
BANDWIDTH=$(trim_input "$BANDWIDTH")
BANDWIDTH=${BANDWIDTH:-1000}
DETECTED_SSH_PORT=""
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  DETECTED_SSH_PORT=$(awk '{print $4}' <<<"$SSH_CONNECTION")
fi
if [[ ! "$DETECTED_SSH_PORT" =~ ^[0-9]+$ ]] && command -v sshd >/dev/null 2>&1; then
  DETECTED_SSH_PORT=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}' || true)
fi
if [[ ! "$DETECTED_SSH_PORT" =~ ^[0-9]+$ ]]; then
  DETECTED_SSH_PORT=22
fi
read -r -p "请输入 SSH 端口（已自动识别为 ${DETECTED_SSH_PORT}，直接回车采用）: " SSH_PORT
SSH_PORT=$(trim_input "$SSH_PORT")
SSH_PORT=${SSH_PORT:-$DETECTED_SSH_PORT}
echo
echo "可从 KiwiVM API 获取搬瓦工精确流量重置时间；API Key 仅用于本次查询，不会保存。"
read -r -p "请输入 KiwiVM VEID（直接回车跳过自动同步）: " KIWIVM_VEID
KIWIVM_VEID=$(trim_input "$KIWIVM_VEID")
KIWIVM_API_KEY=""
if [[ -n "$KIWIVM_VEID" ]]; then
  read -r -s -p "请输入 KiwiVM API Key: " KIWIVM_API_KEY
  KIWIVM_API_KEY=${KIWIVM_API_KEY//$'\r'/}
  echo
fi

if [[ ! "$DOMAIN" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]]; then
  echo "域名格式不正确。"
  exit 1
fi
if [[ ! "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
  echo "邮箱格式不正确。"
  exit 1
fi
if [[ ! "$BANDWIDTH" =~ ^[1-9][0-9]*$ ]]; then
  echo "带宽必须是正整数，例如 100 或 1000。"
  exit 1
fi
if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
  echo "SSH 端口必须是 1-65535 的整数。"
  exit 1
fi
if [[ "$SSH_PORT" == "80" || "$SSH_PORT" == "443" || "$SSH_PORT" == "8080" || "$SSH_PORT" == "8787" ]]; then
  echo "SSH 端口与订阅或内部管理端口冲突，请先把 SSH 改到其他端口。"
  exit 1
fi
if [[ -n "$KIWIVM_VEID" && ! "$KIWIVM_VEID" =~ ^[0-9]+$ ]]; then
  echo "KiwiVM VEID 必须是数字。"
  exit 1
fi
if [[ -n "$KIWIVM_VEID" && -z "$KIWIVM_API_KEY" ]]; then
  echo "已填写 VEID 时，API Key 不能为空。"
  exit 1
fi

BACKUP_DIR="/root/proxy-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
for old_path in \
  /etc/sing-box/config.json \
  /etc/nginx/sites-available/proxy-subscription \
  /etc/systemd/system/proxy-hy2-port-hop.service \
  /etc/proxy-manager \
  /var/lib/proxy-manager \
  /opt/proxy-manager \
  /root/node-info.txt \
  /root/proxy-links.txt; do
  if [[ -e "$old_path" ]]; then
    # 重新安装时旧目录可能处于残缺状态；备份失败不应阻止重新安装。
    if ! cp -a --parents -- "$old_path" "$BACKUP_DIR/"; then
      echo "警告：无法备份 $old_path，继续执行重新安装。" >&2
    fi
  fi
done

OLD_REALITY_PORT=""
OLD_ANYTLS_PORT=""
OLD_HY2_PORT=""
OLD_SS2022_PORT=""
OLD_TUIC_PORT=""
OLD_TROJAN_PORT=""
OLD_HY2_HOP_START=""
OLD_HY2_HOP_END=""
if [[ -f /etc/proxy-manager/config.json ]]; then
  mapfile -t OLD_PORT_VALUES < <(python3 - <<'PY' || true
import json

try:
    with open("/etc/proxy-manager/config.json", encoding="utf-8") as handle:
        config = json.load(handle)
        ports = config["ports"]
    for name in ("reality", "anytls", "hysteria2", "shadowsocks2022", "tuic", "trojan"):
        print(ports.get(name, ""))
    print(config.get("hy2_hop_start", ""))
    print(config.get("hy2_hop_end", ""))
except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError):
    pass
PY
  )
  if (( ${#OLD_PORT_VALUES[@]} == 8 )); then
    OLD_REALITY_PORT=${OLD_PORT_VALUES[0]}
    OLD_ANYTLS_PORT=${OLD_PORT_VALUES[1]}
    OLD_HY2_PORT=${OLD_PORT_VALUES[2]}
    OLD_SS2022_PORT=${OLD_PORT_VALUES[3]}
    OLD_TUIC_PORT=${OLD_PORT_VALUES[4]}
    OLD_TROJAN_PORT=${OLD_PORT_VALUES[5]}
    OLD_HY2_HOP_START=${OLD_PORT_VALUES[6]}
    OLD_HY2_HOP_END=${OLD_PORT_VALUES[7]}
  fi
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  curl ca-certificates openssl nginx certbot iproute2 iptables ufw \
  python3 python3-grpcio python3-yaml tzdata
timedatectl set-ntp true || true

PROVIDER_NEXT_RESET=0
if [[ -n "$KIWIVM_VEID" ]]; then
  echo "正在从 KiwiVM API 获取精确流量重置时间……"
  if ! PROVIDER_NEXT_RESET=$(python3 3<<<"${KIWIVM_VEID}"$'\n'"${KIWIVM_API_KEY}" <<'PY'
import json
import os
import sys
import time
import urllib.parse
import urllib.request

credentials = os.fdopen(3).read().splitlines()
if len(credentials) != 2:
    raise SystemExit("KiwiVM 凭据读取失败")
query = urllib.parse.urlencode({"veid": credentials[0], "api_key": credentials[1]})
request = urllib.request.Request(
    "https://api.64clouds.com/v1/getServiceInfo?" + query,
    headers={"User-Agent": "Mozilla/5.0", "Accept": "application/json"},
)
try:
    with urllib.request.urlopen(request, timeout=20) as response:
        data = json.load(response)
except Exception as exc:
    raise SystemExit(f"KiwiVM API 请求失败：{exc}") from exc
if str(data.get("error", "0")) not in {"0", "None"}:
    raise SystemExit("KiwiVM API 返回错误：" + str(data.get("message", data["error"])))
try:
    next_reset = int(data["data_next_reset"])
except (KeyError, TypeError, ValueError) as exc:
    raise SystemExit("KiwiVM API 未返回有效的 data_next_reset") from exc
if next_reset <= int(time.time()):
    raise SystemExit("KiwiVM API 返回的重置时间不在未来")
print(next_reset)
PY
  ); then
    unset KIWIVM_API_KEY
    echo "无法获取搬瓦工流量重置时间，安装终止；请检查 VEID、API Key 和网络。"
    exit 1
  fi
  unset KIWIVM_API_KEY
  PROVIDER_RESET_TEXT=$(PROVIDER_NEXT_RESET="$PROVIDER_NEXT_RESET" python3 <<'PY'
import os
from datetime import datetime
from zoneinfo import ZoneInfo

stamp = int(os.environ["PROVIDER_NEXT_RESET"])
print(datetime.fromtimestamp(stamp, ZoneInfo("America/New_York")).strftime("%Y-%m-%d %H:%M:%S %Z"))
PY
  )
  echo "搬瓦工下次流量重置：${PROVIDER_RESET_TEXT}"
else
  unset KIWIVM_API_KEY
  echo "未同步 KiwiVM；新增用户时将默认使用下一个自然月同一天。"
fi

# 如果 VPS 原本已启用 UFW，先确保 SSH 与证书申请端口立即可达。
ufw allow "${SSH_PORT}/tcp" comment 'SSH - do not delete'
ufw allow 80/tcp comment 'ACME HTTP'
ufw allow 443/tcp comment 'HTTPS subscription'

DNS_IP=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1 {print $1}')
PUBLIC_IP=$(curl -4fsS --max-time 10 https://api.ipify.org || true)
if [[ -z "$DNS_IP" ]]; then
  echo "域名尚未解析到 IPv4 地址，请先添加 A 记录后重试。"
  exit 1
fi
if [[ -n "$PUBLIC_IP" && "$DNS_IP" != "$PUBLIC_IP" ]]; then
  echo "域名解析 IP（$DNS_IP）与本机公网 IP（$PUBLIC_IP）不同。"
  echo "请修正 DNS A 记录并等待生效后重试。"
  exit 1
fi

echo "正在安装 sing-box……"
curl -fsSL https://sing-box.app/install.sh | sh
SB_BIN=$(command -v sing-box)

if ! "$SB_BIN" version 2>/dev/null | grep -q 'with_v2ray_api'; then
  echo "官方二进制未包含流量统计模块，正在自动编译兼容版本（1核1G约需数分钟）……"
  apt-get install -y xz-utils
  MACHINE=$(uname -m)
  case "$MACHINE" in
    x86_64) GO_ARCH=amd64 ;;
    aarch64|arm64) GO_ARCH=arm64 ;;
    *)
      echo "自动编译只支持 amd64/arm64，当前架构：$MACHINE"
      exit 1
      ;;
  esac
  BUILD_ROOT=$(mktemp -d /opt/proxy-build.XXXXXX)
  BUILD_BIN_DIR="$BUILD_ROOT/bin"
  GO_ARCHIVE="$BUILD_ROOT/go.tar.gz"
  BUILD_TMP_DIR="$BUILD_ROOT/tmp"
  BUILD_GO_CACHE="$BUILD_ROOT/go-cache"
  BUILD_GO_PATH="$BUILD_ROOT/go-path"
  BUILD_HOME="$BUILD_ROOT/home"
  mkdir -p "$BUILD_BIN_DIR" "$BUILD_TMP_DIR" "$BUILD_GO_CACHE" "$BUILD_GO_PATH" "$BUILD_HOME"
  TEMP_SWAP_SIZE_MB=0
  if [[ -z "$(swapon --show=NAME --noheadings)" ]]; then
    # 单线程编译在 1 GiB VPS 上只需少量兜底交换空间；固定创建 2 GiB 会先耗尽小磁盘。
    MEMORY_AVAILABLE_MB=$(awk '/MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo)
    if (( MEMORY_AVAILABLE_MB < 1280 )); then
      TEMP_SWAP_SIZE_MB=$((1280 - MEMORY_AVAILABLE_MB))
      if (( TEMP_SWAP_SIZE_MB < 256 )); then
        TEMP_SWAP_SIZE_MB=256
      elif (( TEMP_SWAP_SIZE_MB > 1024 )); then
        TEMP_SWAP_SIZE_MB=1024
      fi
    fi
  fi
  BUILD_FREE_MB=$(df -Pm "$BUILD_ROOT" | awk 'NR == 2 {print $4}')
  BUILD_REQUIRED_MB=$((2300 + TEMP_SWAP_SIZE_MB))
  if (( BUILD_FREE_MB < BUILD_REQUIRED_MB )); then
    echo "可用磁盘空间不足：当前 ${BUILD_FREE_MB} MiB，编译预计至少需要 ${BUILD_REQUIRED_MB} MiB。" >&2
    echo "请清理根分区后重新运行安装程序。" >&2
    exit 1
  fi
  if (( TEMP_SWAP_SIZE_MB > 0 )); then
    fallocate -l "${TEMP_SWAP_SIZE_MB}M" /swapfile-proxy-build
    TEMP_SWAP_CREATED=1
    chmod 600 /swapfile-proxy-build
    mkswap /swapfile-proxy-build >/dev/null
    swapon /swapfile-proxy-build
    TEMP_SWAP=1
  fi
  GO_VERSION=$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1)
  curl -fL "https://go.dev/dl/${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -o "$GO_ARCHIVE"
  tar -C "$BUILD_ROOT" -xzf "$GO_ARCHIVE"
  rm -f "$GO_ARCHIVE"
  SB_VERSION=$($SB_BIN version | awk '/sing-box version/ {gsub(/^v/, "", $3); print $3; exit}')
  if [[ -z "$SB_VERSION" ]]; then
    echo "无法识别 sing-box 版本。"
    exit 1
  fi
  if ! HOME="$BUILD_HOME" TMPDIR="$BUILD_TMP_DIR" \
    GOPATH="$BUILD_GO_PATH" GOMODCACHE="$BUILD_GO_PATH/pkg/mod" GOCACHE="$BUILD_GO_CACHE" \
    GOBIN="$BUILD_BIN_DIR" CGO_ENABLED=0 GOMAXPROCS=1 \
    GOFLAGS='-p=1 -tags=with_quic,with_utls,with_v2ray_api' \
    "$BUILD_ROOT/go/bin/go" install "github.com/sagernet/sing-box/cmd/sing-box@v${SB_VERSION}"; then
    echo "sing-box 编译失败。当前磁盘空间：" >&2
    df -h /opt "$BUILD_TMP_DIR" >&2 || true
    echo "请确保根分区至少有约 3 GiB 可用空间后重新运行安装程序。" >&2
    exit 1
  fi
  install -m 755 "$BUILD_BIN_DIR/sing-box" /usr/local/bin/sing-box
  SB_BIN=/usr/local/bin/sing-box
  cleanup_build_environment
fi

if ! "$SB_BIN" version | grep -q 'with_v2ray_api'; then
  echo "sing-box 流量统计模块仍不可用，安装终止。"
  exit 1
fi

# 安装脚本全局使用 umask 077 保护密钥，但 ACME WebRoot 必须允许 nginx(www-data)读取。
install -d -o root -g root -m 755 \
  /var/www/html \
  /var/www/html/.well-known \
  /var/www/html/.well-known/acme-challenge
rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/sites-available/proxy-subscription <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root /var/www/html;

    location ^~ /.well-known/acme-challenge/ {
        try_files \$uri =404;
    }

    location / {
        return 404;
    }
}
EOF

ln -sfn /etc/nginx/sites-available/proxy-subscription /etc/nginx/sites-enabled/proxy-subscription
nginx -t
systemctl enable --now nginx
systemctl reload nginx

if ! (
  # Certbot 创建的临时验证文件需要能被 nginx worker 读取。
  umask 022
  certbot certonly \
    --webroot \
    --webroot-path /var/www/html \
    --domain "$DOMAIN" \
    --email "$EMAIL" \
    --agree-tos \
    --no-eff-email \
    --non-interactive
); then
  echo ""
  echo "Let's Encrypt 证书申请失败。请确认："
  echo "  1. 服务商安全组已放行 TCP 80（HTTP 验证）和 TCP 443（HTTPS）；"
  echo "  2. 域名 A 记录已解析到本机公网 IPv4；"
  echo "  3. 80/443 端口没有被其他服务占用，且可从公网访问。"
  echo "安全组规则不由 UFW 控制，请在服务商控制台放行后重新运行安装脚本。"
  exit 1
fi

install -d -m 700 /etc/sing-box /etc/proxy-manager /opt/proxy-manager
install -d -m 700 /var/lib/proxy-manager
if systemctl is-active --quiet sing-box 2>/dev/null; then
  SING_BOX_WAS_ACTIVE=1
fi
if systemctl is-active --quiet proxy-manager 2>/dev/null; then
  PROXY_MANAGER_WAS_ACTIVE=1
fi
systemctl stop proxy-manager sing-box 2>/dev/null || true
systemctl disable --now proxy-hy2-port-hop 2>/dev/null || true
rm -f /etc/systemd/system/proxy-hy2-port-hop.service
systemctl daemon-reload
rm -f /var/lib/proxy-manager/usage.db /var/lib/proxy-manager/usage.db-shm /var/lib/proxy-manager/usage.db-wal
rm -f /var/lib/proxy-manager/audit.db /var/lib/proxy-manager/audit.db-shm /var/lib/proxy-manager/audit.db-wal

DOMAIN="$DOMAIN" BANDWIDTH="$BANDWIDTH" SSH_PORT="$SSH_PORT" BACKUP_DIR="$BACKUP_DIR" SB_BIN="$SB_BIN" PROVIDER_NEXT_RESET="$PROVIDER_NEXT_RESET" python3 <<'PY'
import json
import os
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

domain = os.environ["DOMAIN"]
bandwidth = int(os.environ["BANDWIDTH"])
ssh_port = int(os.environ["SSH_PORT"])
backup_dir = os.environ["BACKUP_DIR"]
sb_bin = os.environ["SB_BIN"]
provider_next_reset = int(os.environ["PROVIDER_NEXT_RESET"])
billing_timezone = "America/New_York"

users = []
ports = {}

cert = f"/etc/letsencrypt/live/{domain}/fullchain.pem"
key = f"/etc/letsencrypt/live/{domain}/privkey.pem"
tls = {
    "enabled": True,
    "server_name": domain,
    "min_version": "1.2",
    "certificate_path": cert,
    "key_path": key,
}

inbounds = []
audit_outbounds = [{"type": "direct", "tag": "direct-out"}]
audit_route_rules = []

singbox_config = {
    "log": {"level": "info", "timestamp": True},
    "inbounds": inbounds,
    "outbounds": audit_outbounds,
    "route": {"rules": audit_route_rules},
    "experimental": {
        "v2ray_api": {
            "listen": "127.0.0.1:8080",
            "stats": {
                "enabled": True,
                "inbounds": [item["tag"] for item in inbounds],
                "users": [u["name"] for u in users],
            },
        }
    },
}

manager_config = {
    "domain": domain,
    "timezone": "Asia/Shanghai",
    "billing_timezone": billing_timezone,
    "provider_next_reset": provider_next_reset,
    "bandwidth_mbps": bandwidth,
    "ssh_port": ssh_port,
    "audit_retention_days": 7,
    "grpc_address": "127.0.0.1:8080",
    "http_address": "127.0.0.1",
    "http_port": 8787,
    "singbox_binary": sb_bin,
    "singbox_config": "/etc/sing-box/config.json",
    "ports": ports,
    "enabled_protocols": [],
    "users": users,
}

Path("/etc/sing-box/config.json").write_text(json.dumps(singbox_config, ensure_ascii=False, indent=2) + "\n")
Path("/etc/proxy-manager/config.json").write_text(json.dumps(manager_config, ensure_ascii=False, indent=2) + "\n")

info = [
    f"域名: {domain}",
    "协议管理: 安装后运行 proxy 并选择 1，按需启用或删除协议",
    "用户管理: 启用协议后运行 proxy，选择 2 进入用户管理，再选择新增、修改限额或查看状态",
    "⚠️ 流量额度按服务商双向流量（入站 + 出站）口径统计；设置额度时直接填写服务商套餐 GiB，无需除以二",
    "套餐策略: 每个用户独立设置流量、到期时间和自动续期",
    "计费时区: America/New_York（与搬瓦工计费周期一致）",
    "搬瓦工下次流量重置: " + (
        datetime.fromtimestamp(provider_next_reset, ZoneInfo(billing_timezone)).strftime("%Y-%m-%d %H:%M:%S %Z")
        if provider_next_reset else "未通过 KiwiVM API 同步"
    ),
    "超额或到期处理: 自动停用；自动续期用户按自然月顺延并重置流量",
    "访问审计: 仅记录用户、协议、目标域名/IP、端口、网络类型和时间",
    "审计保留: 滚动保留7天；不保存来源IP、URL路径、查询参数或网页内容",
    f"Hysteria2 带宽参数: {bandwidth} Mbps",
    f"安装前配置备份: {backup_dir}",
    f"SSH端口: {ssh_port}/TCP（UFW已放行）",
    "",
    "云服务商安全组需要放行：",
    "TCP 80     Let's Encrypt 申请与续期",
    "TCP 443    HTTPS 订阅",
    "代理协议端口: 尚未启用；安装后运行 proxy 并进入协议管理",
]
info += [
    "",
    "日常管理命令：",
    "proxy                              打开交互式管理菜单",
    "proxy-protocol                     启用或删除代理协议",
    "proxy-update                       安全更新管理程序",
    "proxy-user-add                     新增用户",
    "proxy-user-status                  查看所有用户状态",
    "",
    "格式强制参数（通常无需使用）：",
    "?target=mihomo   Clash/Mihomo YAML",
    "?target=base64   v2rayN/Shadowrocket Base64",
    "?target=quanx    Quantumult X",
    "",
    "审计查询命令：",
    "proxy-audit                         最近24小时记录",
    "proxy-audit --user alice --days 7   指定用户最近7天记录",
    "proxy-audit --summary --days 7      最近7天域名汇总",
    "",
    "请明确告知所有使用者已启用域名/IP级访问审计。",
    "严禁把 /etc/proxy-manager/config.json 发给他人，其中包含全部服务端密钥。",
]
Path("/root/node-info.txt").write_text("\n".join(info) + "\n")
PY

chmod 600 /etc/sing-box/config.json /etc/proxy-manager/config.json /root/node-info.txt

cat > /opt/proxy-manager/manager.py <<'PY'
#!/usr/bin/env python3
import base64
import calendar
import json
import os
import re
import sqlite3
import subprocess
import tempfile
import threading
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlparse
from zoneinfo import ZoneInfo

import grpc
import yaml

CONFIG_PATH = Path("/etc/proxy-manager/config.json")
DB_PATH = "/var/lib/proxy-manager/usage.db"
CONFIG = json.loads(CONFIG_PATH.read_text())
TZ = ZoneInfo(CONFIG["timezone"])
BILLING_TZ = ZoneInfo(CONFIG.get("billing_timezone", CONFIG["timezone"]))
LOCK = threading.RLock()
USERS_BY_TOKEN = {u["token"]: u for u in CONFIG["users"]}
USERS_BY_NAME = {u["name"]: u for u in CONFIG["users"]}
# 服务商按入站+出站计费；sing-box 用户统计只记录代理侧的一次传输。
TRAFFIC_ACCOUNTING_VERSION = 2
TRAFFIC_ACCOUNTING_FACTOR = 2

def db():
    conn = sqlite3.connect(DB_PATH, timeout=20)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=FULL")
    return conn

def init_db():
    with db() as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS usage (
                name TEXT PRIMARY KEY,
                upload INTEGER NOT NULL DEFAULT 0,
                download INTEGER NOT NULL DEFAULT 0,
                period TEXT NOT NULL,
                blocked INTEGER NOT NULL DEFAULT 0,
                blocked_reason TEXT NOT NULL DEFAULT '',
                last_upload INTEGER NOT NULL DEFAULT 0,
                last_download INTEGER NOT NULL DEFAULT 0,
                accounting_version INTEGER NOT NULL DEFAULT 2
            )
        """)
        columns = {row[1] for row in conn.execute("PRAGMA table_info(usage)")}
        if "blocked_reason" not in columns:
            conn.execute("ALTER TABLE usage ADD COLUMN blocked_reason TEXT NOT NULL DEFAULT ''")
        if "last_upload" not in columns:
            conn.execute("ALTER TABLE usage ADD COLUMN last_upload INTEGER NOT NULL DEFAULT 0")
        if "last_download" not in columns:
            conn.execute("ALTER TABLE usage ADD COLUMN last_download INTEGER NOT NULL DEFAULT 0")
        if "accounting_version" not in columns:
            conn.execute("ALTER TABLE usage ADD COLUMN accounting_version INTEGER NOT NULL DEFAULT 1")
        # 旧版本按单向流量累计；迁移后与服务商双向计费口径一致。
        conn.execute(
            "UPDATE usage SET upload=upload*?, download=download*?, accounting_version=? "
            "WHERE accounting_version<?",
            (TRAFFIC_ACCOUNTING_FACTOR, TRAFFIC_ACCOUNTING_FACTOR,
             TRAFFIC_ACCOUNTING_VERSION, TRAFFIC_ACCOUNTING_VERSION),
        )
        period = datetime.now(TZ).strftime("%Y-%m-%d")
        for name in USERS_BY_NAME:
            conn.execute(
                "INSERT OR IGNORE INTO usage(name, upload, download, period, blocked, accounting_version) VALUES(?,0,0,?,0,?)",
                (name, period, TRAFFIC_ACCOUNTING_VERSION),
            )

def read_varint(data, pos):
    value = 0
    shift = 0
    while pos < len(data):
        byte = data[pos]
        pos += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, pos
        shift += 7
        if shift > 70:
            raise ValueError("invalid protobuf varint")
    raise ValueError("truncated protobuf varint")

def parse_stat(message):
    pos = 0
    name = ""
    value = 0
    while pos < len(message):
        key, pos = read_varint(message, pos)
        field = key >> 3
        wire = key & 7
        if wire == 2:
            length, pos = read_varint(message, pos)
            item = message[pos:pos + length]
            pos += length
            if field == 1:
                name = item.decode("utf-8", "replace")
        elif wire == 0:
            item, pos = read_varint(message, pos)
            if field == 2:
                value = item
        elif wire == 1:
            pos += 8
        elif wire == 5:
            pos += 4
        else:
            raise ValueError("unsupported protobuf wire type")
    return name, value

def parse_stats_response(data):
    pos = 0
    stats = {}
    while pos < len(data):
        key, pos = read_varint(data, pos)
        field = key >> 3
        wire = key & 7
        if wire == 2:
            length, pos = read_varint(data, pos)
            item = data[pos:pos + length]
            pos += length
            if field == 1:
                name, value = parse_stat(item)
                if name:
                    stats[name] = value
        elif wire == 0:
            _, pos = read_varint(data, pos)
        elif wire == 1:
            pos += 8
        elif wire == 5:
            pos += 4
        else:
            raise ValueError("unsupported protobuf wire type")
    return stats

def query_stats():
    channel = grpc.insecure_channel(CONFIG["grpc_address"])
    call = channel.unary_unary(
        "/v2ray.core.app.stats.command.StatsService/QueryStats",
        request_serializer=lambda value: value,
        response_deserializer=lambda value: value,
    )
    try:
        # 不清空 sing-box 累计计数；只有数据库提交成功后才推进本地检查点。
        response = call(b"", timeout=4)
        return parse_stats_response(response)
    finally:
        channel.close()

def write_text_atomic(path, text):
    fd, temp_path = tempfile.mkstemp(prefix=f"{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp_path, 0o600)
        os.replace(temp_path, path)
    except Exception:
        try:
            os.unlink(temp_path)
        except FileNotFoundError:
            pass
        raise


def apply_blocking(blocked_names):
    path = Path(CONFIG["singbox_config"])
    original_text = path.read_text()
    data = json.loads(original_text)
    rules = []
    if blocked_names:
        rules.append({"auth_user": sorted(blocked_names), "action": "reject"})
    rules.extend(
        {"auth_user": [name], "action": "route", "outbound": f"audit-{name}-out"}
        for name in USERS_BY_NAME
    )
    data.setdefault("route", {})["rules"] = rules
    new_text = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    if new_text == original_text:
        return
    fd, temp_path = tempfile.mkstemp(prefix="config-check.", suffix=".json", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as handle:
            handle.write(new_text)
            handle.flush()
            os.fsync(handle.fileno())
        subprocess.run(
            [CONFIG["singbox_binary"], "check", "-c", temp_path],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
        )
        os.unlink(temp_path)
        write_text_atomic(path, new_text)
        subprocess.run(["systemctl", "restart", "sing-box"], check=True, timeout=30)
    except Exception:
        try:
            os.unlink(temp_path)
        except FileNotFoundError:
            pass
        # 配置已替换但服务重启失败时恢复旧文件，使下一轮仍会重试封禁变更。
        if path.read_text() == new_text:
            write_text_atomic(path, original_text)
            subprocess.run(["systemctl", "restart", "sing-box"], check=False, timeout=30)
        raise

def save_manager_config():
    text = json.dumps(CONFIG, ensure_ascii=False, indent=2) + "\n"
    write_text_atomic(CONFIG_PATH, text)

def add_calendar_months(value, months, anchor_day):
    month_index = value.year * 12 + value.month - 1 + months
    year, month_zero_based = divmod(month_index, 12)
    month = month_zero_based + 1
    day = min(anchor_day, calendar.monthrange(year, month)[1])
    return value.replace(year=year, month=month, day=day)

def renew_expired_users(now_ts):
    renewed = {}
    now = datetime.fromtimestamp(now_ts, BILLING_TZ)
    for user in USERS_BY_NAME.values():
        expiry = datetime.fromtimestamp(int(user["expires_at"]), BILLING_TZ)
        if expiry > now or not user["auto_renew"]:
            continue
        renewal_months = int(user["renewal_months"])
        anchor_day = int(user["renewal_day"])
        while expiry <= now:
            expiry = add_calendar_months(expiry, renewal_months, anchor_day)
        renewed[user["name"]] = int(expiry.timestamp())
    if not renewed:
        return
    with db() as conn:
        old_expiries = {name: USERS_BY_NAME[name]["expires_at"] for name in renewed}
        try:
            for name, expires_at in renewed.items():
                USERS_BY_NAME[name]["expires_at"] = expires_at
                conn.execute(
                    "UPDATE usage SET upload=0, download=0, blocked=0, blocked_reason='', period=? WHERE name=?",
                    (datetime.now(TZ).strftime("%Y-%m-%d"), name),
                )
            save_manager_config()
            conn.commit()
        except Exception:
            conn.rollback()
            for name, expires_at in old_expiries.items():
                USERS_BY_NAME[name]["expires_at"] = expires_at
            save_manager_config()
            raise

STAT_PATTERN = re.compile(r"^user>>>([^>]+)>>>traffic>>>(uplink|downlink)$")

def collect_once():
    with LOCK:
        now_ts = int(datetime.now(TZ).timestamp())
        renew_expired_users(now_ts)
        stats = query_stats()
        counters = {name: {"uplink": 0, "downlink": 0} for name in USERS_BY_NAME}
        for stat_name, value in stats.items():
            match = STAT_PATTERN.match(stat_name)
            if match and match.group(1) in counters:
                counters[match.group(1)][match.group(2)] += max(0, int(value))
        with db() as conn:
            rows_by_name = {
                row["name"]: row
                for row in conn.execute(
                    "SELECT name,upload,download,blocked,last_upload,last_download FROM usage"
                )
            }
            for name, parts in counters.items():
                row = rows_by_name.get(name)
                if row is None:
                    continue
                current_upload = parts["uplink"]
                current_download = parts["downlink"]
                upload_delta = current_upload - row["last_upload"] if current_upload >= row["last_upload"] else current_upload
                download_delta = current_download - row["last_download"] if current_download >= row["last_download"] else current_download
                conn.execute(
                    "UPDATE usage SET upload=upload+?, download=download+?, last_upload=?, last_download=? WHERE name=?",
                    (upload_delta * TRAFFIC_ACCOUNTING_FACTOR, download_delta * TRAFFIC_ACCOUNTING_FACTOR,
                     current_upload, current_download, name),
                )
            rows = conn.execute("SELECT name, upload, download, blocked FROM usage").fetchall()
            for row in rows:
                user = USERS_BY_NAME.get(row["name"])
                if user is None:
                    continue
                expired = now_ts >= int(user["expires_at"])
                quota_exhausted = row["upload"] + row["download"] >= int(user["quota_bytes"])
                blocked = expired or quota_exhausted
                reason = "已到期" if expired else ("流量已用完" if quota_exhausted else "")
                conn.execute(
                    "UPDATE usage SET blocked=?, blocked_reason=? WHERE name=?",
                    (int(blocked), reason, row["name"]),
                )
            blocked = {row[0] for row in conn.execute("SELECT name FROM usage WHERE blocked=1")}
        # 每轮都核对封禁规则；如果上一次重启失败，下一轮会自动重试。
        apply_blocking(blocked)

def collector_loop():
    while True:
        try:
            collect_once()
        except Exception as exc:
            print(f"traffic collector error: {exc}", flush=True)
        time.sleep(5)

def usage_for(name):
    with LOCK:
        renew_expired_users(int(datetime.now(TZ).timestamp()))
        with db() as conn:
            row = conn.execute("SELECT * FROM usage WHERE name=?", (name,)).fetchone()
            return dict(row)

def status_names(user, row):
    used = int(row["upload"]) + int(row["download"])
    remaining = max(0, int(user["quota_bytes"]) - used)
    gib = remaining / (1024 ** 3)
    expiry = datetime.fromtimestamp(int(user["expires_at"]), BILLING_TZ)
    state = row["blocked_reason"] if row["blocked"] else "可用"
    renewal = "自动续期" if user["auto_renew"] else "到期停用"
    return f"剩余流量：{gib:.1f} GiB（{state}）", f"有效期：{expiry:%Y-%m-%d}（{renewal}）"

def uri_links(user, row):
    d = CONFIG["domain"]
    p = CONFIG["ports"]
    enabled = set(CONFIG.get("enabled_protocols", p))
    name1, name2 = status_names(user, row)
    def tag(value):
        return quote(value, safe="")
    links = []
    if "reality" in enabled:
        links.append(f"vless://{user['vless_reality_uuid']}@{d}:{p['reality']}?encryption=none&flow=xtls-rprx-vision&security=reality&sni={CONFIG['reality_server']}&fp=chrome&pbk={CONFIG['reality_public_key']}&sid={CONFIG['reality_short_id']}&type=tcp#{tag('VLESS-REALITY')}")
    if "anytls" in enabled:
        links.append(f"anytls://{quote(user['anytls_password'], safe='')}@{d}:{p['anytls']}?security=tls&sni={d}&fp=chrome&type=tcp#{tag('AnyTLS')}")
    if "hysteria2" in enabled:
        hy2_query = f"sni={d}&obfs=salamander&obfs-password={quote(CONFIG['hy2_obfs_password'], safe='')}"
        if "hy2_hop_start" in CONFIG:
            hy2_query += f"&mport={CONFIG['hy2_hop_start']}-{CONFIG['hy2_hop_end']}"
        links.append(f"hysteria2://{quote(user['hy2_password'], safe='')}@{d}:{p['hysteria2']}/?{hy2_query}#{tag('Hysteria2')}")
    if "shadowsocks2022" in enabled:
        password = f"{CONFIG['ss2022_server_password']}:{user['ss2022_password']}"
        userinfo = base64.urlsafe_b64encode(
            f"2022-blake3-aes-128-gcm:{password}".encode()
        ).decode().rstrip("=")
        links.append(f"ss://{userinfo}@{d}:{p['shadowsocks2022']}#{tag('Shadowsocks 2022')}")
    if "tuic" in enabled:
        links.append(f"tuic://{user['tuic_uuid']}:{quote(user['tuic_password'], safe='')}@{d}:{p['tuic']}?sni={d}&alpn=h3&congestion_control=cubic&udp_relay_mode=native#{tag('TUIC v5')}")
    if "trojan" in enabled:
        links.append(f"trojan://{quote(user['trojan_password'], safe='')}@{d}:{p['trojan']}?security=tls&sni={d}&type=tcp#{tag('Trojan TLS')}")
    dummy = "00000000-0000-0000-0000-000000000000"
    links.insert(0, f"vless://{dummy}@127.0.0.1:1?encryption=none&security=none&type=tcp#{tag(name1)}")
    links.insert(1, f"vless://{dummy}@127.0.0.1:2?encryption=none&security=none&type=tcp#{tag(name2)}")
    return links

def base64_subscription(user, row):
    text = "\n".join(uri_links(user, row)) + "\n"
    return base64.b64encode(text.encode()).decode() + "\n"

def mihomo_subscription(user, row):
    d = CONFIG["domain"]
    p = CONFIG["ports"]
    enabled = set(CONFIG.get("enabled_protocols", p))
    info1, info2 = status_names(user, row)
    actual = []
    if "reality" in enabled:
        actual.append({
            "name": "VLESS-REALITY", "type": "vless", "server": d, "port": p["reality"],
            "uuid": user["vless_reality_uuid"], "network": "tcp", "tls": True, "udp": True,
            "flow": "xtls-rprx-vision", "servername": CONFIG["reality_server"], "client-fingerprint": "chrome",
            "reality-opts": {"public-key": CONFIG["reality_public_key"], "short-id": CONFIG["reality_short_id"]},
        })
    if "anytls" in enabled:
        actual.append({
            "name": "AnyTLS", "type": "anytls", "server": d, "port": p["anytls"],
            "password": user["anytls_password"], "sni": d, "udp": True,
            "skip-cert-verify": False, "client-fingerprint": "chrome",
        })
    if "hysteria2" in enabled:
        hysteria2 = {
            "name": "Hysteria2", "type": "hysteria2", "server": d, "port": p["hysteria2"],
            "password": user["hy2_password"], "sni": d, "skip-cert-verify": False,
            "obfs": "salamander", "obfs-password": CONFIG["hy2_obfs_password"],
        }
        if "hy2_hop_start" in CONFIG:
            hysteria2["ports"] = f"{CONFIG['hy2_hop_start']}-{CONFIG['hy2_hop_end']}"
            hysteria2["hop-interval"] = int(CONFIG["hy2_hop_interval"])
        actual.append(hysteria2)
    if "shadowsocks2022" in enabled:
        actual.append({
            "name": "Shadowsocks 2022", "type": "ss", "server": d,
            "port": p["shadowsocks2022"], "cipher": "2022-blake3-aes-128-gcm",
            "password": f"{CONFIG['ss2022_server_password']}:{user['ss2022_password']}",
            "udp": True, "udp-over-tcp": True, "udp-over-tcp-version": 2,
        })
    if "tuic" in enabled:
        actual.append({
            "name": "TUIC v5", "type": "tuic", "server": d, "port": p["tuic"],
            "uuid": user["tuic_uuid"], "password": user["tuic_password"], "sni": d,
            "skip-cert-verify": False, "congestion-controller": "cubic",
            "udp-relay-mode": "native", "reduce-rtt": False,
        })
    if "trojan" in enabled:
        actual.append({
            "name": "Trojan TLS", "type": "trojan", "server": d, "port": p["trojan"],
            "password": user["trojan_password"], "sni": d, "skip-cert-verify": False,
            "udp": True, "network": "tcp",
        })
    info = [
        {"name": info1, "type": "ss", "server": "127.0.0.1", "port": 1, "cipher": "aes-128-gcm", "password": "info-only"},
        {"name": info2, "type": "ss", "server": "127.0.0.1", "port": 2, "cipher": "aes-128-gcm", "password": "info-only"},
    ]
    names = [item["name"] for item in actual]
    groups = [{"name": "套餐信息", "type": "select", "proxies": [info1, info2]}]
    rules = ["MATCH,DIRECT"]
    if names:
        groups = [
            {"name": "节点选择", "type": "select", "proxies": ["自动选择"] + names},
            {"name": "自动选择", "type": "url-test", "proxies": names, "url": "https://www.gstatic.com/generate_204", "interval": 300},
        ] + groups
        rules = ["MATCH,节点选择"]
    config = {
        "mixed-port": 7890,
        "allow-lan": False,
        "mode": "rule",
        "log-level": "info",
        "ipv6": True,
        "proxies": info + actual,
        "proxy-groups": groups,
        "rules": rules,
    }
    return yaml.safe_dump(config, allow_unicode=True, sort_keys=False)

def quanx_subscription(user, row):
    d = CONFIG["domain"]
    p = CONFIG["ports"]
    enabled = set(CONFIG.get("enabled_protocols", p))
    info1, info2 = status_names(user, row)
    lines = [
        f"shadowsocks=127.0.0.1:1, method=aes-128-gcm, password=info-only, udp-relay=false, tag={info1}",
        f"shadowsocks=127.0.0.1:2, method=aes-128-gcm, password=info-only, udp-relay=false, tag={info2}",
    ]
    if "reality" in enabled:
        lines.append(f"vless={d}:{p['reality']}, method=none, password={user['vless_reality_uuid']}, obfs=over-tls, obfs-host={CONFIG['reality_server']}, reality-base64-pubkey={CONFIG['reality_public_key']}, reality-hex-shortid={CONFIG['reality_short_id']}, vless-flow=xtls-rprx-vision, udp-relay=true, tag=VLESS-REALITY")
    if "anytls" in enabled:
        lines.append(f"anytls={d}:{p['anytls']}, password={user['anytls_password']}, over-tls=true, tls-host={d}, tls-verification=true, udp-relay=true, tag=AnyTLS")
    if "hysteria2" in enabled:
        lines.append("shadowsocks=127.0.0.1:3, method=aes-128-gcm, password=unsupported, udp-relay=false, tag=Hysteria2（QuanX不支持）")
    if "shadowsocks2022" in enabled:
        lines.append("shadowsocks=127.0.0.1:4, method=aes-128-gcm, password=unsupported, udp-relay=false, tag=Shadowsocks 2022（QuanX不支持）")
    if "tuic" in enabled:
        lines.append("shadowsocks=127.0.0.1:5, method=aes-128-gcm, password=unsupported, udp-relay=false, tag=TUIC v5（QuanX不支持）")
    if "trojan" in enabled:
        lines.append(f"trojan={d}:{p['trojan']}, password={user['trojan_password']}, over-tls=true, tls-host={d}, tls-verification=true, fast-open=false, udp-relay=true, tag=Trojan TLS")
    return "\n".join(lines) + "\n"

class Handler(BaseHTTPRequestHandler):
    server_version = "SubscriptionService/1.0"

    def log_message(self, fmt, *args):
        return

    def do_HEAD(self):
        self.respond(send_body=False)

    def do_GET(self):
        self.respond(send_body=True)

    def respond(self, send_body):
        parsed = urlparse(self.path)
        parts = parsed.path.strip("/").split("/")
        if len(parts) != 2 or parts[0] != "sub" or parts[1] not in USERS_BY_TOKEN:
            self.send_response(404)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return
        user = USERS_BY_TOKEN[parts[1]]
        row = usage_for(user["name"])
        target = parse_qs(parsed.query).get("target", [""])[0].lower()
        ua = self.headers.get("User-Agent", "").lower()
        if target in {"mihomo", "clash"} or (not target and any(x in ua for x in ("clash", "mihomo", "stash"))):
            body = mihomo_subscription(user, row)
            content_type = "text/yaml; charset=utf-8"
        elif target in {"quanx", "quantumultx", "quantumult-x"} or (not target and "quantumult" in ua):
            body = quanx_subscription(user, row)
            content_type = "text/plain; charset=utf-8"
        else:
            body = base64_subscription(user, row)
            content_type = "text/plain; charset=utf-8"
        payload = body.encode("utf-8")
        quota = int(user["quota_bytes"])
        expire_ts = int(user["expires_at"])
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Subscription-Userinfo", f"upload={row['upload']}; download={row['download']}; total={quota}; expire={expire_ts}")
        self.send_header("Profile-Update-Interval", "1")
        self.send_header("Profile-Title", f"ST-SB-{user['label']}")
        self.end_headers()
        if send_body:
            self.wfile.write(payload)

def main():
    init_db()
    thread = threading.Thread(target=collector_loop, daemon=True)
    thread.start()
    server = ThreadingHTTPServer((CONFIG["http_address"], int(CONFIG["http_port"])), Handler)
    server.serve_forever()

if __name__ == "__main__":
    main()
PY
chmod 700 /opt/proxy-manager/manager.py

cat > /usr/local/sbin/proxy-user-add <<'PY'
#!/usr/bin/env python3
import argparse
import base64
import calendar
import fcntl
import json
import os
import re
import secrets
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime, time
from decimal import Decimal, InvalidOperation
from pathlib import Path
from zoneinfo import ZoneInfo

MANAGER_CONFIG_PATH = Path("/etc/proxy-manager/config.json")
SINGBOX_CONFIG_PATH = Path("/etc/sing-box/config.json")
USAGE_DB_PATH = Path("/var/lib/proxy-manager/usage.db")
LOCK_PATH = Path("/var/lib/proxy-manager/user-admin.lock")
NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_-]{0,31}$")


class UserInput:
    def __init__(self):
        parser = argparse.ArgumentParser(description="新增独立套餐的代理用户")
        parser.add_argument("--name", help="用户名：字母开头，仅限字母、数字、下划线、连字符")
        parser.add_argument("--quota-gib", help="本有效期服务商双向流量额度，单位 GiB")
        parser.add_argument("--expires", help="自定义到期日期，格式 YYYY-MM-DD；省略时优先采用搬瓦工重置时间")
        parser.add_argument("--auto-renew", choices=("yes", "no"), help="到期后是否自动续期")
        parser.add_argument("--renewal-months", type=int, help="每次自动续期的自然月数，默认1个月")
        self.args = parser.parse_args()

    @staticmethod
    def prompt(value, message):
        return value if value is not None else input(message).strip()

    @staticmethod
    def next_month(current_date):
        year = current_date.year + (1 if current_date.month == 12 else 0)
        month = 1 if current_date.month == 12 else current_date.month + 1
        day = min(current_date.day, calendar.monthrange(year, month)[1])
        return current_date.replace(year=year, month=month, day=day)

    @staticmethod
    def add_calendar_months(value, months, anchor_day):
        month_index = value.year * 12 + value.month - 1 + months
        year, month_zero_based = divmod(month_index, 12)
        month = month_zero_based + 1
        day = min(anchor_day, calendar.monthrange(year, month)[1])
        return value.replace(year=year, month=month, day=day)

    def default_expiry(self, timezone, provider_next_reset):
        now = datetime.now(timezone)
        if provider_next_reset:
            expiry = datetime.fromtimestamp(int(provider_next_reset), timezone)
            anchor_day = expiry.day
            while expiry <= now:
                expiry = self.add_calendar_months(expiry, 1, anchor_day)
            return expiry
        expiry_date = self.next_month(now.date())
        return datetime.combine(expiry_date, time(23, 59, 59), timezone)

    def read(self, timezone, provider_next_reset):
        name = self.prompt(self.args.name, "用户名: ")
        print("⚠️ 流量额度按服务商双向流量（入站 + 出站）统计，请直接填写服务商套餐额度。")
        quota_text = self.prompt(self.args.quota_gib, "服务商双向流量额度 GiB（例如 200）: ")
        default_expiry = self.default_expiry(timezone, provider_next_reset)
        expires_text = self.prompt(
            self.args.expires,
            f"到期日期 YYYY-MM-DD（直接回车对齐 {default_expiry.strftime('%Y-%m-%d %H:%M:%S %Z')}）: ",
        )
        auto_text = self.prompt(self.args.auto_renew, "到期后自动续期？[y/N]: ").lower()
        if auto_text not in {"", "y", "yes", "n", "no"}:
            raise ValueError("自动续期只能输入 y/yes 或 n/no")
        auto_renew = auto_text in {"y", "yes"}
        renewal_months = 0
        if auto_renew:
            renewal_text = self.prompt(
                str(self.args.renewal_months) if self.args.renewal_months is not None else None,
                "每次续期自然月数（直接回车默认1）: ",
            ) or "1"
            try:
                renewal_months = int(renewal_text)
            except ValueError as exc:
                raise ValueError("续期月数必须是正整数") from exc
            if renewal_months < 1 or renewal_months > 120:
                raise ValueError("续期月数必须在 1-120 个月之间")
        if not NAME_RE.fullmatch(name):
            raise ValueError("用户名必须以字母开头，且只能包含字母、数字、下划线、连字符，最长32位")
        try:
            quota_gib = Decimal(quota_text)
        except InvalidOperation as exc:
            raise ValueError("流量额度必须是数字") from exc
        if quota_gib <= 0 or quota_gib > Decimal("1048576"):
            raise ValueError("流量额度必须大于0且不超过1048576 GiB")
        if expires_text:
            try:
                expiry_date = datetime.strptime(expires_text, "%Y-%m-%d").date()
            except ValueError as exc:
                raise ValueError("到期日期格式必须为 YYYY-MM-DD") from exc
            expires_at = datetime.combine(expiry_date, time(23, 59, 59), timezone)
        else:
            expires_at = default_expiry
        if expires_at <= datetime.now(timezone):
            raise ValueError("到期日期必须晚于当前时间")
        return {
            "name": name,
            "quota_bytes": int(quota_gib * 1024 ** 3),
            "expires_at": int(expires_at.timestamp()),
            "auto_renew": auto_renew,
            "renewal_months": renewal_months,
            "renewal_day": expires_at.day,
        }


class ProxyUserManager:
    def __init__(self):
        self.manager_config = json.loads(MANAGER_CONFIG_PATH.read_text())
        self.timezone = ZoneInfo(self.manager_config["timezone"])
        self.billing_timezone = ZoneInfo(self.manager_config.get("billing_timezone", self.manager_config["timezone"]))
        self.singbox_binary = self.manager_config["singbox_binary"]

    def create_credentials(self, values):
        user = {
            **values,
            "label": values["name"],
            "token": secrets.token_hex(32),
        }
        enabled = set(self.manager_config.get("enabled_protocols", self.manager_config["ports"]))
        if "reality" in enabled:
            user["vless_reality_uuid"] = str(uuid.uuid4())
        if "anytls" in enabled:
            user["anytls_password"] = secrets.token_hex(16)
        if "hysteria2" in enabled:
            user["hy2_password"] = secrets.token_hex(16)
        if "shadowsocks2022" in enabled:
            user["ss2022_password"] = base64.b64encode(secrets.token_bytes(16)).decode()
        if "tuic" in enabled:
            user["tuic_uuid"] = str(uuid.uuid4())
            user["tuic_password"] = secrets.token_hex(16)
        if "trojan" in enabled:
            user["trojan_password"] = secrets.token_hex(16)
        return user

    def ensure_unique(self, name):
        if any(user["name"] == name for user in self.manager_config["users"]):
            raise ValueError(f"用户 {name} 已存在")

    def build_singbox_config(self):
        config = self.manager_config
        users = config["users"]
        domain = config["domain"]
        ports = config["ports"]
        enabled = set(config.get("enabled_protocols", ports))
        tls = {
            "enabled": True,
            "server_name": domain,
            "min_version": "1.2",
            "certificate_path": f"/etc/letsencrypt/live/{domain}/fullchain.pem",
            "key_path": f"/etc/letsencrypt/live/{domain}/privkey.pem",
        }
        inbounds = []
        if "reality" in enabled:
            inbounds.append({
                "type": "vless", "tag": "vless-reality-in", "listen": "0.0.0.0",
                "listen_port": ports["reality"],
                "users": [{"name": u["name"], "uuid": u["vless_reality_uuid"], "flow": "xtls-rprx-vision"} for u in users],
                "tls": {
                    "enabled": True,
                    "server_name": config["reality_server"],
                    "reality": {
                        "enabled": True,
                        "handshake": {"server": config["reality_server"], "server_port": 443},
                        "private_key": config["reality_private_key"],
                        "short_id": [config["reality_short_id"]],
                    },
                },
            })
        if "anytls" in enabled:
            inbounds.append({
                "type": "anytls", "tag": "anytls-in", "listen": "0.0.0.0",
                "listen_port": ports["anytls"],
                "users": [{"name": u["name"], "password": u["anytls_password"]} for u in users],
                "tls": tls,
            })
        if "hysteria2" in enabled:
            inbounds.append({
                "type": "hysteria2", "tag": "hysteria2-in", "listen": "0.0.0.0",
                "listen_port": ports["hysteria2"],
                "up_mbps": config["bandwidth_mbps"], "down_mbps": config["bandwidth_mbps"],
                "obfs": {"type": "salamander", "password": config["hy2_obfs_password"]},
                "users": [{"name": u["name"], "password": u["hy2_password"]} for u in users],
                "tls": tls,
                "masquerade": {
                    "type": "string", "status_code": 404,
                    "headers": {"content-type": "text/html; charset=utf-8"},
                    "content": "<html><head><title>404 Not Found</title></head><body><h1>404 Not Found</h1></body></html>",
                },
            })
        if "shadowsocks2022" in enabled:
            inbounds.append({
                "type": "shadowsocks", "tag": "shadowsocks2022-in", "listen": "0.0.0.0",
                "listen_port": ports["shadowsocks2022"], "network": "tcp",
                "method": "2022-blake3-aes-128-gcm",
                "password": config["ss2022_server_password"],
                "users": [{"name": u["name"], "password": u["ss2022_password"]} for u in users],
                "multiplex": {"enabled": True},
            })
        if "tuic" in enabled:
            inbounds.append({
                "type": "tuic", "tag": "tuic-in", "listen": "0.0.0.0",
                "listen_port": ports["tuic"],
                "users": [
                    {"name": u["name"], "uuid": u["tuic_uuid"], "password": u["tuic_password"]}
                    for u in users
                ],
                "congestion_control": "cubic", "zero_rtt_handshake": False,
                "tls": tls,
            })
        if "trojan" in enabled:
            inbounds.append({
                "type": "trojan", "tag": "trojan-in", "listen": "0.0.0.0",
                "listen_port": ports["trojan"],
                "users": [{"name": u["name"], "password": u["trojan_password"]} for u in users],
                "tls": tls,
            })
        outbounds = [{"type": "direct", "tag": "direct-out"}] + [
            {"type": "direct", "tag": f"audit-{user['name']}-out"} for user in users
        ]
        rules = [
            {"auth_user": [user["name"]], "action": "route", "outbound": f"audit-{user['name']}-out"}
            for user in users
        ]
        return {
            "log": {"level": "info", "timestamp": True},
            "inbounds": inbounds,
            "outbounds": outbounds,
            "route": {"rules": rules},
            "experimental": {
                "v2ray_api": {
                    "listen": config["grpc_address"],
                    "stats": {
                        "enabled": True,
                        "inbounds": [item["tag"] for item in inbounds],
                        "users": [user["name"] for user in users],
                    },
                }
            },
        }

    @staticmethod
    def write_atomic(path, data):
        text = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
        fd, temp_path = tempfile.mkstemp(prefix=f"{path.name}.", dir=str(path.parent))
        try:
            with os.fdopen(fd, "w") as handle:
                handle.write(text)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temp_path, 0o600)
            os.replace(temp_path, path)
        except Exception:
            try:
                os.unlink(temp_path)
            except FileNotFoundError:
                pass
            raise

    def validate_singbox(self, config):
        fd, temp_path = tempfile.mkstemp(prefix="sing-box-check.", suffix=".json")
        try:
            with os.fdopen(fd, "w") as handle:
                json.dump(config, handle, ensure_ascii=False, indent=2)
                handle.write("\n")
            result = subprocess.run(
                [self.singbox_binary, "check", "-c", temp_path],
                text=True, capture_output=True,
            )
            if result.returncode != 0:
                raise RuntimeError(result.stderr.strip() or "sing-box 配置校验失败")
        finally:
            Path(temp_path).unlink(missing_ok=True)

    @staticmethod
    def insert_usage(user):
        with sqlite3.connect(USAGE_DB_PATH) as conn:
            conn.execute(
                "INSERT INTO usage(name,upload,download,period,blocked,blocked_reason,accounting_version) VALUES(?,0,0,?,0,'',2)",
                (user["name"], datetime.now().strftime("%Y-%m-%d")),
            )

    def add(self, values):
        self.ensure_unique(values["name"])
        user = self.create_credentials(values)
        self.manager_config["users"].append(user)
        singbox_config = self.build_singbox_config()
        self.validate_singbox(singbox_config)
        manager_backup = MANAGER_CONFIG_PATH.with_suffix(".json.user-add-backup")
        singbox_backup = SINGBOX_CONFIG_PATH.with_suffix(".json.user-add-backup")
        manager_backed_up = False
        singbox_backed_up = False
        try:
            subprocess.run(["systemctl", "stop", "proxy-manager"], check=True)
            shutil.copy2(MANAGER_CONFIG_PATH, manager_backup)
            manager_backed_up = True
            shutil.copy2(SINGBOX_CONFIG_PATH, singbox_backup)
            singbox_backed_up = True
            self.write_atomic(MANAGER_CONFIG_PATH, self.manager_config)
            self.write_atomic(SINGBOX_CONFIG_PATH, singbox_config)
            self.insert_usage(user)
            subprocess.run(["systemctl", "restart", "sing-box"], check=True, timeout=30)
            subprocess.run(["systemctl", "start", "proxy-manager"], check=True, timeout=30)
        except Exception:
            if manager_backed_up:
                shutil.copy2(manager_backup, MANAGER_CONFIG_PATH)
            if singbox_backed_up:
                shutil.copy2(singbox_backup, SINGBOX_CONFIG_PATH)
            if USAGE_DB_PATH.exists():
                try:
                    with sqlite3.connect(USAGE_DB_PATH) as conn:
                        conn.execute("DELETE FROM usage WHERE name=?", (user["name"],))
                except sqlite3.Error:
                    pass
            subprocess.run(["systemctl", "restart", "sing-box"], check=False)
            subprocess.run(["systemctl", "start", "proxy-manager"], check=False)
            raise
        finally:
            manager_backup.unlink(missing_ok=True)
            singbox_backup.unlink(missing_ok=True)
        return user


def main():
    if os.geteuid() != 0:
        raise SystemExit("请使用 root 运行：sudo proxy-user-add")
    LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
    with LOCK_PATH.open("w") as lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        manager = ProxyUserManager()
        if not manager.manager_config.get("enabled_protocols", manager.manager_config["ports"]):
            raise SystemExit("尚未启用代理协议，请先运行 proxy-protocol。")
        try:
            values = UserInput().read(
                manager.billing_timezone,
                manager.manager_config.get("provider_next_reset", 0),
            )
            user = manager.add(values)
        except (ValueError, RuntimeError, subprocess.SubprocessError, sqlite3.Error) as exc:
            raise SystemExit(f"新增用户失败：{exc}") from exc
    expiry = datetime.fromtimestamp(user["expires_at"], manager.billing_timezone).strftime("%Y-%m-%d %H:%M:%S %Z")
    quota = user["quota_bytes"] / 1024 ** 3
    renewal = f"每 {user['renewal_months']} 个自然月自动续期" if user["auto_renew"] else "到期后停用"
    print("新增用户成功")
    print(f"用户名: {user['name']}")
    print(f"流量额度: {quota:g} GiB")
    print(f"到期时间: {expiry} ({manager.billing_timezone.key})")
    print(f"续期策略: {renewal}")
    print(f"订阅地址: https://{manager.manager_config['domain']}/sub/{user['token']}")


if __name__ == "__main__":
    main()
PY
chmod 700 /usr/local/sbin/proxy-user-add

cat > /usr/local/sbin/proxy-user-quota <<'PY'
#!/usr/bin/env python3
import json
import os
import tempfile
import subprocess
from pathlib import Path

CONFIG_PATH = Path("/etc/proxy-manager/config.json")

def save_config(config):
    fd, temp_path = tempfile.mkstemp(prefix="config.", dir=str(CONFIG_PATH.parent))
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(config, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp_path, 0o600)
        os.replace(temp_path, CONFIG_PATH)
    finally:
        Path(temp_path).unlink(missing_ok=True)

def main():
    if os.geteuid() != 0:
        raise SystemExit("请使用 root 运行：sudo proxy-user-quota")
    config = json.loads(CONFIG_PATH.read_text())
    users = config.get("users", [])
    if not users:
        raise SystemExit("当前没有用户。")
    print("⚠️ 流量额度按服务商双向流量（入站 + 出站）统计，请直接填写服务商套餐额度。")
    print("当前用户：")
    for index, user in enumerate(users, 1):
        print(f"  {index}. {user['name']}（当前 {user['quota_bytes'] / 1024**3:g} GiB）")
    choice = input("请选择用户编号: ").strip()
    try:
        user = users[int(choice) - 1]
    except (ValueError, IndexError):
        raise SystemExit("无效的用户编号。")
    quota_text = input("新的服务商双向流量额度 GiB: ").strip()
    try:
        quota_gib = float(quota_text)
    except ValueError as exc:
        raise SystemExit("流量额度必须是数字。") from exc
    if not 0 < quota_gib <= 1048576:
        raise SystemExit("流量额度必须大于 0 且不超过 1048576 GiB。")
    user["quota_bytes"] = int(quota_gib * 1024**3)
    save_config(config)
    subprocess.run(["systemctl", "restart", "proxy-manager"], check=True, timeout=30)
    print(f"用户 {user['name']} 的流量额度已修改为 {quota_gib:g} GiB。")

if __name__ == "__main__":
    main()
PY
chmod 700 /usr/local/sbin/proxy-user-quota

cat > /usr/local/sbin/proxy-protocol <<'PY'
#!/usr/bin/env python3
import base64
import fcntl
import os
import re
import runpy
import secrets
import shutil
import socket
import subprocess
import uuid
from pathlib import Path

MANAGER_CONFIG_PATH = Path("/etc/proxy-manager/config.json")
SINGBOX_CONFIG_PATH = Path("/etc/sing-box/config.json")
LOCK_PATH = Path("/var/lib/proxy-manager/user-admin.lock")
HY2_HOP_SERVICE_PATH = Path("/etc/systemd/system/proxy-hy2-port-hop.service")
PROTOCOLS = {
    "1": ("reality", "VLESS + REALITY", "tcp", "VLESS REALITY"),
    "2": ("anytls", "AnyTLS", "tcp", "AnyTLS"),
    "3": ("hysteria2", "Hysteria2", "udp", "Hysteria2"),
    "4": ("shadowsocks2022", "Shadowsocks 2022", "tcp", "Shadowsocks 2022"),
    "5": ("tuic", "TUIC v5", "udp", "TUIC v5"),
    "6": ("trojan", "Trojan TLS", "tcp", "Trojan TLS"),
}


class ProtocolManager:
    def __init__(self):
        namespace = runpy.run_path("/usr/local/sbin/proxy-user-add", run_name="proxy_user_module")
        self.user_manager = namespace["ProxyUserManager"]()
        self.config = self.user_manager.manager_config
        self.enabled = list(self.config.get("enabled_protocols", self.config["ports"].keys()))
        self.config["enabled_protocols"] = self.enabled

    def show(self):
        print("\n已启用协议：")
        if not self.enabled:
            print("  暂无")
        for key, name, network, _comment in PROTOCOLS.values():
            if key in self.enabled:
                port_text = str(self.config["ports"][key])
                suffix = ""
                if key == "hysteria2" and "hy2_hop_start" in self.config:
                    port_text = f"{self.config['hy2_hop_start']}-{self.config['hy2_hop_end']}"
                    suffix = f"（端口跳跃，{self.config['hy2_hop_interval']}s）"
                print(f"  {name:<16} {port_text}/{network.upper()}{suffix}")
        print("\n协议状态：")
        for choice, (key, name, _network, _comment) in PROTOCOLS.items():
            state = "已启用" if key in self.enabled else "可添加"
            print(f"  {choice}. {name:<16} {state}")
        print("\n操作：1. 添加协议  2. 删除协议  0. 返回")

    def choose_action(self):
        self.show()
        choice = input("请选择操作 [0-2]: ").strip()
        if choice == "0":
            return None
        if choice not in {"1", "2"}:
            raise ValueError("请选择 0-2")
        return choice

    def choose_to_add(self):
        choice = input("请选择要添加的协议 [1-6]: ").strip()
        if choice not in PROTOCOLS:
            raise ValueError("请选择 1-6")
        protocol = PROTOCOLS[choice]
        if protocol[0] in self.enabled:
            raise ValueError(f"{protocol[1]} 已经启用")
        return protocol

    def choose_to_remove(self):
        if not self.enabled:
            raise ValueError("当前没有已启用的协议")
        choice = input("请选择要删除的协议 [1-6]: ").strip()
        if choice not in PROTOCOLS:
            raise ValueError("请选择 1-6")
        protocol = PROTOCOLS[choice]
        if protocol[0] not in self.enabled:
            raise ValueError(f"{protocol[1]} 尚未启用")
        confirm = input(f"确认删除 {protocol[1]}？输入 yes 继续: ").strip().lower()
        if confirm != "yes":
            raise ValueError("已取消删除")
        return protocol

    def random_port(self):
        used = {80, 443, 8080, 8787, int(self.config["ssh_port"]), *self.config["ports"].values()}
        for _ in range(1000):
            port = secrets.randbelow(40001) + 20000
            if port in used:
                continue
            sockets = [
                socket.socket(socket.AF_INET, socket.SOCK_STREAM),
                socket.socket(socket.AF_INET, socket.SOCK_DGRAM),
            ]
            try:
                for item in sockets:
                    item.bind(("0.0.0.0", port))
            except OSError:
                continue
            finally:
                for item in sockets:
                    item.close()
            return port
        raise RuntimeError("无法生成空闲随机端口")

    def udp_range_available(self, start, end):
        used = {80, 443, 8080, 8787, int(self.config["ssh_port"]), *self.config["ports"].values()}
        for table_path in (Path("/proc/net/udp"), Path("/proc/net/udp6")):
            try:
                rows = table_path.read_text(encoding="ascii").splitlines()[1:]
            except OSError:
                continue
            for row in rows:
                fields = row.split()
                if len(fields) > 1:
                    used.add(int(fields[1].rsplit(":", 1)[1], 16))
        return not any(start <= port <= end for port in used)

    def random_udp_range(self):
        for _ in range(1000):
            start = secrets.randbelow(39901) + 20000
            end = start + 99
            if self.udp_range_available(start, end):
                return start, end
        raise RuntimeError("无法生成连续100个未占用的 UDP 端口")

    def configure_hysteria2_port(self):
        enabled = input("是否开启 Hysteria2 端口跳跃？[y/N]: ").strip().lower()
        if enabled not in {"y", "yes"}:
            return self.random_port()
        range_text = input("请输入跳跃端口范围（例如 20000-20100，直接回车自动选择100个端口）: ").strip()
        if range_text:
            match = re.fullmatch(r"(\d+)-(\d+)", range_text)
            if not match:
                raise ValueError("端口范围格式必须为 起始端口-结束端口")
            start, end = map(int, match.groups())
            if not (1 <= start < end <= 65535):
                raise ValueError("端口范围必须在 1-65535 内，且结束端口大于起始端口")
            if not self.udp_range_available(start, end):
                raise ValueError("端口范围包含已占用或保留端口")
        else:
            start, end = self.random_udp_range()
        interval_text = input("请输入跳跃间隔秒数（直接回车默认30）: ").strip() or "30"
        if not interval_text.isdigit() or int(interval_text) < 5:
            raise ValueError("跳跃间隔必须是至少 5 秒的整数")
        self.config["hy2_hop_start"] = start
        self.config["hy2_hop_end"] = end
        self.config["hy2_hop_interval"] = int(interval_text)
        return start

    def firewall_rule(self, key, port):
        if key == "hysteria2" and "hy2_hop_start" in self.config:
            return f"{self.config['hy2_hop_start']}:{self.config['hy2_hop_end']}/udp"
        network = next(item[2] for item in PROTOCOLS.values() if item[0] == key)
        return f"{port}/{network}"

    def install_hy2_hop_service(self):
        iptables = shutil.which("iptables")
        if not iptables:
            raise RuntimeError("未找到 iptables，无法启用端口跳跃")
        start = self.config["hy2_hop_start"]
        end = self.config["hy2_hop_end"]
        port = self.config["ports"]["hysteria2"]
        rule = f"{iptables} -t nat -C PREROUTING -p udp --dport {start}:{end} -j REDIRECT --to-ports {port}"
        add_rule = f"{iptables} -t nat -A PREROUTING -p udp --dport {start}:{end} -j REDIRECT --to-ports {port}"
        delete_rule = f"{iptables} -t nat -D PREROUTING -p udp --dport {start}:{end} -j REDIRECT --to-ports {port}"
        content = f"""[Unit]
Description=ST-SB Hysteria2 UDP port hopping
Before=sing-box.service
After=network-online.target ufw.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '{rule} || {add_rule}'
ExecStop=/bin/sh -c '{delete_rule} || true'

[Install]
WantedBy=multi-user.target
"""
        temp_path = HY2_HOP_SERVICE_PATH.with_suffix(".service.temp")
        temp_path.write_text(content, encoding="utf-8")
        os.chmod(temp_path, 0o644)
        os.replace(temp_path, HY2_HOP_SERVICE_PATH)
        subprocess.run(["systemctl", "daemon-reload"], check=True)
        subprocess.run(["systemctl", "enable", "--now", HY2_HOP_SERVICE_PATH.name], check=True)

    @staticmethod
    def remove_hy2_hop_service():
        subprocess.run(
            ["systemctl", "disable", "--now", HY2_HOP_SERVICE_PATH.name],
            check=False,
        )
        HY2_HOP_SERVICE_PATH.unlink(missing_ok=True)
        subprocess.run(["systemctl", "daemon-reload"], check=True)

    def add_credentials(self, key):
        if key == "reality":
            result = subprocess.check_output(
                [self.user_manager.singbox_binary, "generate", "reality-keypair"],
                text=True,
            )
            private_match = re.search(r"PrivateKey:\s*(\S+)", result, re.I)
            public_match = re.search(r"PublicKey:\s*(\S+)", result, re.I)
            if not private_match or not public_match:
                raise RuntimeError("REALITY 密钥生成失败")
            self.config["reality_private_key"] = private_match.group(1)
            self.config["reality_public_key"] = public_match.group(1)
            self.config["reality_short_id"] = secrets.token_hex(8)
            self.config["reality_server"] = "www.cloudflare.com"
            for user in self.config["users"]:
                user["vless_reality_uuid"] = str(uuid.uuid4())
        elif key == "anytls":
            for user in self.config["users"]:
                user["anytls_password"] = secrets.token_hex(16)
        elif key == "hysteria2":
            self.config["hy2_obfs_password"] = secrets.token_hex(16)
            for user in self.config["users"]:
                user["hy2_password"] = secrets.token_hex(16)
        elif key == "shadowsocks2022":
            self.config["ss2022_server_password"] = base64.b64encode(secrets.token_bytes(16)).decode()
            for user in self.config["users"]:
                user["ss2022_password"] = base64.b64encode(secrets.token_bytes(16)).decode()
        elif key == "tuic":
            for user in self.config["users"]:
                user["tuic_uuid"] = str(uuid.uuid4())
                user["tuic_password"] = secrets.token_hex(16)
        elif key == "trojan":
            for user in self.config["users"]:
                user["trojan_password"] = secrets.token_hex(16)

    def remove_credentials(self, key):
        if key == "reality":
            for field in (
                "reality_private_key", "reality_public_key", "reality_short_id", "reality_server",
            ):
                self.config.pop(field, None)
            for user in self.config["users"]:
                user.pop("vless_reality_uuid", None)
        elif key == "anytls":
            for user in self.config["users"]:
                user.pop("anytls_password", None)
        elif key == "hysteria2":
            for field in ("hy2_obfs_password", "hy2_hop_start", "hy2_hop_end", "hy2_hop_interval"):
                self.config.pop(field, None)
            for user in self.config["users"]:
                user.pop("hy2_password", None)
        elif key == "shadowsocks2022":
            self.config.pop("ss2022_server_password", None)
            for user in self.config["users"]:
                user.pop("ss2022_password", None)
        elif key == "tuic":
            for user in self.config["users"]:
                user.pop("tuic_uuid", None)
                user.pop("tuic_password", None)
        elif key == "trojan":
            for user in self.config["users"]:
                user.pop("trojan_password", None)

    @staticmethod
    def service_active(service):
        return subprocess.run(
            ["systemctl", "is-active", "--quiet", service],
            check=False,
        ).returncode == 0

    def refresh_node_info(self):
        path = Path("/root/node-info.txt")
        if not path.exists():
            return
        protocol_names = {item[1] for item in PROTOCOLS.values()}
        lines = [
            line for line in path.read_text(encoding="utf-8").splitlines()
            if not line.startswith("代理协议端口:")
            and not (
                line.startswith(("TCP", "UDP"))
                and any(name in line for name in protocol_names)
            )
        ]
        insert_at = next(
            (index + 1 for index, line in enumerate(lines) if line.startswith("TCP 443")),
            len(lines),
        )
        protocol_lines = ["代理协议端口: 尚未启用；运行 proxy 并进入协议管理"]
        if self.enabled:
            protocol_lines = ["代理协议端口:"]
            for key, name, network, _comment in PROTOCOLS.values():
                if key in self.enabled:
                    port_text = str(self.config["ports"][key])
                    suffix = ""
                    if key == "hysteria2" and "hy2_hop_start" in self.config:
                        port_text = f"{self.config['hy2_hop_start']}-{self.config['hy2_hop_end']}"
                        suffix = f"（端口跳跃，{self.config['hy2_hop_interval']}s）"
                    protocol_lines.append(f"{network.upper():<7} {port_text:<11} {name}{suffix}")
        lines[insert_at:insert_at] = protocol_lines
        temp_path = path.with_suffix(".txt.protocol-temp")
        temp_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        os.chmod(temp_path, 0o600)
        os.replace(temp_path, path)

    def enable(self, protocol):
        key, name, network, comment = protocol
        port = self.configure_hysteria2_port() if key == "hysteria2" else self.random_port()
        self.config["ports"][key] = port
        self.add_credentials(key)
        self.enabled.append(key)
        singbox_config = self.user_manager.build_singbox_config()
        self.user_manager.validate_singbox(singbox_config)
        manager_backup = MANAGER_CONFIG_PATH.with_suffix(".json.protocol-backup")
        singbox_backup = SINGBOX_CONFIG_PATH.with_suffix(".json.protocol-backup")
        service_state = {
            "sing-box": self.service_active("sing-box"),
            "proxy-manager": self.service_active("proxy-manager"),
        }
        firewall_added = False
        hop_service_touched = False
        firewall_rule = self.firewall_rule(key, port)
        try:
            shutil.copy2(MANAGER_CONFIG_PATH, manager_backup)
            shutil.copy2(SINGBOX_CONFIG_PATH, singbox_backup)
            if service_state["proxy-manager"]:
                subprocess.run(["systemctl", "stop", "proxy-manager"], check=True, timeout=30)
            self.user_manager.write_atomic(MANAGER_CONFIG_PATH, self.config)
            self.user_manager.write_atomic(SINGBOX_CONFIG_PATH, singbox_config)
            subprocess.run(["ufw", "allow", firewall_rule, "comment", comment], check=True)
            firewall_added = True
            if key == "hysteria2" and "hy2_hop_start" in self.config:
                hop_service_touched = True
                self.install_hy2_hop_service()
            if service_state["sing-box"]:
                subprocess.run(["systemctl", "restart", "sing-box"], check=True, timeout=30)
            if service_state["proxy-manager"]:
                subprocess.run(["systemctl", "start", "proxy-manager"], check=True, timeout=30)
        except Exception:
            shutil.copy2(manager_backup, MANAGER_CONFIG_PATH)
            shutil.copy2(singbox_backup, SINGBOX_CONFIG_PATH)
            if firewall_added:
                subprocess.run(["ufw", "--force", "delete", "allow", firewall_rule], check=False)
            if hop_service_touched:
                self.remove_hy2_hop_service()
            if service_state["sing-box"]:
                subprocess.run(["systemctl", "restart", "sing-box"], check=False)
            if service_state["proxy-manager"]:
                subprocess.run(["systemctl", "start", "proxy-manager"], check=False)
            raise
        finally:
            manager_backup.unlink(missing_ok=True)
            singbox_backup.unlink(missing_ok=True)
        try:
            self.refresh_node_info()
        except OSError as exc:
            print(f"警告：节点信息文件更新失败：{exc}")
        display_port = firewall_rule.removesuffix(f"/{network}")
        print(f"已启用 {name}：{display_port}/{network.upper()}")
        if self.config["users"]:
            print("已有用户的订阅地址不变，刷新订阅即可获取新协议。")

    def disable(self, protocol):
        key, name, network, comment = protocol
        port = self.config["ports"][key]
        firewall_rule = self.firewall_rule(key, port)
        hop_enabled = key == "hysteria2" and "hy2_hop_start" in self.config
        self.config["ports"].pop(key)
        self.enabled.remove(key)
        self.remove_credentials(key)
        singbox_config = self.user_manager.build_singbox_config()
        self.user_manager.validate_singbox(singbox_config)
        manager_backup = MANAGER_CONFIG_PATH.with_suffix(".json.protocol-backup")
        singbox_backup = SINGBOX_CONFIG_PATH.with_suffix(".json.protocol-backup")
        hop_service_backup = HY2_HOP_SERVICE_PATH.with_suffix(".service.protocol-backup")
        service_state = {
            "sing-box": self.service_active("sing-box"),
            "proxy-manager": self.service_active("proxy-manager"),
        }
        firewall_removed = False
        try:
            shutil.copy2(MANAGER_CONFIG_PATH, manager_backup)
            shutil.copy2(SINGBOX_CONFIG_PATH, singbox_backup)
            if hop_enabled and HY2_HOP_SERVICE_PATH.exists():
                shutil.copy2(HY2_HOP_SERVICE_PATH, hop_service_backup)
            if service_state["proxy-manager"]:
                subprocess.run(["systemctl", "stop", "proxy-manager"], check=True, timeout=30)
            self.user_manager.write_atomic(MANAGER_CONFIG_PATH, self.config)
            self.user_manager.write_atomic(SINGBOX_CONFIG_PATH, singbox_config)
            if hop_enabled:
                self.remove_hy2_hop_service()
            result = subprocess.run(
                ["ufw", "--force", "delete", "allow", firewall_rule],
                check=False,
            )
            firewall_removed = result.returncode == 0
            if service_state["sing-box"]:
                subprocess.run(["systemctl", "restart", "sing-box"], check=True, timeout=30)
            if service_state["proxy-manager"]:
                subprocess.run(["systemctl", "start", "proxy-manager"], check=True, timeout=30)
        except Exception:
            shutil.copy2(manager_backup, MANAGER_CONFIG_PATH)
            shutil.copy2(singbox_backup, SINGBOX_CONFIG_PATH)
            if firewall_removed:
                subprocess.run(
                    ["ufw", "allow", firewall_rule, "comment", comment],
                    check=False,
                )
            if hop_service_backup.exists():
                shutil.copy2(hop_service_backup, HY2_HOP_SERVICE_PATH)
                subprocess.run(["systemctl", "daemon-reload"], check=False)
                subprocess.run(
                    ["systemctl", "enable", "--now", HY2_HOP_SERVICE_PATH.name],
                    check=False,
                )
            if service_state["sing-box"]:
                subprocess.run(["systemctl", "restart", "sing-box"], check=False)
            if service_state["proxy-manager"]:
                subprocess.run(["systemctl", "start", "proxy-manager"], check=False)
            raise
        finally:
            manager_backup.unlink(missing_ok=True)
            singbox_backup.unlink(missing_ok=True)
            hop_service_backup.unlink(missing_ok=True)
        try:
            self.refresh_node_info()
        except OSError as exc:
            print(f"警告：节点信息文件更新失败：{exc}")
        display_port = firewall_rule.removesuffix(f"/{network}")
        print(f"已删除 {name}，并关闭 {display_port}/{network.upper()}。")
        if self.config["users"]:
            print("已有用户的订阅地址不变，刷新订阅后该协议将消失。")


def main():
    if os.geteuid() != 0:
        raise SystemExit("请使用 root 运行：sudo proxy-protocol")
    LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
    with LOCK_PATH.open("w") as lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        manager = ProtocolManager()
        try:
            action = manager.choose_action()
            if action == "1":
                manager.enable(manager.choose_to_add())
            elif action == "2":
                manager.disable(manager.choose_to_remove())
        except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as exc:
            raise SystemExit(f"协议操作失败：{exc}") from exc


if __name__ == "__main__":
    main()
PY
chmod 700 /usr/local/sbin/proxy-protocol

cat > /usr/local/sbin/proxy-node-info <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

NODE_INFO_PATH=/root/node-info.txt
if [[ ! -r "$NODE_INFO_PATH" ]]; then
  echo "节点信息文件不存在：$NODE_INFO_PATH"
  exit 1
fi

COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_CYAN=""
COLOR_RED=""
COLOR_RESET=""
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  COLOR_GREEN=$'\033[1;32m'
  COLOR_YELLOW=$'\033[1;33m'
  COLOR_CYAN=$'\033[1;36m'
  COLOR_RED=$'\033[1;31m'
  COLOR_RESET=$'\033[0m'
fi

while IFS= read -r line; do
  case "$line" in
    "云服务商安全组需要放行："|"代理协议端口: "*|"日常管理命令："|"格式强制参数（通常无需使用）："|"审计查询命令：")
      printf '%b%s%b\n' "$COLOR_YELLOW" "$line" "$COLOR_RESET"
      ;;
    "域名: "*|"搬瓦工下次流量重置: "*|"SSH端口: "*)
      printf '%b%s%b\n' "$COLOR_GREEN" "$line" "$COLOR_RESET"
      ;;
    TCP*|UDP*|proxy*|\?target=*)
      printf '%b%s%b\n' "$COLOR_CYAN" "$line" "$COLOR_RESET"
      ;;
    "请明确告知所有使用者已启用域名/IP级访问审计。"|"严禁把 /etc/proxy-manager/config.json 发给他人，其中包含全部服务端密钥。")
      printf '%b%s%b\n' "$COLOR_RED" "$line" "$COLOR_RESET"
      ;;
    *)
      printf '%s\n' "$line"
      ;;
  esac
done < "$NODE_INFO_PATH"
EOF
chmod 700 /usr/local/sbin/proxy-node-info

cat > /usr/local/sbin/proxy <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "请使用 root 运行：sudo proxy"
  exit 1
fi

pause_menu() {
  echo
  read -r -p "按回车键返回主菜单……" _
}

show_menu() {
  echo '
   ___________   _____ ____
  / ___/_  __/  / ___// __ )
 \__ \ / /_____\__ \/ __  |
 ___/ // /_____/__/ / /_/ /
/____//_/     /____/_____/'
  echo "
╔──────────────────────────────────╗
│           代理节点管理           │
├──────────────────────────────────┤
│  1. 协议管理                     │
│  2. 用户管理                     │
│  3. 访问审计                     │
│  4. 配置检查                     │
│  5. 服务管理                     │
│  6. 防火墙                       │
│  7. 节点信息                     │
│  8. BBR 管理                     │
│  9. 更新版本                     │
│ 10. 卸载                         │
│  0. 退出                         │
╚──────────────────────────────────╝"
}

manage_protocols() {
  proxy-protocol
}

add_user() {
  proxy-user-add
}

edit_user_quota() {
  proxy-user-quota
}

show_users() {
  proxy-user-status
}

manage_users() {
  local choice
  while true; do
    echo "
╔──────────────────────────────────╗
│             用户管理             │
├──────────────────────────────────┤
│  1. 新增用户                     │
│  2. 修改用户限额                 │
│  3. 用户状态                     │
│  0. 返回                         │
╚──────────────────────────────────╝"
    read -r -p "请选择 [0-3]: " choice
    echo
    case "$choice" in
      1) add_user; pause_menu ;;
      2) edit_user_quota; pause_menu ;;
      3) show_users; pause_menu ;;
      0) return ;;
      *) echo "无效选择，请输入 0-3。" ;;
    esac
  done
}

show_recent_audit() {
  proxy-audit
}

show_audit_summary() {
  proxy-audit --summary --days 7
}

manage_audit() {
  local choice
  echo "
╔──────────────────────────────────╗
│             访问审计             │
├──────────────────────────────────┤
│  1. 访问记录                     │
│  2. 访问汇总                     │
│  0. 返回                         │
╚──────────────────────────────────╝"
  read -r -p "请选择 [0-2]: " choice
  echo
  case "$choice" in
    1) show_recent_audit ;;
    2) show_audit_summary ;;
    0) return ;;
    *) echo "无效选择，请输入 0-2。" ;;
  esac
}

check_singbox_config() {
  local binary
  binary=$(python3 -c "import json; print(json.load(open('/etc/proxy-manager/config.json'))['singbox_binary'])")
  if "$binary" check -c /etc/sing-box/config.json; then
    echo "配置检查通过，sing-box 配置有效。"
  else
    echo "配置检查失败，请根据上方错误信息修复。" >&2
    return 1
  fi
}

show_service_status() {
  systemctl status sing-box proxy-manager --no-pager
}

show_service_logs() {
  echo "--- sing-box 最近50行日志 ---"
  journalctl -u sing-box -n 50 --no-pager
  echo
  echo "--- proxy-manager 最近50行日志 ---"
  journalctl -u proxy-manager -n 50 --no-pager
}

manage_services() {
  local choice
  echo "
╔──────────────────────────────────╗
│             服务管理             │
├──────────────────────────────────┤
│  1. 服务状态                     │
│  2. 服务日志                     │
│  0. 返回                         │
╚──────────────────────────────────╝"
  read -r -p "请选择 [0-2]: " choice
  echo
  case "$choice" in
    1) show_service_status ;;
    2) show_service_logs ;;
    0) return ;;
    *) echo "无效选择，请输入 0-2。" ;;
  esac
}

show_firewall() {
  ufw status numbered
}

show_node_info() {
  if command -v proxy-node-info >/dev/null 2>&1; then
    proxy-node-info
  else
    cat /root/node-info.txt
  fi
}

show_bbr_status() {
  local available current qdisc
  available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
  current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
  qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
  echo "可用拥塞控制算法: ${available:-无法读取}"
  echo "当前拥塞控制算法: ${current:-无法读取}"
  echo "当前默认队列规则: ${qdisc:-无法读取}"
  if [[ "$current" == "bbr" ]]; then
    echo "BBR 状态: 已开启"
  else
    echo "BBR 状态: 未开启"
  fi
}

restore_network_settings() {
  local old_congestion=$1
  local old_qdisc=$2
  sysctl -w "net.ipv4.tcp_congestion_control=${old_congestion}" >/dev/null 2>&1 || true
  sysctl -w "net.core.default_qdisc=${old_qdisc}" >/dev/null 2>&1 || true
}

enable_bbr() {
  local available old_congestion old_qdisc temp_config
  local config_path=/etc/sysctl.d/99-st-sb-bbr.conf
  old_congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
  old_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
  if [[ -z "$old_congestion" || -z "$old_qdisc" ]]; then
    echo "无法读取当前网络参数，未修改系统配置。" >&2
    return 1
  fi

  available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
  if [[ " $available " != *" bbr "* ]]; then
    modprobe tcp_bbr 2>/dev/null || true
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
  fi
  if [[ " $available " != *" bbr "* ]]; then
    echo "当前内核不支持 BBR，请先升级内核。" >&2
    return 1
  fi

  if ! sysctl -w net.core.default_qdisc=fq >/dev/null || \
    ! sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null; then
    restore_network_settings "$old_congestion" "$old_qdisc"
    echo "应用 BBR 参数失败，已恢复原网络设置。" >&2
    return 1
  fi

  install -d -m 755 /etc/sysctl.d
  if ! temp_config=$(mktemp /etc/sysctl.d/.99-st-sb-bbr.conf.XXXXXX); then
    restore_network_settings "$old_congestion" "$old_qdisc"
    echo "无法创建 BBR 配置文件，已恢复原网络设置。" >&2
    return 1
  fi
  if ! printf '%s\n' \
    'net.core.default_qdisc = fq' \
    'net.ipv4.tcp_congestion_control = bbr' > "$temp_config" || \
    ! chmod 644 "$temp_config" || \
    ! mv -f "$temp_config" "$config_path"; then
    rm -f -- "$temp_config"
    restore_network_settings "$old_congestion" "$old_qdisc"
    echo "保存 BBR 配置失败，已恢复原网络设置。" >&2
    return 1
  fi

  if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" != "bbr" ]]; then
    rm -f -- "$config_path"
    restore_network_settings "$old_congestion" "$old_qdisc"
    echo "BBR 状态验证失败，请检查内核日志。" >&2
    return 1
  fi
  echo "BBR 已开启，并已写入 ${config_path}。"
}

manage_bbr() {
  local choice
  echo "
╔──────────────────────────────────╗
│             BBR 管理             │
╚──────────────────────────────────╝"
  show_bbr_status
  echo "
╔──────────────────────────────────╗
│  1. 开启或修复 BBR               │
│  0. 返回                         │
╚──────────────────────────────────╝"
  read -r -p "请选择 [0-1]: " choice
  echo
  case "$choice" in
    1) enable_bbr ;;
    0) return ;;
    *) echo "无效选择，请输入 0-1。" ;;
  esac
}

update_proxy() {
  proxy-update
}

uninstall_proxy() {
  local confirm backup_dir path rule
  local backup_failed=0
  local warning_count=0
  local -a firewall_rules=()
  echo "此操作将卸载 ST-SB 服务、配置、数据库、管理命令和 nginx 订阅站点。"
  echo "Let’s Encrypt 证书、sing-box 程序、BBR 设置、SSH/80/443 防火墙规则和卸载备份会保留。"
  read -r -p "请输入 UNINSTALL 确认卸载: " confirm
  if [[ "$confirm" != "UNINSTALL" ]]; then
    echo "已取消卸载。"
    return
  fi

  exec 8>/run/lock/proxy-manager-install.lock
  if ! flock -n 8; then
    echo "安装或更新程序正在运行，请稍后重试。"
    return
  fi
  exec 7>/var/lib/proxy-manager/user-admin.lock
  if ! flock -n 7; then
    echo "用户或协议管理程序正在运行，请稍后重试。"
    return
  fi

  if ! backup_dir=$(mktemp -d "/root/st-sb-uninstall-backup-$(date +%Y%m%d-%H%M%S).XXXXXX"); then
    echo "无法创建卸载备份目录，已终止卸载。"
    return
  fi
  chmod 700 "$backup_dir"
  for path in \
    /etc/proxy-manager \
    /etc/sing-box/config.json \
    /var/lib/proxy-manager \
    /opt/proxy-manager \
    /etc/systemd/system/sing-box.service \
    /etc/systemd/system/proxy-manager.service \
    /etc/systemd/system/proxy-hy2-port-hop.service \
    /etc/nginx/sites-available/proxy-subscription \
    /etc/nginx/sites-enabled/proxy-subscription \
    /etc/letsencrypt/renewal-hooks/deploy/reload-proxy-services \
    /usr/local/sbin/proxy \
    /usr/local/sbin/proxy-protocol \
    /usr/local/sbin/proxy-node-info \
    /usr/local/sbin/proxy-update \
    /usr/local/sbin/proxy-user-add \
    /usr/local/sbin/proxy-user-quota \
    /usr/local/sbin/proxy-user-status \
    /usr/local/sbin/proxy-audit \
    /root/node-info.txt \
    /root/proxy-links.txt; do
    if [[ -e "$path" || -L "$path" ]]; then
      if ! cp -a --parents "$path" "$backup_dir"; then
        backup_failed=1
      fi
    fi
  done
  if (( backup_failed )); then
    echo "卸载备份不完整，已终止卸载：$backup_dir"
    return
  fi

  if [[ -r /etc/proxy-manager/config.json ]]; then
    mapfile -t firewall_rules < <(python3 <<'PY'
import json

networks = {
    "reality": "tcp",
    "anytls": "tcp",
    "hysteria2": "udp",
    "shadowsocks2022": "tcp",
    "tuic": "udp",
    "trojan": "tcp",
}
try:
    with open("/etc/proxy-manager/config.json", encoding="utf-8") as handle:
        config = json.load(handle)
        ports = config.get("ports", {})
    for name, network in networks.items():
        port = ports.get(name)
        if isinstance(port, int) and 1 <= port <= 65535:
            if name == "hysteria2" and "hy2_hop_start" in config:
                print(f"{config['hy2_hop_start']}:{config['hy2_hop_end']}/udp")
            else:
                print(f"{port}/{network}")
except (OSError, TypeError, ValueError, json.JSONDecodeError):
    pass
PY
    )
  fi

  if ! systemctl stop proxy-manager sing-box; then
    echo "服务停止失败，已终止卸载；备份位于：$backup_dir"
    return
  fi
  systemctl disable --now proxy-hy2-port-hop >/dev/null 2>&1 || true
  systemctl disable proxy-manager sing-box >/dev/null 2>&1 || warning_count=$((warning_count + 1))
  for rule in "${firewall_rules[@]}"; do
    ufw --force delete allow "$rule" >/dev/null 2>&1 || warning_count=$((warning_count + 1))
  done

  if ! rm -f \
    /etc/systemd/system/sing-box.service \
    /etc/systemd/system/proxy-manager.service \
    /etc/systemd/system/proxy-hy2-port-hop.service \
    /etc/nginx/sites-enabled/proxy-subscription \
    /etc/nginx/sites-available/proxy-subscription \
    /etc/letsencrypt/renewal-hooks/deploy/reload-proxy-services \
    /etc/sing-box/config.json \
    /usr/local/sbin/proxy \
    /usr/local/sbin/proxy-protocol \
    /usr/local/sbin/proxy-node-info \
    /usr/local/sbin/proxy-update \
    /usr/local/sbin/proxy-user-add \
    /usr/local/sbin/proxy-user-status \
    /usr/local/sbin/proxy-audit \
    /root/node-info.txt \
    /root/proxy-links.txt; then
    echo "部分文件删除失败，请根据备份手动检查：$backup_dir"
    return
  fi
  if ! rm -rf -- /etc/proxy-manager /var/lib/proxy-manager /opt/proxy-manager; then
    echo "部分目录删除失败，请根据备份手动检查：$backup_dir"
    return
  fi
  systemctl daemon-reload || warning_count=$((warning_count + 1))
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx 2>/dev/null || warning_count=$((warning_count + 1))
  else
    warning_count=$((warning_count + 1))
  fi

  echo "ST-SB 已卸载。"
  echo "卸载前备份：$backup_dir"
  echo "已保留 Let’s Encrypt 证书和 sing-box 程序。"
  if (( warning_count )); then
    echo "警告：有 ${warning_count} 项防火墙或系统刷新操作未成功，请手动检查 UFW、systemd 和 nginx。"
  fi
  exit 0
}

while true; do
  show_menu
  read -r -p "请选择 [0-10]: " choice
  echo
  case "$choice" in
    1) manage_protocols ;;
    2) manage_users; continue ;;
    3) manage_audit ;;
    4) check_singbox_config ;;
    5) manage_services ;;
    6) show_firewall ;;
    7) show_node_info ;;
    8) manage_bbr ;;
    9) update_proxy ;;
    10) uninstall_proxy ;;
    0)
      echo "已退出代理节点管理。"
      exit 0
      ;;
    *)
      echo "无效选择，请输入 0-10。"
      ;;
  esac
  pause_menu
done
EOF
chmod 700 /usr/local/sbin/proxy

cat > /usr/local/sbin/proxy-update <<'PY'
#!/usr/bin/env python3
import fcntl
import os
import py_compile
import re
import shutil
import subprocess
import tempfile
import urllib.request
from datetime import datetime
from pathlib import Path

SOURCE_URL = "https://raw.githubusercontent.com/ShumTin/st-sb-manager/master/install.sh"
LOCK_PATH = Path("/run/lock/proxy-manager-install.lock")
ADMIN_LOCK_PATH = Path("/var/lib/proxy-manager/user-admin.lock")
TARGETS = (
    Path("/opt/proxy-manager/manager.py"),
    Path("/opt/proxy-manager/audit_supervisor.py"),
    Path("/usr/local/sbin/proxy-user-add"),
    Path("/usr/local/sbin/proxy-user-quota"),
    Path("/usr/local/sbin/proxy-protocol"),
    Path("/usr/local/sbin/proxy-node-info"),
    Path("/usr/local/sbin/proxy"),
    Path("/usr/local/sbin/proxy-update"),
    Path("/usr/local/sbin/proxy-user-status"),
    Path("/usr/local/sbin/proxy-audit"),
)
HEADER_RE = re.compile(r"^cat > (\S+) <<'([A-Z]+)'$")


class ProxyUpdater:
    def __init__(self):
        self.changed = []
        self.backup_dir = Path("/root") / f"proxy-update-backup-{datetime.now():%Y%m%d-%H%M%S-%f}"
        self.was_active = {}

    @staticmethod
    def download_source():
        request = urllib.request.Request(SOURCE_URL, headers={"User-Agent": "ST-SB-Updater/1.0"})
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.read().decode("utf-8")

    @staticmethod
    def extract_files(source):
        expected = {str(path): path for path in TARGETS}
        extracted = {}
        lines = source.splitlines(keepends=True)
        index = 0
        while index < len(lines):
            match = HEADER_RE.fullmatch(lines[index].rstrip("\r\n"))
            if not match or match.group(1) not in expected:
                index += 1
                continue
            target = expected[match.group(1)]
            delimiter = match.group(2)
            end = index + 1
            while end < len(lines) and lines[end].rstrip("\r\n") != delimiter:
                end += 1
            if end >= len(lines):
                raise RuntimeError(f"远程安装脚本中的 {target} 未正确结束")
            extracted[target] = "".join(lines[index + 1:end]).encode("utf-8")
            index = end + 1
        missing = [str(path) for path in TARGETS if path not in extracted]
        if missing:
            raise RuntimeError("远程安装脚本缺少更新文件：" + "、".join(missing))
        return extracted

    @staticmethod
    def validate_files(extracted, stage_dir):
        staged = {}
        for target, content in extracted.items():
            stage_path = stage_dir / target.name
            stage_path.write_bytes(content)
            os.chmod(stage_path, 0o700)
            staged[target] = stage_path
            if target.name in {"proxy", "proxy-node-info"}:
                subprocess.run(["bash", "-n", stage_path], check=True)
            else:
                py_compile.compile(str(stage_path), doraise=True)
        return staged

    def find_changes(self, extracted):
        self.changed = [
            target for target, content in extracted.items()
            if not target.exists() or target.read_bytes() != content
        ]

    def backup_files(self):
        for target in self.changed:
            if not target.exists():
                continue
            backup_path = self.backup_dir / target.relative_to("/")
            backup_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(target, backup_path)

    def remember_service_state(self):
        service_targets = {
            "sing-box": Path("/opt/proxy-manager/audit_supervisor.py"),
            "proxy-manager": Path("/opt/proxy-manager/manager.py"),
        }
        for service, target in service_targets.items():
            if target not in self.changed:
                self.was_active[service] = False
                continue
            result = subprocess.run(["systemctl", "is-active", "--quiet", service], check=False)
            self.was_active[service] = result.returncode == 0

    def stop_services(self):
        for service in ("proxy-manager", "sing-box"):
            if self.was_active[service]:
                subprocess.run(["systemctl", "stop", service], check=True, timeout=30)

    def install_files(self, staged):
        for target in self.changed:
            target.parent.mkdir(parents=True, exist_ok=True)
            fd, temp_path = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
            os.close(fd)
            try:
                shutil.copyfile(staged[target], temp_path)
                os.chmod(temp_path, 0o700)
                os.replace(temp_path, target)
            finally:
                Path(temp_path).unlink(missing_ok=True)

    def start_services(self):
        for service in ("sing-box", "proxy-manager"):
            if not self.was_active[service]:
                continue
            subprocess.run(["systemctl", "start", service], check=True, timeout=30)
            subprocess.run(["systemctl", "is-active", "--quiet", service], check=True)

    def rollback(self):
        for target in self.changed:
            backup_path = self.backup_dir / target.relative_to("/")
            if backup_path.exists():
                shutil.copy2(backup_path, target)
            else:
                target.unlink(missing_ok=True)
        for service in ("sing-box", "proxy-manager"):
            if self.was_active.get(service):
                subprocess.run(["systemctl", "start", service], check=False)

    def run(self):
        source = self.download_source()
        extracted = self.extract_files(source)
        self.find_changes(extracted)
        if not self.changed:
            print("当前已经是最新版本。")
            return
        with tempfile.TemporaryDirectory(prefix="proxy-update-") as temp_dir:
            staged = self.validate_files(extracted, Path(temp_dir))
            self.backup_files()
            self.remember_service_state()
            try:
                self.stop_services()
                self.install_files(staged)
                self.start_services()
            except Exception:
                self.rollback()
                raise
        print("更新完成。")
        print("已更新：" + "、".join(target.name for target in self.changed))
        print(f"更新前备份：{self.backup_dir}")


def main():
    if os.geteuid() != 0:
        raise SystemExit("请使用 root 运行：sudo proxy-update")
    LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
    ADMIN_LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
    with LOCK_PATH.open("w") as lock_file, ADMIN_LOCK_PATH.open("w") as admin_lock_file:
        try:
            fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(admin_lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise SystemExit("安装或更新程序正在运行，请稍后重试。") from exc
        try:
            ProxyUpdater().run()
        except (OSError, RuntimeError, subprocess.SubprocessError, py_compile.PyCompileError) as exc:
            raise SystemExit(f"更新失败：{exc}") from exc


if __name__ == "__main__":
    main()
PY
chmod 700 /usr/local/sbin/proxy-update

cat > /opt/proxy-manager/audit_supervisor.py <<'PY'
#!/usr/bin/env python3
"""Run sing-box and persist only sanitized destination metadata for seven days."""
import ipaddress
import json
import os
import queue
import re
import signal
import sqlite3
import subprocess
import sys
import threading
import time
from pathlib import Path

CONFIG_PATH = Path("/etc/proxy-manager/config.json")
DB_PATH = "/var/lib/proxy-manager/audit.db"
CONFIG = json.loads(CONFIG_PATH.read_text())
RETENTION_SECONDS = int(CONFIG.get("audit_retention_days", 7)) * 86400
VALID_USERS = {u["name"] for u in CONFIG["users"]}
ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
CONTEXT_RE = re.compile(
    r"\[(\d+)(?:\s+[^\]]*)?\]\s+inbound/([A-Za-z0-9_-]+)\[([^\]]+)\]:"
)
OUTBOUND_RE = re.compile(
    r"\[(\d+)(?:\s+[^\]]*)?\]\s+outbound/direct\[audit-([A-Za-z][A-Za-z0-9_-]{0,31})-out\]:\s+"
    r"outbound\s+(packet\s+)?connection\s+to\s+(\S+)"
)
DOMAIN_RE = re.compile(
    r"^(?=.{1,253}\.?$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*"
    r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.?$"
)
PROTOCOL_NAMES = {
    "vless-reality-in": "VLESS-REALITY",
    "anytls-in": "AnyTLS",
    "hysteria2-in": "Hysteria2",
    "shadowsocks2022-in": "Shadowsocks 2022",
    "tuic-in": "TUIC v5",
    "trojan-in": "Trojan TLS",
}
process = None


def open_db():
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA secure_delete=ON")
    conn.execute("PRAGMA busy_timeout=30000")
    return conn


def init_db():
    with open_db() as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS access_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts INTEGER NOT NULL,
                user TEXT NOT NULL,
                protocol TEXT NOT NULL,
                destination TEXT NOT NULL,
                port INTEGER NOT NULL,
                network TEXT NOT NULL
            )
        """)
        conn.execute("CREATE INDEX IF NOT EXISTS audit_ts_idx ON access_events(ts)")
        conn.execute("CREATE INDEX IF NOT EXISTS audit_user_ts_idx ON access_events(user, ts)")
        conn.execute("CREATE INDEX IF NOT EXISTS audit_destination_ts_idx ON access_events(destination, ts)")
    os.chmod(DB_PATH, 0o600)


def cleanup_once():
    cutoff = int(time.time()) - RETENTION_SECONDS
    with open_db() as conn:
        conn.execute("DELETE FROM access_events WHERE ts < ?", (cutoff,))
        conn.commit()
        conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")


def cleanup_loop():
    while True:
        try:
            cleanup_once()
        except Exception:
            print("proxy audit cleanup failed", flush=True)
        time.sleep(3600)


class AuditWriter:
    """批量持久化审计事件，避免 SQLite I/O 阻塞 sing-box 日志管道。"""

    def __init__(self):
        self.events = queue.Queue(maxsize=10000)
        self.stopping = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.last_drop_warning = 0.0

    def start(self):
        self.thread.start()

    def submit(self, event):
        try:
            self.events.put_nowait(event)
        except queue.Full:
            now = time.monotonic()
            if now - self.last_drop_warning >= 10:
                print("proxy audit queue full; events are being dropped", flush=True)
                self.last_drop_warning = now

    def close(self):
        self.stopping.set()
        self.thread.join(timeout=10)
        if self.thread.is_alive():
            print("proxy audit writer did not stop cleanly", flush=True)

    def _run(self):
        conn = open_db()
        try:
            while not self.stopping.is_set() or not self.events.empty():
                batch = []
                try:
                    batch.append(self.events.get(timeout=0.5))
                except queue.Empty:
                    continue
                while len(batch) < 100:
                    try:
                        batch.append(self.events.get_nowait())
                    except queue.Empty:
                        break
                try:
                    conn.executemany(
                        "INSERT INTO access_events(ts,user,protocol,destination,port,network) "
                        "VALUES(?,?,?,?,?,?)",
                        batch,
                    )
                    conn.commit()
                except sqlite3.Error:
                    conn.rollback()
                    print("proxy audit database batch write failed", flush=True)
        finally:
            conn.close()


def split_destination(value):
    value = value.strip()
    if not value or any(mark in value for mark in ("/", "?", "#", "@")):
        return None
    if value.startswith("["):
        close = value.find("]")
        if close < 2 or close + 2 >= len(value) or value[close + 1] != ":":
            return None
        host = value[1:close]
        port_text = value[close + 2:]
    else:
        if ":" not in value:
            return None
        host, port_text = value.rsplit(":", 1)
    try:
        port = int(port_text)
    except ValueError:
        return None
    if not 1 <= port <= 65535 or not host or len(host) > 253:
        return None
    try:
        host = ipaddress.ip_address(host).compressed
    except ValueError:
        try:
            host = host.encode("idna").decode("ascii").lower().rstrip(".")
        except UnicodeError:
            return None
        if not DOMAIN_RE.fullmatch(host):
            return None
    return host, port


def stop_child(signum, _frame):
    if process is not None and process.poll() is None:
        try:
            process.send_signal(signum)
        except ProcessLookupError:
            pass


def main():
    global process
    if len(sys.argv) != 3:
        print("audit supervisor configuration error", flush=True)
        return 2
    init_db()
    cleanup_once()
    threading.Thread(target=cleanup_loop, daemon=True).start()
    signal.signal(signal.SIGTERM, stop_child)
    signal.signal(signal.SIGINT, stop_child)
    process = subprocess.Popen(
        [sys.argv[1], "run", "-c", sys.argv[2]],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        bufsize=1,
    )
    contexts = {}
    writer = AuditWriter()
    writer.start()
    print("sing-box started with sanitized 7-day destination audit", flush=True)
    try:
        for raw_line in process.stdout:
            line = ANSI_RE.sub("", raw_line.rstrip("\r\n"))
            now_mono = time.monotonic()
            context_match = CONTEXT_RE.search(line)
            if context_match:
                connection_id, inbound_type, inbound_tag = context_match.groups()
                protocol = PROTOCOL_NAMES.get(inbound_tag, inbound_type)
                contexts[connection_id] = (protocol, now_mono)
            outbound_match = OUTBOUND_RE.search(line)
            if outbound_match:
                connection_id, user, packet_word, raw_destination = outbound_match.groups()
                destination = split_destination(raw_destination)
                if user in VALID_USERS and destination is not None:
                    protocol = contexts.get(connection_id, ("未知", now_mono))[0]
                    host, port = destination
                    writer.submit(
                        (int(time.time()), user, protocol, host, port, "UDP" if packet_word else "TCP")
                    )
            if len(contexts) > 20000:
                contexts = {
                    key: value for key, value in contexts.items()
                    if now_mono - value[1] < 3600
                }
    finally:
        writer.close()
        if process.poll() is None:
            process.terminate()
        return_code = process.wait()
        print(f"sing-box stopped with status {return_code}", flush=True)
    return return_code


if __name__ == "__main__":
    raise SystemExit(main())
PY
chmod 700 /opt/proxy-manager/audit_supervisor.py

cat > /usr/local/sbin/proxy-user-status <<'PY'
#!/usr/bin/env python3
import json
import sqlite3
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

cfg = json.loads(Path("/etc/proxy-manager/config.json").read_text())
billing_timezone = ZoneInfo(cfg.get("billing_timezone", cfg["timezone"]))
conn = sqlite3.connect("/var/lib/proxy-manager/usage.db")
conn.row_factory = sqlite3.Row
rows = {row["name"]: row for row in conn.execute("SELECT * FROM usage")}
print("用户                              已用/总量 GiB          到期时间     状态          续期策略  订阅地址")
for user in cfg["users"]:
    row = rows.get(user["name"])
    used = ((row["upload"] + row["download"]) / 1024**3) if row else 0
    quota = user["quota_bytes"] / 1024**3
    expiry = datetime.fromtimestamp(user["expires_at"], billing_timezone).strftime("%Y-%m-%d %H:%M")
    status = row["blocked_reason"] if row and row["blocked"] else "可用"
    renewal = f"{user['renewal_months']}个月" if user["auto_renew"] else "不续期"
    print(f"{user['name']:<32} {used:9.2f}/{quota:<9g} {expiry}  {status:<12} {renewal:<8}  https://{cfg['domain']}/sub/{user['token']}")
PY
chmod 700 /usr/local/sbin/proxy-user-status

cat > /usr/local/sbin/proxy-audit <<'PY'
#!/usr/bin/env python3
import argparse
import ipaddress
import json
import re
import sqlite3
import sys
import time
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

CONFIG = json.loads(Path("/etc/proxy-manager/config.json").read_text())
DB_PATH = "/var/lib/proxy-manager/audit.db"
TZ = ZoneInfo(CONFIG["timezone"])
RETENTION_DAYS = int(CONFIG.get("audit_retention_days", 7))
DOMAIN_RE = re.compile(
    r"^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*"
    r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$"
)
ALIASES = {}
LABELS = {}
for item in CONFIG["users"]:
    ALIASES[item["name"]] = item["name"]
    ALIASES[item["label"]] = item["name"]
    LABELS[item["name"]] = item["label"]


def arguments():
    parser = argparse.ArgumentParser(
        description="查询最近7天的域名/IP级代理访问审计（不含URL路径和网页内容）"
    )
    parser.add_argument("--user", help="用户编号或标签，例如 user1 或 用户1")
    parser.add_argument("--days", type=int, default=1, help="查询最近几天，范围1-7，默认1")
    parser.add_argument("--domain", help="只看某个域名/IP；域名同时匹配其子域名")
    parser.add_argument("--limit", type=int, default=100, help="最多显示条数，默认100，最大1000")
    parser.add_argument("--summary", action="store_true", help="按用户和目标汇总连接次数")
    return parser.parse_args()


def normalize_filter(value):
    value = value.strip().lower().rstrip(".")
    try:
        return ipaddress.ip_address(value).compressed
    except ValueError:
        try:
            value = value.encode("idna").decode("ascii")
        except UnicodeError:
            raise SystemExit("域名/IP格式不正确")
        if not DOMAIN_RE.fullmatch(value):
            raise SystemExit("域名/IP格式不正确")
        return value


def main():
    args = arguments()
    if not 1 <= args.days <= RETENTION_DAYS:
        raise SystemExit(f"--days 只能是 1 到 {RETENTION_DAYS}")
    if not 1 <= args.limit <= 1000:
        raise SystemExit("--limit 只能是 1 到 1000")
    params = [int(time.time()) - args.days * 86400]
    clauses = ["ts >= ?"]
    if args.user:
        if args.user not in ALIASES:
            raise SystemExit("未知用户，可用值：" + "、".join(LABELS))
        clauses.append("user = ?")
        params.append(ALIASES[args.user])
    if args.domain:
        destination = normalize_filter(args.domain)
        clauses.append("(destination = ? OR destination LIKE ?)")
        params.extend([destination, f"%.{destination}"])
    where = " AND ".join(clauses)
    try:
        conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)
    except sqlite3.OperationalError:
        raise SystemExit("审计数据库尚未创建，请先确认 sing-box 服务已经启动")
    conn.row_factory = sqlite3.Row
    params.append(args.limit)
    if args.summary:
        rows = conn.execute(
            f"SELECT user,destination,COUNT(*) AS connections,MAX(ts) AS latest "
            f"FROM access_events WHERE {where} GROUP BY user,destination "
            f"ORDER BY connections DESC,latest DESC LIMIT ?",
            params,
        ).fetchall()
        print(f"最近 {args.days} 天域名/IP汇总（最多 {args.limit} 条）")
        print("用户    连接次数  最后访问时间         目标域名/IP")
        for row in rows:
            stamp = datetime.fromtimestamp(row["latest"], TZ).strftime("%Y-%m-%d %H:%M:%S")
            print(f"{LABELS.get(row['user'], row['user']):<5} {row['connections']:>8}  {stamp}  {row['destination']}")
    else:
        rows = conn.execute(
            f"SELECT ts,user,protocol,destination,port,network FROM access_events "
            f"WHERE {where} ORDER BY ts DESC,id DESC LIMIT ?",
            params,
        ).fetchall()
        print(f"最近 {args.days} 天访问记录（最多 {args.limit} 条）")
        print("时间                用户    协议                 类型  目标域名/IP:端口")
        for row in rows:
            stamp = datetime.fromtimestamp(row["ts"], TZ).strftime("%Y-%m-%d %H:%M:%S")
            target = f"[{row['destination']}]:{row['port']}" if ":" in row["destination"] else f"{row['destination']}:{row['port']}"
            print(f"{stamp}  {LABELS.get(row['user'], row['user']):<5} {row['protocol']:<20} {row['network']:<4}  {target}")
    if not rows:
        print("没有符合条件的记录。")
    print("\n说明：仅记录目标域名/IP元数据；不记录来源IP、URL路径、查询参数或网页内容。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
chmod 700 /usr/local/sbin/proxy-audit

cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box three-protocol proxy service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/proxy-manager/audit_supervisor.py ${SB_BIN} /etc/sing-box/config.json
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/proxy-manager.service <<'EOF'
[Unit]
Description=Per-user proxy traffic and subscription manager
After=network-online.target sing-box.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/proxy-manager/manager.py
Restart=always
RestartSec=3s
User=root
Group=root
NoNewPrivileges=false
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/nginx/sites-available/proxy-subscription <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root /var/www/html;

    location ^~ /.well-known/acme-challenge/ {
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${DOMAIN};
    server_tokens off;

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    location ^~ /sub/ {
        proxy_pass http://127.0.0.1:8787;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header User-Agent \$http_user_agent;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_buffering off;
        proxy_read_timeout 15s;
        add_header X-Content-Type-Options nosniff always;
        access_log off;
    }

    location / {
        return 404;
    }
}
EOF

install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-proxy-services <<'EOF'
#!/bin/sh
systemctl reload nginx
systemctl restart sing-box
EOF
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-proxy-services

python3 -m py_compile \
  /opt/proxy-manager/manager.py \
  /opt/proxy-manager/audit_supervisor.py \
  /usr/local/sbin/proxy-user-add \
  /usr/local/sbin/proxy-protocol \
  /usr/local/sbin/proxy-update \
  /usr/local/sbin/proxy-user-status \
  /usr/local/sbin/proxy-audit
bash -n /usr/local/sbin/proxy
bash -n /usr/local/sbin/proxy-node-info
sh -n /etc/letsencrypt/renewal-hooks/deploy/reload-proxy-services
nginx -t
"$SB_BIN" check -c /etc/sing-box/config.json
systemctl daemon-reload
systemctl enable sing-box proxy-manager
systemctl restart nginx
systemctl restart sing-box
sleep 2
systemctl restart proxy-manager
sleep 2

if ! systemctl is-active --quiet sing-box; then
  journalctl -u sing-box -n 30 --no-pager
  echo "sing-box 启动失败。"
  exit 1
fi
if ! systemctl is-active --quiet proxy-manager; then
  journalctl -u proxy-manager -n 30 --no-pager
  echo "流量与订阅服务启动失败。"
  exit 1
fi

echo "正在配置 UFW；将先放行当前 SSH 端口 ${SSH_PORT}/TCP……"
ufw allow "${SSH_PORT}/tcp" comment 'SSH - do not delete'
if [[ -n "$OLD_REALITY_PORT" ]]; then
  ufw --force delete allow "${OLD_REALITY_PORT}/tcp" || true
fi
if [[ -n "$OLD_ANYTLS_PORT" ]]; then
  ufw --force delete allow "${OLD_ANYTLS_PORT}/tcp" || true
fi
if [[ -n "$OLD_HY2_HOP_START" && -n "$OLD_HY2_HOP_END" ]]; then
  ufw --force delete allow "${OLD_HY2_HOP_START}:${OLD_HY2_HOP_END}/udp" || true
elif [[ -n "$OLD_HY2_PORT" ]]; then
  ufw --force delete allow "${OLD_HY2_PORT}/udp" || true
fi
if [[ -n "$OLD_SS2022_PORT" ]]; then
  ufw --force delete allow "${OLD_SS2022_PORT}/tcp" || true
fi
if [[ -n "$OLD_TUIC_PORT" ]]; then
  ufw --force delete allow "${OLD_TUIC_PORT}/udp" || true
fi
if [[ -n "$OLD_TROJAN_PORT" ]]; then
  ufw --force delete allow "${OLD_TROJAN_PORT}/tcp" || true
fi
ufw default deny incoming
ufw default allow outgoing
ufw allow 80/tcp comment 'ACME HTTP'
ufw allow 443/tcp comment 'HTTPS subscription'
ufw --force enable

if ! ufw status | grep -q '^Status: active'; then
  echo "UFW 启用失败，安装终止。"
  exit 1
fi

INSTALL_SUCCEEDED=1

COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_CYAN=""
COLOR_RESET=""
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  COLOR_GREEN=$'\033[1;32m'
  COLOR_YELLOW=$'\033[1;33m'
  COLOR_CYAN=$'\033[1;36m'
  COLOR_RESET=$'\033[0m'
fi

echo
printf '%b=== 安装完成 ===%b\n' "$COLOR_GREEN" "$COLOR_RESET"
proxy-node-info
echo
printf '%b下一步%b\n' "$COLOR_YELLOW" "$COLOR_RESET"
printf '  1. 运行 %bproxy%b 打开管理菜单\n' "$COLOR_CYAN" "$COLOR_RESET"
printf '  2. 选择 %b1. 协议管理%b，逐个启用所需协议\n' "$COLOR_CYAN" "$COLOR_RESET"
printf '  3. 选择 %b2. 新增用户%b 创建首个订阅\n' "$COLOR_CYAN" "$COLOR_RESET"
printf '  4. 完整安装信息保存在 %b/root/node-info.txt%b\n' "$COLOR_CYAN" "$COLOR_RESET"
