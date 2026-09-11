#!/bin/sh
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

# POSIX sh 获取脚本所在目录的标准写法
DIR="$(cd "$(dirname "$0")" && pwd)"
PERSIST_FILE="$DIR/.sys_data"
TMP="$DIR/tmp"
BIN="$TMP/xray"
CFG="$TMP/config.json"
LINK_FILE="$DIR/LINK.txt"

# 退出清理 (POSIX trap 只用大写标准信号)
XRAY_PID=""
cleanup() {
  if [ -n "$XRAY_PID" ]; then
    kill "$XRAY_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# ==================== 1. 下载解压 Xray ====================
mkdir -p "$TMP"
ZIP_PATH="$TMP/x.zip"

printf "Downloading Xray...\n"
curl -fsSL "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" -o "$ZIP_PATH"
unzip -o "$ZIP_PATH" xray -d "$TMP" >/dev/null
chmod +x "$BIN"
rm -f "$ZIP_PATH"

# ==================== 2. 状态读取与参数生成 ====================
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

# UUID
if [ -n "$UUID" ]; then
  FINAL_UUID="$UUID"
elif [ -n "$OLD_UUID" ]; then
  FINAL_UUID="$OLD_UUID"
elif [ -f /proc/sys/kernel/random/uuid ]; then
  FINAL_UUID=$(cat /proc/sys/kernel/random/uuid)
else
  FINAL_UUID=$(openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)/\1-\2-\3-\4-\5/')
fi

# Path
if [ -n "$XHTTP_PATH" ]; then
  FINAL_PATH="$XHTTP_PATH"
elif [ -n "$OLD_PATH" ]; then
  FINAL_PATH="$OLD_PATH"
else
  FINAL_PATH="/$(openssl rand -hex 4 2>/dev/null || head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
fi

DEC_KEY="${VLESS_DECRYPTION:-$OLD_DEC}"
ENC_KEY="${VLESS_ENCRYPTION:-$OLD_ENC}"

# 提取 ML-KEM-768
if [ "$ENABLE_PQ" != "false" ]; then
  if [ -z "$DEC_KEY" ] || [ -z "$ENC_KEY" ]; then
    VLESSENC_OUT=$("$BIN" vlessenc 2>/dev/null || true)
    PARSED_DEC=$(printf "%s\n" "$VLESSENC_OUT" | grep -A 2 'ML-KEM-768' | grep '"decryption"' | head -n1 | cut -d'"' -f4 || true)
    PARSED_ENC=$(printf "%s\n" "$VLESSENC_OUT" | grep -A 2 'ML-KEM-768' | grep '"encryption"' | head -n1 | cut -d'"' -f4 || true)
    
    [ -n "$PARSED_DEC" ] && DEC_KEY="$PARSED_DEC"
    [ -n "$PARSED_ENC" ] && ENC_KEY="$PARSED_ENC"
  fi
fi

# 写入持久化配置
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

# ==================== 3. 生成 Xray 配置 ====================
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

# ==================== 4. 后台运行 ====================
"$BIN" -c "$CFG" >/dev/null 2>&1 &
XRAY_PID=$!

# ==================== 5. 生成链接 ====================
URL_QUERY="security=tls&sni=${CUSTOM_DOMAIN}&fp=random&alpn=h2&type=xhttp&path=${FINAL_PATH}"
if [ "$ENABLE_PQ" != "false" ] && [ -n "$ENC_KEY" ]; then
  URL_QUERY="${URL_QUERY}&encryption=${ENC_KEY}"
fi
if [ -n "$FLOW" ]; then
  URL_QUERY="${URL_QUERY}&flow=${FLOW}"
fi

LINK="vless://${FINAL_UUID}@${CDN_HOST}:443?${URL_QUERY}#${LINK_NAME}"

printf "\n%s\n\n" "$LINK"
printf "%s\n" "$LINK" > "$LINK_FILE"
printf "✅ Running...\n"

wait "$XRAY_PID"
