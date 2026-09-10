#!/bin/sh

set -eu

BASE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

TMP="$BASE_DIR/tmp"
PUBLIC_DIR="$BASE_DIR/public"

STATE_FILE="$BASE_DIR/.sys_data"
LINK_FILE="$BASE_DIR/LINK.txt"

DECRYPTION_FILE="$BASE_DIR/.vless_decryption"
ENCRYPTION_FILE="$BASE_DIR/.vless_encryption"

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

# true 时强制重新生成一对 ML-KEM-768 密钥
ROTATE_PQ_KEYS="${ROTATE_PQ_KEYS:-false}"

XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"

INDEX_URL="https://gist.githubusercontent.com/good-xuan/c746ede2162561742591de5ef18ed280/raw/67d07ca6f813c8b616f71a68be491b561244d771/sjtp.html"

STATIC_PORT=$((PORT + 2))
FALLBACK_PORT=$((PORT + 1))

XRAY_PID=""
HTTP_PID=""

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
    if [ -n "${XRAY_PID:-}" ] &&
        kill -0 "$XRAY_PID" 2>/dev/null; then
        kill "$XRAY_PID" 2>/dev/null || true
    fi

    if [ -n "${HTTP_PID:-}" ] &&
        kill -0 "$HTTP_PID" 2>/dev/null; then
        kill "$HTTP_PID" 2>/dev/null || true
    fi
}

trap cleanup INT TERM EXIT

# 清理临时目录
rm -rf "$TMP"

mkdir -p "$TMP"
mkdir -p "$PUBLIC_DIR"

# 每次启动重新生成链接文件
rm -f "$LINK_FILE"

# 读取状态文件
if [ -f "$STATE_FILE" ] &&
    jq empty "$STATE_FILE" >/dev/null 2>&1; then
    STATE="$(cat "$STATE_FILE")"
else
    STATE='{}'
fi

# 读取或生成 UUID
if [ -z "$UUID" ]; then
    UUID="$(printf '%s' "$STATE" | jq -r '.uuid // empty')"
fi

if [ -z "$UUID" ]; then
    UUID="$(cat /proc/sys/kernel/random/uuid)"
fi

# 读取或生成 XHTTP 路径
XHTTP_PATH="${XHTTP_PATH:-}"

if [ -z "$XHTTP_PATH" ]; then
    XHTTP_PATH="$(
        printf '%s' "$STATE" |
            jq -r '.xhttp // empty'
    )"
fi

if [ -z "$XHTTP_PATH" ]; then
    XHTTP_PATH="/$(random_hex)"
fi

save_state() {
    jq \
        --arg uuid "$UUID" \
        --arg xhttp "$XHTTP_PATH" \
        '. + {
            uuid: $uuid,
            xhttp: $xhttp
        }' \
        "$STATE_FILE" \
        > "$STATE_FILE.tmp" 2>/dev/null || \
    printf '%s\n' \
        "{\"uuid\":\"$UUID\",\"xhttp\":\"$XHTTP_PATH\"}" \
        > "$STATE_FILE.tmp"

    mv "$STATE_FILE.tmp" "$STATE_FILE"
}

save_state

# ------------------------------
# 下载 Xray
# ------------------------------

if [ "$ENABLE_XRAY" = "false" ]; then
    log "ENABLE_XRAY=false, Xray was not started."

    while :; do
        sleep 3600

        printf 'Heartbeat %s\n' \
            "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    done
fi

log "Downloading Xray..."

wget \
    -q \
    -O "$ZIP_FILE" \
    "$XRAY_URL"

unzip -oq "$ZIP_FILE" -d "$TMP"

XRAY_SOURCE="$(
    find "$TMP" \
        -type f \
        -name xray |
        head -n 1
)"

if [ -z "$XRAY_SOURCE" ]; then
    echo "Xray binary not found" >&2
    exit 1
fi


if [ "$XRAY_SOURCE" != "$BIN_FILE" ]; then
    mv "$XRAY_SOURCE" "$BIN_FILE"
fi
chmod 755 "$BIN_FILE"

# ------------------------------
# 读取和生成 ML-KEM-768 密钥
# ------------------------------

read_key_file() {
    FILE="$1"

    if [ -f "$FILE" ]; then
        tr -d '\r' < "$FILE" |
            sed 's/[[:space:]]*$//'
    fi
}

DECRYPTION=""
ENCRYPTION=""

