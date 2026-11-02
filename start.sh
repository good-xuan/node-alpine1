#!/bin/sh
set -e

# ==================== 环境变量与默认值 ====================
PORT="${SERVER_PORT:-${PORT:-3000}}"
LINK_NAME="${LINK_NAME:-Node}"
CDN_HOST="${CDN_HOST:-www.visa.com.sg}"
CUSTOM_DOMAIN="${CUSTOM_DOMAIN:-}"
ENABLE_PQ="${ENABLE_PQ:-true}"

# Argo 隧道环境变量
# ARGO_ENABLE: 是否启用 Argo 隧道 (true/false)
# ARGO_AUTH:   固定隧道的 Token (若留空则自动启动 TryCloudflare 临时隧道)
# ARGO_DOMAIN: 固定隧道绑定的域名 (配合 ARGO_AUTH 使用)
ARGO_ENABLE="${ARGO_ENABLE:-true}"
ARGO_AUTH="${ARGO_AUTH:-}"
ARGO_DOMAIN="${ARGO_DOMAIN:-}"

if [ "$ENABLE_PQ" != "false" ]; then
  FLOW="xtls-rprx-vision"
else
  FLOW=""
fi

PORT_FALLBACK=$((PORT + 1))
PORT_CAMOUFLAGE=$((PORT + 2))

DIR="$(cd "$(dirname "$0")" && pwd)"
PERSIST_FILE="$DIR/.sys_data"
TMP="$DIR/tmp"
BIN="$TMP/web"
ARGO_BIN="$TMP/bot"
CFG="$TMP/config.json"
ARGO_LOG="$TMP/argo.log"
LINK_FILE="$DIR/LINK.txt"

# ==================== 退出清理 Hook ====================
XRAY_PID=""
CAMO_PID=""
ARGO_PID=""

