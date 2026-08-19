#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

if [[ ${EUID} -ne 0 ]]; then
  echo "请使用 root 运行：sudo bash $0"
  exit 1
fi

SOURCE_URL="https://raw.githubusercontent.com/ShumTin/st-sb-manager/master/install.sh"
TEMP_DIR=$(mktemp -d)
cleanup() {
  rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

curl -fsSL "$SOURCE_URL" -o "$TEMP_DIR/install.sh"
python3 - "$TEMP_DIR/install.sh" "$TEMP_DIR/proxy-update" <<'PY'
import sys
from pathlib import Path

source_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
source = source_path.read_text(encoding="utf-8")
marker = "cat > /usr/local/sbin/proxy-update <<'PY'\n"
try:
    start = source.index(marker) + len(marker)
    end = source.index("\nPY\nchmod 700 /usr/local/sbin/proxy-update", start)
except ValueError as exc:
    raise SystemExit("远程安装脚本中未找到 proxy-update") from exc
output_path.write_text(source[start:end] + "\n", encoding="utf-8")
PY

python3 -m py_compile "$TEMP_DIR/proxy-update"
install -m 700 "$TEMP_DIR/proxy-update" /usr/local/sbin/proxy-update
exec /usr/local/sbin/proxy-update
