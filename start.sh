#!/bin/sh

set -eu

BASE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
TMP="$BASE_DIR/tmp"
PUBLIC_DIR="$BASE_DIR/public"
STATE_FILE="$BASE_DIR/.sys_data"
LINK_FILE="$BASE_DIR/LINK.txt"
CONFIG_FILE="$TMP/config.json"
ZIP_FILE="$TMP/xray.zip"
BIN_FILE="$TMP/xray"

PORT="${SERVER_PORT:-${PORT:-3000}}"
UUID="${UUID:-}"
LINK_NAME="${LINK_NAME:-Node}"
CDN_HOST="${CDN_HOST:-www.visa.com.sg}"
SERVER_IP="${SERVER_IP:-127.0.0.1}"
CUSTOM_DOMAIN="${CUSTOM_DOMAIN:-www.visa.com.sg}"
ENABLE_XRAY="${ENABLE_XRAY:-true}"
ENABLE_PQ="${ENABLE_PQ:-true}"

XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
INDEX_URL="https://gist.githubusercontent.com/good-xuan/c746ede2162561742591de5ef18ed280/raw/67d07ca6f813c8b616f71a68be491b561244d771/sjtp.html"

STATIC_PORT=$((PORT + 2))
FALLBACK_PORT=$((PORT + 1))

random_hex() {
    od -An -N4 -tx1 /dev/urandom | tr -d ' \n'
}

urlencode() {
    printf '%s' "$1" | jq -sRr @uri
}

log() {
    printf '%s\n' "$*"
}

cleanup() {
    if [ -n "${XRAY_PID:-}" ] && kill -0 "$XRAY_PID" 2>/dev/null; then
        kill "$XRAY_PID" 2>/dev/null || true
    fi

    if [ -n "${HTTP_PID:-}" ] && kill -0 "$HTTP_PID" 2>/dev/null; then
        kill "$HTTP_PID" 2>/dev/null || true
    fi
}

trap cleanup INT TERM EXIT

mkdir -p "$TMP" "$PUBLIC_DIR"

rm -f "$LINK_FILE"
rm -rf "$TMP"
mkdir -p "$TMP"

if [ -f "$STATE_FILE" ] && jq empty "$STATE_FILE" >/dev/null 2>&1; then
    STATE="$(cat "$STATE_FILE")"
else
    STATE='{}'
fi

if [ -z "$UUID" ]; then
    UUID="$(printf '%s' "$STATE" | jq -r '.uuid // empty')"
fi

if [ -z "$UUID" ]; then
    UUID="$(cat /proc/sys/kernel/random/uuid)"
fi

XHTTP_PATH="${XHTTP_PATH:-}"
if [ -z "$XHTTP_PATH" ]; then
    XHTTP_PATH="$(printf '%s' "$STATE" | jq -r '.xhttp // empty')"
fi

if [ -z "$XHTTP_PATH" ]; then
    XHTTP_PATH="/$(random_hex)"
fi

save_state() {
    jq \
        --arg uuid "$UUID" \
        --arg xhttp "$XHTTP_PATH" \
        '. + {uuid: $uuid, xhttp: $xhttp}' \
        "$STATE_FILE" 2>/dev/null > "$STATE_FILE.tmp" || \
        printf '{"uuid":"%s","xhttp":"%s"}\n' "$UUID" "$XHTTP_PATH" > "$STATE_FILE.tmp"

    mv "$STATE_FILE.tmp" "$STATE_FILE"
}

save_state

# 读取已保存的 ML-KEM 密钥
DECRYPTION=""
ENCRYPTION=""

if [ -f "$STATE_FILE" ]; then
    DECRYPTION="$(jq -r '.keys.decryption // empty' "$STATE_FILE" 2>/dev/null || true)"
    ENCRYPTION="$(jq -r '.keys.encryption // empty' "$STATE_FILE" 2>/dev/null || true)"
fi

if [ -n "${VLESS_DECRYPTION:-}" ]; then
    DECRYPTION="$VLESS_DECRYPTION"
fi

if [ -n "${VLESS_ENCRYPTION:-}" ]; then
    ENCRYPTION="$VLESS_ENCRYPTION"
fi

FLOW=""
if [ "$ENABLE_PQ" != "false" ]; then
    FLOW="xtls-rprx-vision"
fi

