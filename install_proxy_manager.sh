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
cleanup() {
  local exit_code=$?
  if [[ "$TEMP_SWAP" == "1" ]] && swapon --show=NAME --noheadings | grep -qx '/swapfile-proxy-build'; then
    swapoff /swapfile-proxy-build || true
  fi
  if [[ "$TEMP_SWAP_CREATED" == "1" ]]; then
    rm -f /swapfile-proxy-build
  fi
  if [[ -n "$BUILD_ROOT" && -d "$BUILD_ROOT" ]]; then
    rm -rf -- "$BUILD_ROOT"
  fi
  if [[ "$INSTALL_SUCCEEDED" != "1" ]]; then
    if [[ "$SING_BOX_WAS_ACTIVE" == "1" ]]; then
      systemctl start sing-box >/dev/null 2>&1 || true
    fi
    if [[ "$PROXY_MANAGER_WAS_ACTIVE" == "1" ]]; then
      systemctl start proxy-manager >/dev/null 2>&1 || true
    fi
  fi
  return "$exit_code"
}
trap cleanup EXIT
trap 'echo "安装在第 ${LINENO} 行失败，请保留终端报错信息。" >&2' ERR

echo "=== 三协议动态用户管理 + 独立流量/到期策略 + 7天域名审计安装程序 ==="
echo "协议：VLESS+REALITY、AnyTLS、Hysteria2"
echo "说明：安装后使用 proxy-user-add 按需创建用户；重新安装会使旧订阅失效。"
echo
read -r -p "请输入节点域名（例如 node.example.com）: " DOMAIN
read -r -p "请输入用于 Let's Encrypt 的真实邮箱: " EMAIL
read -r -p "请输入 VPS 标称带宽 Mbps（1 Gbps 填 1000，直接回车默认 1000）: " BANDWIDTH
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
SSH_PORT=${SSH_PORT:-$DETECTED_SSH_PORT}
echo
echo "可从 KiwiVM API 获取搬瓦工精确流量重置时间；API Key 仅用于本次查询，不会保存。"
read -r -p "请输入 KiwiVM VEID（直接回车跳过自动同步）: " KIWIVM_VEID
KIWIVM_API_KEY=""
if [[ -n "$KIWIVM_VEID" ]]; then
  read -r -s -p "请输入 KiwiVM API Key: " KIWIVM_API_KEY
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
  /etc/proxy-manager \
  /var/lib/proxy-manager \
  /opt/proxy-manager \
  /root/node-info.txt \
  /root/proxy-links.txt; do
  if [[ -e "$old_path" ]]; then
    cp -a --parents "$old_path" "$BACKUP_DIR/"
  fi
done

OLD_REALITY_PORT=""
OLD_ANYTLS_PORT=""
OLD_HY2_PORT=""
if [[ -f /etc/proxy-manager/config.json ]]; then
  mapfile -t OLD_PORT_VALUES < <(python3 - <<'PY' || true
import json

try:
    with open("/etc/proxy-manager/config.json", encoding="utf-8") as handle:
        ports = json.load(handle)["ports"]
    for name in ("reality", "anytls", "hysteria2"):
        print(int(ports[name]))
except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError):
    pass