cleanup() {
  [ -n "$XRAY_PID" ] && kill "$XRAY_PID" 2>/dev/null || true
  [ -n "$CAMO_PID" ] && kill "$CAMO_PID" 2>/dev/null || true
  [ -n "$ARGO_PID" ] && kill "$ARGO_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ==================== 1. 下载解压 Xray 与 Cloudflared ====================
mkdir -p "$TMP"
ZIP_PATH="$TMP/x.zip"

if [ ! -x "$BIN" ]; then
  curl -fsSL "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" -o "$ZIP_PATH"
  unzip -o "$ZIP_PATH" xray -d "$TMP" >/dev/null
  mv -f "$TMP/xray" "$BIN"
  chmod +x "$BIN"
  rm -f "$ZIP_PATH"
fi

if [ "$ARGO_ENABLE" = "true" ] && [ ! -x "$ARGO_BIN" ]; then
  curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" -o "$ARGO_BIN"
  chmod +x "$ARGO_BIN"
fi

# ==================== 2. 状态读取与参数持久化 ====================
OLD_UUID=""
OLD_PATH=""
OLD_DEC=""
OLD_ENC=""

if [ -f "$PERSIST_FILE" ]; then
  OLD_UUID=$(grep -o '"uuid": *"[^"]*"' "$PERSIST_FILE" 2>/dev/null | cut -d'"' -f4 || true)
  OLD_PATH=$(grep -o '"xhttp": *"[^"]*"' "$PERSIST_FILE" 2>/dev/null | cut -d'"' -f4 || true)
  OLD_DEC=$(grep -o '"decryption": *"[^"]*"' "$PERSIST_FILE" 2>/dev/null | cut -d'"' -f4 || true)
  OLD_ENC=$(grep -o '"encryption": *"[^"]*"' "$PERSIST_FILE" 2>/dev/null | cut -d'"' -f4 || true)
fi

# UUID 生成 / 获取
if [ -n "$UUID" ]; then
  FINAL_UUID="$UUID"
elif [ -n "$OLD_UUID" ]; then
  FINAL_UUID="$OLD_UUID"
elif [ -f /proc/sys/kernel/random/uuid ]; then
  FINAL_UUID=$(cat /proc/sys/kernel/random/uuid)
else
  FINAL_UUID=$(openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)/\1-\2-\3-\4-\5/')
fi

# Path 生成 / 获取
if [ -n "$XHTTP_PATH" ]; then
  FINAL_PATH="$XHTTP_PATH"
elif [ -n "$OLD_PATH" ]; then
  FINAL_PATH="$OLD_PATH"
else
  FINAL_PATH="/$(openssl rand -hex 4 2>/dev/null || head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
fi

DEC_KEY="${VLESS_DECRYPTION:-$OLD_DEC}"
ENC_KEY="${VLESS_ENCRYPTION:-$OLD_ENC}"

# 提取 ML-KEM-768 密钥
if [ "$ENABLE_PQ" != "false" ]; then
  if [ -z "$DEC_KEY" ] || [ -z "$ENC_KEY" ]; then
    VLESSENC_OUT=$("$BIN" vlessenc 2>/dev/null || true)
    PARSED_DEC=$(printf "%s\n" "$VLESSENC_OUT" | grep -A 2 'ML-KEM-768' | grep '"decryption"' | head -n1 | cut -d'"' -f4 || true)
    PARSED_ENC=$(printf "%s\n" "$VLESSENC_OUT" | grep -A 2 'ML-KEM-768' | grep '"encryption"' | head -n1 | cut -d'"' -f4 || true)
    
    [ -n "$PARSED_DEC" ] && DEC_KEY="$PARSED_DEC"
    [ -n "$PARSED_ENC" ] && ENC_KEY="$PARSED_ENC"
  fi
fi

# 保存状态到持久化文件
cat <<EOF > "$PERSIST_FILE"
{
  "uuid": "$FINAL_UUID",
  "xhttp": "$FINAL_PATH",
  "keys": {
    "decryption": "$DEC_KEY",
    "encryption": "$ENC_KEY"
  }
}
EOF

# 优先读取 SUB_PATH 环境变量，若未设置或为空，则回退提取 UUID 后 12 位
UUID_SUFFIX="${SUB_PATH:-$(printf "%s" "$FINAL_UUID" | tr -d '-' | tail -c 12)}"

# ==================== 3. 生成 Xray 配置文件 ====================
ACTUAL_DEC="none"
if [ "$ENABLE_PQ" != "false" ] && [ -n "$DEC_KEY" ]; then
  ACTUAL_DEC="$DEC_KEY"
fi

cat <<EOF > "$CFG"
{
  "log": { "loglevel": "none" },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "fallbacks": [
          { "dest": $PORT_FALLBACK },
          { "path": "/$UUID_SUFFIX", "dest": $PORT_CAMOUFLAGE },
          { "path": "/", "dest": $PORT_CAMOUFLAGE }
        ],
        "decryption": "none"
      }
    },
    {
      "port": $PORT_FALLBACK,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$FINAL_UUID", "flow": "$FLOW" }],
        "decryption": "$ACTUAL_DEC"
      },
      "streamSettings": {
        "sockopt": {
          "trustedXForwardedFor": ["CF-Connecting-IP", "X-Real-IP"],
          "tcpcongestion": "bbr"
        },
        "network": "xhttp",
        "xhttpSettings": { "path": "$FINAL_PATH" }
      }
    }
  ],
  "dns": { "servers": ["https+local://1.1.1.1/dns-query"] },
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "streamSettings": {
        "sockopt": {
          "tcpcongestion": "bbr",
          "domainStrategy": "UseIPv4v6"
        }
      }
    },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF

# ==================== 4. 启动 401 伪装服务、Xray 与 Argo ====================
FIFO="$TMP/camo_fifo"
rm -f "$FIFO"
mkfifo "$FIFO"

(
  RESP_401="HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"Restricted Access\"\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 13\r\nConnection: close\r\n\r\nAccess Denied"

  while true; do
    cat "$FIFO" | ( nc -l -p "$PORT_CAMOUFLAGE" || nc -l "$PORT_CAMOUFLAGE" ) 2>/dev/null | (
      read -r METHOD REQ_PATH PROTOCOL || true
      CLEAN_PATH=$(printf "%s" "$REQ_PATH" | cut -d'?' -f1 | tr -d '\r')

      if [ "$CLEAN_PATH" = "/$UUID_SUFFIX" ] && [ -f "$LINK_FILE" ]; then
        BODY=$(cat "$LINK_FILE")
        BODY_LEN=$(printf "%s" "$BODY" | wc -c | tr -d ' ')
        printf "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s" "$BODY_LEN" "$BODY" > "$FIFO"
      else
        printf "%b" "$RESP_401" > "$FIFO"
      fi
    ) || true
    sleep 0.1
  done
) &
CAMO_PID=$!

# 启动 Xray 核心
"$BIN" run -config "$CFG" >/dev/null 2>&1 &
XRAY_PID=$!