if [ -f "$DECRYPTION_FILE" ]; then
    DECRYPTION="$(read_key_file "$DECRYPTION_FILE")"
fi

if [ -f "$ENCRYPTION_FILE" ]; then
    ENCRYPTION="$(read_key_file "$ENCRYPTION_FILE")"
fi

# 环境变量优先级更高
if [ -n "${VLESS_DECRYPTION:-}" ]; then
    DECRYPTION="$VLESS_DECRYPTION"
fi

if [ -n "${VLESS_ENCRYPTION:-}" ]; then
    ENCRYPTION="$VLESS_ENCRYPTION"
fi

# 只接受 ML-KEM-768 格式，防止误用 X25519
case "$DECRYPTION" in
    mlkem768x25519plus.native.*)
        ;;
    *)
        DECRYPTION=""
        ;;
esac

case "$ENCRYPTION" in
    mlkem768x25519plus.native.*)
        ;;
    *)
        ENCRYPTION=""
        ;;
esac

# 从 Xray 输出中的 ML-KEM-768 区块提取字段
extract_mlkem_key() {
    KEY_NAME="$1"

    awk -v key="$KEY_NAME" '
        /Authentication:[[:space:]]*ML-KEM-768,[[:space:]]*Post-Quantum/ {
            in_mlkem=1
            next
        }

        in_mlkem && /^Authentication:/ {
            exit
        }

        in_mlkem && index($0, "\"" key "\"") {
            line=$0

            sub(".*\"" key "\"[[:space:]]*:[[:space:]]*\"", "", line)
            sub("\".*", "", line)

            if (line != "") {
                print line
                exit
            }
        }
    ' "$VLESSENC_FILE"
}

# 强制轮换密钥
if [ "$ROTATE_PQ_KEYS" = "true" ]; then
    log "ROTATE_PQ_KEYS=true, existing ML-KEM keys will be replaced."

    DECRYPTION=""
    ENCRYPTION=""
fi

# 如果缺少任意一把密钥，则重新生成一整对
if [ "$ENABLE_PQ" != "false" ] &&
    { [ -z "$DECRYPTION" ] || [ -z "$ENCRYPTION" ]; }; then

    log "Generating VLESS ML-KEM-768 keys..."

    VLESSENC_FILE="$TMP/vlessenc.txt"

    # 某些版本的 Xray 输出到 stderr，因此同时捕获 stdout 和 stderr
    "$BIN_FILE" vlessenc > "$VLESSENC_FILE" 2>&1 || true

    NEW_DECRYPTION="$(extract_mlkem_key decryption)"
    NEW_ENCRYPTION="$(extract_mlkem_key encryption)"

    # 再次检查提取出的确实是 ML-KEM-768 密钥
    case "$NEW_DECRYPTION" in
        mlkem768x25519plus.native.*)
            ;;
        *)
            NEW_DECRYPTION=""
            ;;
    esac

    case "$NEW_ENCRYPTION" in
        mlkem768x25519plus.native.*)
            ;;
        *)
            NEW_ENCRYPTION=""
            ;;
    esac

    if [ -z "$NEW_DECRYPTION" ] ||
        [ -z "$NEW_ENCRYPTION" ]; then

        log "Error: failed to generate ML-KEM-768 keys." >&2
        cat "$VLESSENC_FILE" >&2
        exit 1
    fi

    DECRYPTION="$NEW_DECRYPTION"
    ENCRYPTION="$NEW_ENCRYPTION"

    printf '%s\n' "$DECRYPTION" > "$DECRYPTION_FILE"
    printf '%s\n' "$ENCRYPTION" > "$ENCRYPTION_FILE"

    chmod 600 \
        "$DECRYPTION_FILE" \
        "$ENCRYPTION_FILE"

    log "ML-KEM-768 keys saved."
fi

# PQ 开启时，必须同时存在两把密钥
if [ "$ENABLE_PQ" != "false" ]; then
    if [ -z "$DECRYPTION" ] || [ -z "$ENCRYPTION" ]; then
        log "Error: ML-KEM-768 keys are unavailable." >&2
        exit 1
    fi

    INBOUND_DECRYPTION="$DECRYPTION"
    LINK_ENCRYPTION="$ENCRYPTION"
else
    INBOUND_DECRYPTION="none"
    LINK_ENCRYPTION=""
fi

# ------------------------------
# 生成 Xray 配置
# ------------------------------

FLOW=""

if [ "$ENABLE_PQ" != "false" ]; then
    FLOW="xtls-rprx-vision"