if [ "$ENABLE_XRAY" != "false" ]; then
    log "Downloading Xray..."

    wget -q --show-progress \
        -O "$ZIP_FILE" \
        "$XRAY_URL"

    unzip -oq "$ZIP_FILE" -d "$TMP"

    XRAY_SOURCE="$(find "$TMP" -type f -name xray | head -n 1)"

    if [ -z "$XRAY_SOURCE" ]; then
        echo "Xray binary not found" >&2
        exit 1
    fi

    mv "$XRAY_SOURCE" "$BIN_FILE"
    chmod 755 "$BIN_FILE"

    # 自动生成 ML-KEM 密钥
    if [ "$ENABLE_PQ" != "false" ] &&
        { [ -z "$DECRYPTION" ] || [ -z "$ENCRYPTION" ]; }; then

        VLESSENC_OUTPUT="$("$BIN_FILE" vlessenc 2>/dev/null || true)"

        NEW_DECRYPTION="$(printf '%s' "$VLESSENC_OUTPUT" |
            sed -n 's/.*"decryption"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
            head -n 1)"

        NEW_ENCRYPTION="$(printf '%s' "$VLESSENC_OUTPUT" |
            sed -n 's/.*"encryption"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
            head -n 1)"

        if [ -n "$NEW_DECRYPTION" ] && [ -n "$NEW_ENCRYPTION" ]; then
            DECRYPTION="$NEW_DECRYPTION"
            ENCRYPTION="$NEW_ENCRYPTION"

            jq \
                --arg decryption "$DECRYPTION" \
                --arg encryption "$ENCRYPTION" \
                '. + {keys: {decryption: $decryption, encryption: $encryption}}' \
                "$STATE_FILE" > "$STATE_FILE.tmp"

            mv "$STATE_FILE.tmp" "$STATE_FILE"
        fi
    fi

    if [ "$ENABLE_PQ" != "false" ] && [ -n "$DECRYPTION" ]; then
        INBOUND_DECRYPTION="$DECRYPTION"
    else
        INBOUND_DECRYPTION="none"
    fi

    if [ "$ENABLE_PQ" != "false" ] && [ -n "$ENCRYPTION" ]; then
        LINK_ENCRYPTION="$ENCRYPTION"
    else
        LINK_ENCRYPTION=""
    fi

    # 生成 Xray 配置
    jq -n \
        --argjson port "$PORT" \
        --argjson fallback_port "$FALLBACK_PORT" \
        --argjson static_port "$STATIC_PORT" \
        --arg uuid "$UUID" \
        --arg flow "$FLOW" \
        --arg xhttp_path "$XHTTP_PATH" \
        --arg decryption "$INBOUND_DECRYPTION" \
        '{
          log: {
            loglevel: "none"
          },
          inbounds: [
            {
              port: $port,
              protocol: "vless",
              settings: {
                fallbacks: [
                  {
                    dest: $fallback_port
                  },
                  {
                    path: "/",
                    dest: $static_port
                  }
                ],
                decryption: "none"
              }
            },
            {
              port: $fallback_port,
              protocol: "vless",
              settings: {
                clients: [
                  {
                    id: $uuid,
                    flow: $flow
                  }
                ],
                decryption: $decryption
              },
              streamSettings: {
                sockopt: {
                  trustedXForwardedFor: [
                    "CF-Connecting-IP",
                    "X-Real-IP"
                  ],
                  tcpcongestion: "bbr"
                },
                network: "xhttp",
                xhttpSettings: {
                  path: $xhttp_path
                }
              }
            }
          ],
          dns: {
            servers: [
              "https+local://1.1.1.1/dns-query",
              "localhost"
            ]
          },
          outbounds: [
            {
              protocol: "freedom",
              tag: "direct",
              streamSettings: {
                finalmask: {
                  tcp: [
                    {
                      type: "fragment",
                      settings: {
                        packets: "tlshello",
                        length: "100-200",
                        delay: "10-20",
                        maxSplit: "3-6"
                      }
                    }
                  ]
                },
                sockopt: {
                  tcpcongestion: "bbr",
                  domainStrategy: "UseIP",
                  happyEyeballs: {
                    tryDelayMs: 250
                  }
                }
              }
            },
            {
              protocol: "blackhole",
              tag: "block"
            }
          ]
        }' > "$CONFIG_FILE"

    wget -q -O "$PUBLIC_DIR/index.html" "$INDEX_URL"

    # Alpine 自带 BusyBox httpd
    busybox httpd \
        -f \
        -p "127.0.0.1:$STATIC_PORT" \
        -h "$PUBLIC_DIR" &
    HTTP_PID=$!

    "$BIN_FILE" -c "$CONFIG_FILE" >/dev/null 2>&1 &
    XRAY_PID=$!

    sleep 1

    if ! kill -0 "$XRAY_PID" 2>/dev/null; then
        echo "Xray failed to start" >&2
        exit 1
    fi

    gen_vless_link() {
        HOST="$1"
        LINK_PORT="$2"
        REMARK="$3"
        DOMAIN_LINK="$4"

        if [ "$DOMAIN_LINK" = "true" ]; then
            LINK_HOST="$CDN_HOST"
            LINK_PORT="443"
            SNI="$HOST"
        else
            LINK_HOST="$HOST"
            SNI="$CDN_HOST"
        fi

        ENCODED_PATH="$(urlencode "$XHTTP_PATH")"
        ENCODED_REMARK="$(urlencode "$REMARK")"

        LINK="vless://${UUID}@${LINK_HOST}:${LINK_PORT}"
        LINK="${LINK}?security=tls"

        if [ -n "$LINK_ENCRYPTION" ]; then
            LINK="${LINK}&encryption=$(urlencode "$LINK_ENCRYPTION")"
        fi

        if [ -n "$FLOW" ]; then
            LINK="${LINK}&flow=$(urlencode "$FLOW")"
        fi

        LINK="${LINK}&sni=$(urlencode "$SNI")"
        LINK="${LINK}&fp=random"
        LINK="${LINK}&alpn=h2"
        LINK="${LINK}&type=xhttp"
        LINK="${LINK}&path=${ENCODED_PATH}"
        LINK="${LINK}#${ENCODED_REMARK}"

        printf '%s\n' "$LINK"
    }

    save_link() {
        TITLE="$1"
        CONTENT="$2"

        {
            printf '\n%s\n%s\n' "$TITLE" "$CONTENT"
        } >> "$LINK_FILE"
    }

    if [ -n "$SERVER_IP" ]; then
        save_link \
            "Direct IP" \
            "$(gen_vless_link "$SERVER_IP" "$PORT" "${LINK_NAME}-Direct" false)"
    fi

    if [ -n "$CUSTOM_DOMAIN" ]; then
        save_link \
            "Custom Domain" \
            "$(gen_vless_link "$CUSTOM_DOMAIN" 443 "$LINK_NAME" true)"
    fi

    log "Initialized successfully."
    log "Links saved to: $LINK_FILE"
else
    log "ENABLE_XRAY=false, Xray was not started."
fi

# 保持主进程运行，并输出心跳
while :; do
    sleep 3600
    printf '💓 Heartbeat %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
done