# 启动 Cloudflare Argo 隧道
FINAL_DOMAIN="${CUSTOM_DOMAIN:-$CDN_HOST}"
if [ "$ARGO_ENABLE" = "true" ]; then
  rm -f "$ARGO_LOG"
  if [ -n "$ARGO_AUTH" ]; then
    # 固定隧道 (Token 模式)
    "$ARGO_BIN" tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token "$ARGO_AUTH" >"$ARGO_LOG" 2>&1 &
    ARGO_PID=$!
    [ -n "$ARGO_DOMAIN" ] && FINAL_DOMAIN="$ARGO_DOMAIN"
  else
    # 临时隧道 (TryCloudflare 模式，直接转发至 $PORT 主端口以同时支持节点分流与订阅路径)
    "$ARGO_BIN" tunnel --no-autoupdate --edge-ip-version auto --protocol http2 --url "http://127.0.0.1:${PORT}" >"$ARGO_LOG" 2>&1 &
    ARGO_PID=$!
    
    # 轮询提取 TryCloudflare 分配的临时域名 (最长等待 15 秒)
    for _ in $(seq 1 15); do
      TRY_DOMAIN=$(grep -o 'https://[-a-zA-Z0-9.]*\.trycloudflare\.com' "$ARGO_LOG" 2>/dev/null | head -n1 | sed 's#https://##' || true)
      if [ -n "$TRY_DOMAIN" ]; then
        FINAL_DOMAIN="$TRY_DOMAIN"
        break
      fi
      sleep 1
    done
  fi
fi

# ==================== 5. 生成与输出节点链接 ====================
URL_QUERY="security=tls&sni=${FINAL_DOMAIN}&host=${FINAL_DOMAIN}&fp=random&alpn=h2&type=xhttp&path=${FINAL_PATH}"
if [ "$ENABLE_PQ" != "false" ] && [ -n "$ENC_KEY" ]; then
  URL_QUERY="${URL_QUERY}&encryption=${ENC_KEY}"
fi
if [ -n "$FLOW" ]; then
  URL_QUERY="${URL_QUERY}&flow=${FLOW}"
fi

LINK="vless://${FINAL_UUID}@${CDN_HOST}:443?${URL_QUERY}#${LINK_NAME}"

printf "%s\n" "$LINK" > "$LINK_FILE"
printf "✅ Running...\n"
printf "🌐 Domain: %s\n" "$FINAL_DOMAIN"
printf "🔗 Sub URL: https://%s/%s\n" "$FINAL_DOMAIN" "$UUID_SUFFIX"

# ==================== 6. 健康检查守护循环 ====================
FAIL_COUNT=0
MAX_FAILS=3
CHECK_INTERVAL=10

sleep 2

while true; do
  XRAY_ALIVE=true
  SUB_ALIVE=true
  ARGO_ALIVE=true

  # 1. 检测 Xray 进程存活
  if ! kill -0 "$XRAY_PID" 2>/dev/null; then
    XRAY_ALIVE=false
  fi

  # 2. 检测 Argo 进程存活
  if [ "$ARGO_ENABLE" = "true" ] && ! kill -0 "$ARGO_PID" 2>/dev/null; then
    ARGO_ALIVE=false
  fi

  # 3. 检测 Sub 订阅服务是否返回 HTTP 200
  SUB_STATUS=$(curl -s -m 3 -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT_CAMOUFLAGE}/${UUID_SUFFIX}" 2>/dev/null || echo "000")
  if [ "$SUB_STATUS" != "200" ]; then
    SUB_ALIVE=false
  fi

  # 4. 失败计数与重启判定
  if [ "$XRAY_ALIVE" = "false" ] || [ "$SUB_ALIVE" = "false" ] || [ "$ARGO_ALIVE" = "false" ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf "⚠️ Health check failed (%d/%d): Xray=%s, Argo=%s, Sub=%s (HTTP %s)\n" \
      "$FAIL_COUNT" "$MAX_FAILS" "$XRAY_ALIVE" "$ARGO_ALIVE" "$SUB_ALIVE" "$SUB_STATUS"
    
    if [ "$FAIL_COUNT" -ge "$MAX_FAILS" ]; then
      printf "❌ Threshold reached. Restarting script...\n"
      cleanup
      trap - EXIT INT TERM
      exec "$0" "$@"
    fi
  else
    FAIL_COUNT=0
  fi

  sleep "$CHECK_INTERVAL"
done