PY
  )
  if (( ${#OLD_PORT_VALUES[@]} == 3 )); then
    OLD_REALITY_PORT=${OLD_PORT_VALUES[0]}
    OLD_ANYTLS_PORT=${OLD_PORT_VALUES[1]}
    OLD_HY2_PORT=${OLD_PORT_VALUES[2]}
  fi
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  curl ca-certificates openssl nginx certbot iproute2 ufw \
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
  if [[ -z "$(swapon --show=NAME --noheadings)" ]]; then
    fallocate -l 2G /swapfile-proxy-build
    TEMP_SWAP_CREATED=1
    chmod 600 /swapfile-proxy-build
    mkswap /swapfile-proxy-build >/dev/null
    swapon /swapfile-proxy-build
    TEMP_SWAP=1
  fi
  BUILD_ROOT=$(mktemp -d /opt/proxy-build.XXXXXX)
  BUILD_BIN_DIR="$BUILD_ROOT/bin"
  GO_ARCHIVE="$BUILD_ROOT/go.tar.gz"
  mkdir -p "$BUILD_BIN_DIR"
  GO_VERSION=$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1)
  curl -fL "https://go.dev/dl/${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -o "$GO_ARCHIVE"
  tar -C "$BUILD_ROOT" -xzf "$GO_ARCHIVE"
  SB_VERSION=$($SB_BIN version | awk '/sing-box version/ {gsub(/^v/, "", $3); print $3; exit}')
  if [[ -z "$SB_VERSION" ]]; then
    echo "无法识别 sing-box 版本。"
    exit 1
  fi
  HOME=/root GOBIN="$BUILD_BIN_DIR" CGO_ENABLED=0 GOMAXPROCS=1 \
    GOFLAGS='-p=1 -tags=with_quic,with_utls,with_v2ray_api' \
    "$BUILD_ROOT/go/bin/go" install "github.com/sagernet/sing-box/cmd/sing-box@v${SB_VERSION}"
  install -m 755 "$BUILD_BIN_DIR/sing-box" /usr/local/bin/sing-box
  SB_BIN=/usr/local/bin/sing-box
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

(
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
)

install -d -m 700 /etc/sing-box /etc/proxy-manager /opt/proxy-manager
install -d -m 700 /var/lib/proxy-manager
if systemctl is-active --quiet sing-box 2>/dev/null; then
  SING_BOX_WAS_ACTIVE=1
fi
if systemctl is-active --quiet proxy-manager 2>/dev/null; then
  PROXY_MANAGER_WAS_ACTIVE=1
fi
systemctl stop proxy-manager sing-box 2>/dev/null || true
rm -f /var/lib/proxy-manager/usage.db /var/lib/proxy-manager/usage.db-shm /var/lib/proxy-manager/usage.db-wal
rm -f /var/lib/proxy-manager/audit.db /var/lib/proxy-manager/audit.db-shm /var/lib/proxy-manager/audit.db-wal

DOMAIN="$DOMAIN" BANDWIDTH="$BANDWIDTH" SSH_PORT="$SSH_PORT" BACKUP_DIR="$BACKUP_DIR" SB_BIN="$SB_BIN" PROVIDER_NEXT_RESET="$PROVIDER_NEXT_RESET" python3 <<'PY'
import json
import os
import re
import secrets
import socket
import subprocess
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

def run(*args):
    return subprocess.check_output(args, text=True).strip()

def random_port(used):
    for _ in range(1000):
        port = secrets.randbelow(40001) + 20000
        if port in used:
            continue
        tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            tcp.bind(("0.0.0.0", port))
            udp.bind(("0.0.0.0", port))
        except OSError:
            tcp.close()
            udp.close()
            continue
        tcp.close()
        udp.close()
        used.add(port)
        return port
    raise RuntimeError("无法生成空闲随机端口")

used_ports = {80, 443, 8080, 8787, ssh_port}
port_names = ["reality", "anytls", "hysteria2"]
ports = {name: random_port(used_ports) for name in port_names}

keypair = run(sb_bin, "generate", "reality-keypair")
private_match = re.search(r"PrivateKey:\s*(\S+)", keypair, re.I)
public_match = re.search(r"PublicKey:\s*(\S+)", keypair, re.I)
if not private_match or not public_match:
    raise RuntimeError("REALITY 密钥生成失败")
reality_private = private_match.group(1)
reality_public = public_match.group(1)
short_id = secrets.token_hex(8)
reality_server = "www.cloudflare.com"
hy2_obfs = secrets.token_hex(16)

users = []

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
    "reality_private_key": reality_private,
    "reality_public_key": reality_public,
    "reality_short_id": short_id,
    "reality_server": reality_server,
    "hy2_obfs_password": hy2_obfs,
    "users": users,
}

Path("/etc/sing-box/config.json").write_text(json.dumps(singbox_config, ensure_ascii=False, indent=2) + "\n")
Path("/etc/proxy-manager/config.json").write_text(json.dumps(manager_config, ensure_ascii=False, indent=2) + "\n")

protocol_lines = [
    ("TCP", ports["reality"], "VLESS + REALITY"),
    ("TCP", ports["anytls"], "AnyTLS"),
    ("UDP", ports["hysteria2"], "Hysteria2"),
]
info = [
    f"域名: {domain}",
    "用户管理: 安装后运行 proxy-user-add 按需创建",
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
]
info += [f"{proto:<7} {port:<5} {name}" for proto, port, name in protocol_lines]
info += [
    "",
    "日常管理命令：",
    "proxy                              打开交互式管理菜单",
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
import math
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
                last_download INTEGER NOT NULL DEFAULT 0
            )
        """)
        columns = {row[1] for row in conn.execute("PRAGMA table_info(usage)")}
        if "blocked_reason" not in columns:
            conn.execute("ALTER TABLE usage ADD COLUMN blocked_reason TEXT NOT NULL DEFAULT ''")
        if "last_upload" not in columns:
            conn.execute("ALTER TABLE usage ADD COLUMN last_upload INTEGER NOT NULL DEFAULT 0")
        if "last_download" not in columns:
            conn.execute("ALTER TABLE usage ADD COLUMN last_download INTEGER NOT NULL DEFAULT 0")
        period = datetime.now(TZ).strftime("%Y-%m-%d")
        for name in USERS_BY_NAME:
            conn.execute(
                "INSERT OR IGNORE INTO usage(name, upload, download, period, blocked) VALUES(?,0,0,?,0)",
                (name, period),
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
                    (upload_delta, download_delta, current_upload, current_download, name),
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
    days = max(0, math.ceil((expiry - datetime.now(BILLING_TZ)).total_seconds() / 86400))
    state = row["blocked_reason"] if row["blocked"] else "可用"
    renewal = "自动续期" if user["auto_renew"] else "到期停用"
    return f"剩余流量：{gib:.1f} GiB（{state}）", f"有效期：{days} 天（{renewal}）"

def uri_links(user, row):
    d = CONFIG["domain"]
    p = CONFIG["ports"]
    name1, name2 = status_names(user, row)
    def tag(value):
        return quote(value, safe="")
    links = [
        f"vless://{user['vless_reality_uuid']}@{d}:{p['reality']}?encryption=none&flow=xtls-rprx-vision&security=reality&sni={CONFIG['reality_server']}&fp=chrome&pbk={CONFIG['reality_public_key']}&sid={CONFIG['reality_short_id']}&type=tcp#{tag('01 VLESS-REALITY')}",
        f"anytls://{quote(user['anytls_password'], safe='')}@{d}:{p['anytls']}?security=tls&sni={d}&fp=chrome&type=tcp#{tag('02 AnyTLS')}",
        f"hysteria2://{quote(user['hy2_password'], safe='')}@{d}:{p['hysteria2']}/?sni={d}&obfs=salamander&obfs-password={quote(CONFIG['hy2_obfs_password'], safe='')}#{tag('03 Hysteria2')}",
    ]
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
    info1, info2 = status_names(user, row)
    actual = [
        {
            "name": "01 VLESS-REALITY", "type": "vless", "server": d, "port": p["reality"],
            "uuid": user["vless_reality_uuid"], "network": "tcp", "tls": True, "udp": True,
            "flow": "xtls-rprx-vision", "servername": CONFIG["reality_server"], "client-fingerprint": "chrome",
            "reality-opts": {"public-key": CONFIG["reality_public_key"], "short-id": CONFIG["reality_short_id"]},
        },
        {
            "name": "02 AnyTLS", "type": "anytls", "server": d, "port": p["anytls"],
            "password": user["anytls_password"], "sni": d, "udp": True,
            "skip-cert-verify": False, "client-fingerprint": "chrome",
        },
        {
            "name": "03 Hysteria2", "type": "hysteria2", "server": d, "port": p["hysteria2"],
            "password": user["hy2_password"], "sni": d, "skip-cert-verify": False,
            "obfs": "salamander", "obfs-password": CONFIG["hy2_obfs_password"],
        },
    ]
    info = [
        {"name": info1, "type": "ss", "server": "127.0.0.1", "port": 1, "cipher": "aes-128-gcm", "password": "info-only"},
        {"name": info2, "type": "ss", "server": "127.0.0.1", "port": 2, "cipher": "aes-128-gcm", "password": "info-only"},
    ]
    names = [item["name"] for item in actual]
    config = {
        "mixed-port": 7890,
        "allow-lan": False,
        "mode": "rule",
        "log-level": "info",
        "ipv6": True,
        "proxies": info + actual,
        "proxy-groups": [
            {"name": "节点选择", "type": "select", "proxies": ["自动选择"] + names},
            {"name": "自动选择", "type": "url-test", "proxies": names, "url": "https://www.gstatic.com/generate_204", "interval": 300},
            {"name": "套餐信息", "type": "select", "proxies": [info1, info2]},
        ],
        "rules": ["MATCH,节点选择"],
    }
    return yaml.safe_dump(config, allow_unicode=True, sort_keys=False)

def quanx_subscription(user, row):
    d = CONFIG["domain"]
    p = CONFIG["ports"]
    info1, info2 = status_names(user, row)
    lines = [
        f"shadowsocks=127.0.0.1:1, method=aes-128-gcm, password=info-only, udp-relay=false, tag={info1}",
        f"shadowsocks=127.0.0.1:2, method=aes-128-gcm, password=info-only, udp-relay=false, tag={info2}",
        f"vless={d}:{p['reality']}, method=none, password={user['vless_reality_uuid']}, obfs=over-tls, obfs-host={CONFIG['reality_server']}, reality-base64-pubkey={CONFIG['reality_public_key']}, reality-hex-shortid={CONFIG['reality_short_id']}, vless-flow=xtls-rprx-vision, udp-relay=true, tag=01 VLESS-REALITY",
        f"anytls={d}:{p['anytls']}, password={user['anytls_password']}, over-tls=true, tls-host={d}, tls-verification=true, udp-relay=true, tag=02 AnyTLS",
        "shadowsocks=127.0.0.1:3, method=aes-128-gcm, password=unsupported, udp-relay=false, tag=03 Hysteria2（QuanX不支持）",
    ]
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
        self.send_header("Profile-Title", f"Personal-3Protocol-{user['label']}")
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
        parser.add_argument("--quota-gib", help="本有效期流量额度，单位 GiB")
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
        quota_text = self.prompt(self.args.quota_gib, "流量额度 GiB（例如 200）: ")
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

    @staticmethod
    def create_credentials(values):
        return {
            **values,
            "label": values["name"],
            "token": secrets.token_hex(32),
            "vless_reality_uuid": str(uuid.uuid4()),
            "anytls_password": secrets.token_hex(16),
            "hy2_password": secrets.token_hex(16),
        }

    def ensure_unique(self, name):
        if any(user["name"] == name for user in self.manager_config["users"]):
            raise ValueError(f"用户 {name} 已存在")

    def build_singbox_config(self):
        config = self.manager_config
        users = config["users"]
        domain = config["domain"]
        ports = config["ports"]
        tls = {
            "enabled": True,
            "server_name": domain,
            "min_version": "1.2",
            "certificate_path": f"/etc/letsencrypt/live/{domain}/fullchain.pem",
            "key_path": f"/etc/letsencrypt/live/{domain}/privkey.pem",
        }
        inbounds = [
            {
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
            },
            {
                "type": "anytls", "tag": "anytls-in", "listen": "0.0.0.0",
                "listen_port": ports["anytls"],
                "users": [{"name": u["name"], "password": u["anytls_password"]} for u in users],
                "tls": tls,
            },
            {
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
            },
        ]
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
                "INSERT INTO usage(name,upload,download,period,blocked,blocked_reason) VALUES(?,0,0,?,0,'')",
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
  echo
  echo "================ 代理节点管理 ================"
  echo "1) 新增用户             proxy-user-add"
  echo "2) 查看所有用户         proxy-user-status"
  echo "3) 最近24小时访问审计   proxy-audit"
  echo "4) 最近7天访问汇总      proxy-audit --summary --days 7"
  echo "5) 检查 sing-box 配置   sing-box check"
  echo "6) 查看服务状态         systemctl status"
  echo "7) 查看最近服务日志     journalctl"
  echo "8) 查看防火墙规则       ufw status numbered"
  echo "9) 查看节点安装信息     /root/node-info.txt"
  echo "0) 退出"
  echo "==============================================="
}

add_user() {
  proxy-user-add
}

show_users() {
  proxy-user-status
}

show_recent_audit() {
  proxy-audit
}

show_audit_summary() {
  proxy-audit --summary --days 7
}

check_singbox_config() {
  local binary
  binary=$(python3 -c "import json; print(json.load(open('/etc/proxy-manager/config.json'))['singbox_binary'])")
  "$binary" check -c /etc/sing-box/config.json
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

show_firewall() {
  ufw status numbered
}

show_node_info() {
  cat /root/node-info.txt
}

while true; do
  show_menu
  read -r -p "请输入数字选择: " choice
  echo
  case "$choice" in
    1) add_user ;;
    2) show_users ;;
    3) show_recent_audit ;;
    4) show_audit_summary ;;
    5) check_singbox_config ;;
    6) show_service_status ;;
    7) show_service_logs ;;
    8) show_firewall ;;
    9) show_node_info ;;
    0)
      echo "已退出代理节点管理。"
      exit 0
      ;;
    *)
      echo "无效选择，请输入 0-9。"
      ;;
  esac
  pause_menu
done
EOF
chmod 700 /usr/local/sbin/proxy

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
  /usr/local/sbin/proxy-user-status \
  /usr/local/sbin/proxy-audit
bash -n /usr/local/sbin/proxy
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

mapfile -t PORT_VALUES < <(python3 - <<'PY'
import json
cfg = json.load(open('/etc/proxy-manager/config.json'))
for key in ('reality','anytls','hysteria2'):
    print(cfg['ports'][key])
PY
)
REALITY_PORT=${PORT_VALUES[0]}
ANYTLS_PORT=${PORT_VALUES[1]}
HY2_PORT=${PORT_VALUES[2]}

echo "正在配置 UFW；将先放行当前 SSH 端口 ${SSH_PORT}/TCP……"
ufw allow "${SSH_PORT}/tcp" comment 'SSH - do not delete'
if [[ -n "$OLD_REALITY_PORT" && "$OLD_REALITY_PORT" != "$REALITY_PORT" ]]; then
  ufw --force delete allow "${OLD_REALITY_PORT}/tcp" || true
fi
if [[ -n "$OLD_ANYTLS_PORT" && "$OLD_ANYTLS_PORT" != "$ANYTLS_PORT" ]]; then
  ufw --force delete allow "${OLD_ANYTLS_PORT}/tcp" || true
fi
if [[ -n "$OLD_HY2_PORT" && "$OLD_HY2_PORT" != "$HY2_PORT" ]]; then
  ufw --force delete allow "${OLD_HY2_PORT}/udp" || true
fi
ufw default deny incoming
ufw default allow outgoing
ufw allow 80/tcp comment 'ACME HTTP'
ufw allow 443/tcp comment 'HTTPS subscription'
ufw allow "${REALITY_PORT}/tcp" comment 'VLESS REALITY'
ufw allow "${ANYTLS_PORT}/tcp" comment 'AnyTLS'
ufw allow "${HY2_PORT}/udp" comment 'Hysteria2'
ufw --force enable

if ! ufw status | grep -q '^Status: active'; then
  echo "UFW 启用失败，安装终止。"
  exit 1
fi

INSTALL_SUCCEEDED=1

echo
echo "=== 安装完成 ==="
cat /root/node-info.txt
echo
echo "打开交互式管理菜单：proxy"
echo "也可直接新增用户：proxy-user-add"
echo "也可直接查看用户状态：proxy-user-status"
echo "查看最近24小时访问：proxy-audit"
echo "查看7天访问汇总：proxy-audit --summary --days 7"
echo "查看服务状态：systemctl status sing-box proxy-manager --no-pager"
echo "查看防火墙规则：ufw status numbered"
echo "完整信息文件：/root/node-info.txt"
echo "安装时不会预建用户，请现在运行 proxy 并选择 1 新增用户。"