fi

log "Generating Xray configuration..."

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

# ------------------------------
# 下载静态页面
# ------------------------------

log "Downloading static page..."

wget \
    -q \
    -O "$PUBLIC_DIR/index.html" \
    "$INDEX_URL"

# ------------------------------
# 生成 lighttpd 配置
# ------------------------------

LIGHTTPD_CONF="$TMP/lighttpd.conf"

cat > "$LIGHTTPD_CONF" <<EOF
server.document-root = "$PUBLIC_DIR"
server.bind = "127.0.0.1"
server.port = $STATIC_PORT
server.pid-file = "$TMP/lighttpd.pid"
server.errorlog = "$TMP/lighttpd.error.log"

index-file.names = ( "index.html" )

mimetype.assign = (
    ".html"  => "text/html; charset=utf-8",
    ".css"   => "text/css; charset=utf-8",
    ".js"    => "application/javascript; charset=utf-8",
    ".json"  => "application/json; charset=utf-8",
    ".txt"   => "text/plain; charset=utf-8",
    ".xml"   => "application/xml; charset=utf-8",
    ".png"   => "image/png",
    ".jpg"   => "image/jpeg",
    ".jpeg"  => "image/jpeg",
    ".gif"   => "image/gif",
    ".svg"   => "image/svg+xml",
    ".ico"   => "image/x-icon",
    ".webp"  => "image/webp",
    ".woff"  => "font/woff",
    ".woff2" => "font/woff2"
)
EOF

# ------------------------------
# 启动 lighttpd
# ------------------------------

log "Starting lighttpd on 127.0.0.1:$STATIC_PORT..."

lighttpd \
    -D \
    -f "$LIGHTTPD_CONF" \
    >/dev/null 2>&1 &

HTTP_PID=$!

sleep 1

if ! kill -0 "$HTTP_PID" 2>/dev/null; then
    echo "lighttpd failed to start" >&2

    if [ -f "$TMP/lighttpd.error.log" ]; then
        cat "$TMP/lighttpd.error.log" >&2
    fi

    exit 1
fi

# ------------------------------
# 启动 Xray
# ------------------------------

log "Starting Xray on port $PORT..."

"$BIN_FILE" \
    -c "$CONFIG_FILE" \
    >/dev/null 2>&1 &

XRAY_PID=$!

sleep 1

if ! kill -0 "$XRAY_PID" 2>/dev/null; then
    echo "Xray failed to start" >&2
    exit 1
fi

# ------------------------------
# 生成 VLESS 链接
# ------------------------------

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
    ENCODED_SNI="$(urlencode "$SNI")"
    ENCODED_REMARK="$(urlencode "$REMARK")"

    LINK="vless://${UUID}@${LINK_HOST}:${LINK_PORT}"
    LINK="${LINK}?security=tls"

    if [ -n "$LINK_ENCRYPTION" ]; then
        LINK="${LINK}&encryption=$(urlencode "$LINK_ENCRYPTION")"
    fi

    if [ -n "$FLOW" ]; then
        LINK="${LINK}&flow=$(urlencode "$FLOW")"
    fi

    LINK="${LINK}&sni=${ENCODED_SNI}"
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
        "$(gen_vless_link \
            "$SERVER_IP" \
            "$PORT" \
            "${LINK_NAME}-Direct" \
            false)"
fi

if [ -n "$CUSTOM_DOMAIN" ]; then
    save_link \
        "Custom Domain" \
        "$(gen_vless_link \
            "$CUSTOM_DOMAIN" \
            443 \
            "$LINK_NAME" \
            true)"
fi

# 链接文件包含 encryption 参数，限制为当前用户可读
chmod 600 "$LINK_FILE"

# 限制状态文件和配置文件权限
chmod 600 "$STATE_FILE" "$CONFIG_FILE" 2>/dev/null || true

log "Initialized successfully."
log "Links saved to: $LINK_FILE"
log "Xray PID: $XRAY_PID"
log "lighttpd PID: $HTTP_PID"

# ------------------------------
# 保持容器运行
# ------------------------------

while :; do
    sleep 3600

    printf 'Heartbeat %s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    if ! kill -0 "$XRAY_PID" 2>/dev/null; then
        echo "Xray process exited" >&2
        exit 1
    fi

    if ! kill -0 "$HTTP_PID" 2>/dev/null; then
        echo "lighttpd process exited" >&2
        exit 1
    fi
done
