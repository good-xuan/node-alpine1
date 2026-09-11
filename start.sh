#!/usr/bin/env bash
set -e

# ==================== 环境变量与默认值 ====================
PORT="${SERVER_PORT:-${PORT:-3000}}"
LINK_NAME="${LINK_NAME:-Node}"
CDN_HOST="${CDN_HOST:-www.visa.com.sg}"
CUSTOM_DOMAIN="${CUSTOM_DOMAIN:-www.visa.com.sg}"
ENABLE_PQ="${ENABLE_PQ:-true}"

if [ "$ENABLE_PQ" != "false" ]; then
  FLOW="xtls-rprx-vision"
else
  FLOW=""
fi

PORT_FALLBACK=$((PORT + 1))
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERSIST_FILE="$DIR/.sys_data"
TMP="$DIR/tmp"
BIN="$TMP/xray"
CFG="$TMP/config.json"
LINK_FILE="$DIR/LINK.txt"

# 退出清理
XRAY_PID=""
cleanup() {
  [ -n "$XRAY_PID" ] && kill "$XRAY_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ==================== 1. 下载解压 Xray ====================
mkdir -p "$TMP"
ZIP_PATH="$TMP/x.zip"

echo "Downloading Xray..."
curl -fsSL "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" -o "$ZIP_PATH"
unzip -o "$ZIP_PATH" xray -d "$TMP" >/dev/null
chmod +x "$BIN"
rm -f "$ZIP_PATH"

# ==================== 2. 状态读取与参数生成 (纯 Shell) ====================
# 读取历史数据
OLD_UUID=""
OLD_PATH=""
OLD_DEC=""
OLD_ENC=""

if [ -f "$PERSIST_FILE" ]; then
  OLD_UUID=$(grep -o '"uuid": *"[^"]*"' "$PERSIST_FILE" | cut -d'"' -f4 || true)
  OLD_PATH=$(grep -o '"xhttp": *"[^"]*"' "$PERSIST_FILE" | cut -d'"' -f4 || true)
  OLD_DEC=$(grep -o '"decryption": *"[^"]*"' "$PERSIST_FILE" | cut -d'"' -f4 || true)
  OLD_ENC=$(grep -o '"encryption": *"[^"]*"' "$PERSIST_FILE" | cut -d'"' -f4 || true)
fi

# UUID 优先顺序: 环境变量 > .sys_data > 系统随机生成
if [ -n "$UUID" ]; then
  FINAL_UUID="$UUID"
elif [ -n "$OLD_UUID" ]; then
  FINAL_UUID="$OLD_UUID"
elif [ -f /proc/sys/kernel/random/uuid ]; then
  FINAL_UUID=$(cat /proc/sys/kernel/random/uuid)
else
  FINAL_UUID=$(openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')
fi

# XHTTP Path 优先顺序
if [ -n "$XHTTP_PATH" ]; then
  FINAL_PATH="$XHTTP_PATH"
elif [ -n "$OLD_PATH" ]; then
  FINAL_PATH="$OLD_PATH"
else
  FINAL_PATH="/$(head -c 4 /dev/urandom | xxd -p 2>/dev/null || openssl rand -hex 4)"
fi

DEC_KEY="${VLESS_DECRYPTION:-$OLD_DEC}"
ENC_KEY="${VLESS_ENCRYPTION:-$OLD_ENC}"

# PQ 密钥生成
if [ "$ENABLE_PQ" != "false" ] && { [ -z "$DEC_KEY" ] || [ -z "$ENC_KEY" ]; }; then
  VLESSENC_OUT=$("$BIN" vlessenc 2>/dev/null || true)
  PARSED_DEC=$(echo "$VLESSENC_OUT" | grep -A 2 'ML-KEM-768' | grep '"decryption"' | head -n1 | cut -d'"' -f4 || true)
  PARSED_ENC=$(echo "$VLESSENC_OUT" | grep -A 2 'ML-KEM-768' | grep '"encryption"' | head -n1 | cut -d'"' -f4 || true)
  
  [ -n "$PARSED_DEC" ] && DEC_KEY="$PARSED_DEC"
  [ -n "$PARSED_ENC" ] && ENC_KEY="$PARSED_ENC"
fi

# 保存状态到 .sys_data (纯文本写入)
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

# ==================== 3. 纯 Shell 生成 Xray 配置 ====================
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
          { "path": "/", "dest": 401 }
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
  "dns": { "servers": ["https+local://1.1.1.1/dns-query", "localhost"] },
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "streamSettings": {
        "finalmask": {
          "tcp": [
            {
              "type": "fragment",
              "settings": {
                "packets": "tlshello",
                "length": "100-200",
                "delay": "10-20",
                "maxSplit": "3-6"
              }
            }
          ]
        },
        "sockopt": {
          "tcpcongestion": "bbr",
          "domainStrategy": "UseIP",
          "happyEyeballs": { "tryDelayMs": 250 }
        }
      }
    },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF

# ==================== 4. 启动 Xray 核心 ====================
"$BIN" -c "$CFG" >/dev/null 2>&1 &
XRAY_PID=$!

# ==================== 5. 拼接节点链接 ====================
ENCODED_REMARK=$(echo -n "$LINK_NAME" | od -An -tx1 | tr ' ' % | tr -d '\n' | tr '[:lower:]' '[:upper:]')
[ -z "$ENCODED_REMARK" ] && ENCODED_REMARK="$LINK_NAME"

URL_QUERY="security=tls&sni=${CUSTOM_DOMAIN}&fp=random&alpn=h2&type=xhttp&path=${FINAL_PATH}"
if [ "$ENABLE_PQ" != "false" ] && [ -n "$ENC_KEY" ]; then
  URL_QUERY="${URL_QUERY}&encryption=${ENC_KEY}"
fi
if [ -n "$FLOW" ]; then
  URL_QUERY="${URL_QUERY}&flow=${FLOW}"
fi

LINK="vless://${FINAL_UUID}@${CDN_HOST}:443?${URL_QUERY}#${ENCODED_REMARK}"

echo -e "\n${LINK}\n"
echo "$LINK" > "$LINK_FILE"
echo "✅ Running..."

wait "$XRAY_PID"
