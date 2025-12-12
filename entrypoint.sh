#!/usr/bin/env bash
set -euo pipefail

exec 2>&1
trap 'echo "ERROR: exit at line $LINENO"; exit 1' ERR

BIN="${BIN:-/usr/local/bin/3proxy}"

# ==== 可在容器后台用环境变量改 ====
SOCKS_COUNT="${SOCKS_COUNT:-5}"                 # 默认 5 个节点/账号
SOCKS_MODE="${SOCKS_MODE:-2}"                   # 1=单端口多用户；2=多端口多用户
SOCKS_PUBLIC_PORT="${SOCKS_PUBLIC_PORT:-$SOCKS_START_PORT}"
SOCKS_START_PORT="${SOCKS_START_PORT:-${PORT:-30000}}"   # 起始端口（MODE=2 时会用到 port..port+count-1）
SOCKS_HOST="${SOCKS_HOST:-}"                    # 不填就尝试自动探测；探测失败就输出 <YOUR_IP>
SOCKS_DIR="${SOCKS_DIR:-/tmp/auto3proxy}"                 # 配置/导出保存目录（可挂载持久化）
SOCKS_CONFIG_PATH="${SOCKS_CONFIG_PATH:-$SOCKS_DIR/3proxy.cfg}"
SOCKS_EXPORT_PATH="${SOCKS_EXPORT_PATH:-$SOCKS_DIR/socks5_export.txt}"
SOCKS_LOG="${SOCKS_LOG:-/dev/null}"             # 想看 3proxy 日志可设为 /dev/stdout

mkdir -p "$SOCKS_DIR"

get_host() {
  if [ -n "$SOCKS_HOST" ]; then return 0; fi
  SOCKS_HOST="$(curl -s -4 ifconfig.me || true)"
  [ -z "${SOCKS_HOST:-}" ] && SOCKS_HOST="$(curl -s -4 icanhazip.com || true)"
  [ -z "${SOCKS_HOST:-}" ] && SOCKS_HOST="<YOUR_IP>"
}

init_config() {
  mkdir -p "$(dirname "$SOCKS_CONFIG_PATH")"
  mkdir -p "$(dirname "$SOCKS_EXPORT_PATH")"

  cat > "$SOCKS_CONFIG_PATH" <<EOF
nserver 8.8.8.8
nserver 1.1.1.1
nscache 65536
timeouts 1 5 30 60 180 180 15 60
maxconn 100

# 容器里不要 daemon（保持前台运行，容器才不会退出）
auth strong
log $SOCKS_LOG
EOF
}

rand_user() { echo "u$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)"; }
rand_pass() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 18; }

generate() {
  get_host
  init_config

  echo "================ SOCKS5 list ================" > "$SOCKS_EXPORT_PATH"
  echo ">>> Generating $SOCKS_COUNT node(s), mode=$SOCKS_MODE, start_port=$SOCKS_START_PORT"

  if [ "$SOCKS_MODE" = "1" ]; then
    # 单端口多用户：只需要在平台暴露一个端口
    for ((i=0; i<SOCKS_COUNT; i++)); do
      u="$(rand_user)"; p="$(rand_pass)"
      echo "users $u:CL:$p" >> "$SOCKS_CONFIG_PATH"
      echo "allow $u" >> "$SOCKS_CONFIG_PATH"
      echo "$SOCKS_HOST:$SOCKS_START_PORT:$u:$p" >> "$SOCKS_EXPORT_PATH"
    done
    echo "socks -p$SOCKS_START_PORT -i0.0.0.0" >> "$SOCKS_CONFIG_PATH"
    echo "flush" >> "$SOCKS_CONFIG_PATH"
  else
    # 多端口多用户：每个账号一个端口（更直观，但需要平台暴露多个端口）
    for ((i=0; i<SOCKS_COUNT; i++)); do
      port=$((SOCKS_START_PORT + i))
      u="$(rand_user)"; p="$(rand_pass)"
      echo "users $u:CL:$p" >> "$SOCKS_CONFIG_PATH"
      echo "allow $u" >> "$SOCKS_CONFIG_PATH"
      echo "socks -p$port -i0.0.0.0" >> "$SOCKS_CONFIG_PATH"
      echo "flush" >> "$SOCKS_CONFIG_PATH"
      echo "$SOCKS_HOST:$SOCKS_PUBLIC_PORT:$u:$p" >> "$SOCKS_EXPORT_PATH"
    done
  fi

  echo "========================================================"
  echo "Generated SOCKS5 nodes (also saved to $SOCKS_EXPORT_PATH):"
  cat "$SOCKS_EXPORT_PATH"
  echo "========================================================"
}

main() {
  generate
  echo ">>> Starting 3proxy in foreground..."
  exec "$BIN" "$SOCKS_CONFIG_PATH"
}

main "$@"
