#!/bin/sh
set -e

BASE_DIR="$(pwd)"
TMP_DIR="${BASE_DIR}/tmp"
PUBLIC_DIR="${BASE_DIR}/public"
STATE_FILE="${BASE_DIR}/.sys_data"
CONFIG_FILE="${TMP_DIR}/config.json"

rm -rf "$TMP_DIR" && mkdir -p "$TMP_DIR" "$PUBLIC_DIR"
[ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"

# 退出时清理后台进程
trap 'kill 0 2>/dev/null || true' INT TERM EXIT

# 1. 基础参数与 UUID / Path 读取
PORT="${SERVER_PORT:-${PORT:-3000}}"
FALLBACK_PORT=$((PORT + 1))
STATIC_PORT=$((PORT + 2))
FLOW="xtls-rprx-vision"
CDN_HOST="${CDN_HOST:-www.visa.com.sg}"
CUSTOM_DOMAIN="${CUSTOM_DOMAIN:-www.visa.com.sg}"
LINK_NAME="${LINK_NAME:-Node}"
INDEX_URL="https://gist.githubusercontent.com/good-xuan/c746ede2162561742591de5ef18ed280/raw/67d07ca6f813c8b616f71a68be491b561244d771/sjtp.html"

UUID="${UUID:-$(jq -r '.uuid // empty' "$STATE_FILE")}"
[ -z "$UUID" ] && UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || od -x /dev/urandom | head -1 | awk '{OFS="-"; print $2$3,$4,$5,$6,$7$8$9}')"

XHTTP_PATH="${XHTTP_PATH:-$(jq -r '.xhttp // empty' "$STATE_FILE")}"
[ -z "$XHTTP_PATH" ] && XHTTP_PATH="/$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"

# 2. 下载 Xray
wget -qO "${TMP_DIR}/x.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
unzip -oq "${TMP_DIR}/x.zip" -d "$TMP_DIR"
chmod 755 "${TMP_DIR}/xray"

# 3. 读取或生成 ML-KEM-768 密钥并持久化到 .sys_data
DECRYPTION="${VLESS_DECRYPTION:-$(jq -r '.decryption // empty' "$STATE_FILE")}"
ENCRYPTION="${VLESS_ENCRYPTION:-$(jq -r '.encryption // empty' "$STATE_FILE")}"

if [ -z "$DECRYPTION" ] || [ -z "$ENCRYPTION" ]; then
    "${TMP_DIR}/xray" vlessenc > "${TMP_DIR}/enc.txt" 2>&1 || true
    DECRYPTION=$(awk '/Authentication:[[:space:]]*ML-KEM-768/{flag=1;next}/^Authentication:/{flag=0}flag && /"decryption"/{gsub(/.*:[[:space:]]*"|"[[:space:]]*,?/,"");print;exit}' "${TMP_DIR}/enc.txt")
    ENCRYPTION=$(awk '/Authentication:[[:space:]]*ML-KEM-768/{flag=1;next}/^Authentication:/{flag=0}flag && /"encryption"/{gsub(/.*:[[:space:]]*"|"[[:space:]]*,?/,"");print;exit}' "${TMP_DIR}/enc.txt")
fi

jq --arg u "$UUID" \
   --arg p "$XHTTP_PATH" \
   --arg dec "$DECRYPTION" \
   --arg enc "$ENCRYPTION" \
   '.uuid = $u | .xhttp = $p | .decryption = $dec | .encryption = $enc' \
   "$STATE_FILE" > "${STATE_FILE}.tmp"
mv -f "${STATE_FILE}.tmp" "$STATE_FILE"

# 4. 启动静态服务器 (lighttpd)
wget -qO "$PUBLIC_DIR/index.html" "$INDEX_URL" || echo "<h1>Welcome</h1>" > "$PUBLIC_DIR/index.html"
cat > "${TMP_DIR}/lighttpd.conf" <<EOF
server.document-root = "$PUBLIC_DIR"
server.bind = "127.0.0.1"
server.port = $STATIC_PORT
index-file.names = ( "index.html" )
mimetype.assign = ( ".html" => "text/html; charset=utf-8", ".css" => "text/css", ".js" => "application/javascript" )
EOF
lighttpd -D -f "${TMP_DIR}/lighttpd.conf" >/dev/null 2>&1 &

# 5. 原样生成 Xray 配置
jq -n \
    --argjson port "$PORT" \
    --argjson fallback_port "$FALLBACK_PORT" \
    --argjson static_port "$STATIC_PORT" \
    --arg uuid "$UUID" \
    --arg flow "$FLOW" \
    --arg xhttp_path "$XHTTP_PATH" \
    --arg decryption "$DECRYPTION" \
    '{
        log: { loglevel: "none" },
        inbounds: [
            {
                port: $port,
                protocol: "vless",
                settings: {
                    fallbacks: [
                        { dest: $fallback_port },
                        { path: "/", dest: $static_port }
                    ],
                    decryption: "none"
                }
            },
            {
                port: $fallback_port,
                protocol: "vless",
                settings: {
                    clients: [{ id: $uuid, flow: $flow }],
                    decryption: $decryption
                },
                streamSettings: {
                    sockopt: {
                        trustedXForwardedFor: ["CF-Connecting-IP", "X-Real-IP"],
                        tcpcongestion: "bbr"
                    },
                    network: "xhttp",
                    xhttpSettings: { path: $xhttp_path }
                }
            }
        ],
        dns: {
            servers: ["https+local://1.1.1.1/dns-query", "localhost"]
        },
        outbounds: [
            {
                protocol: "freedom",
                tag: "direct",
                streamSettings: {
                    finalmask: {
                        tcp: [{
                            type: "fragment",
                            settings: {
                                packets: "tlshello",
                                length: "100-200",
                                delay: "10-20",
                                maxSplit: "3-6"
                            }
                        }]
                    },
                    sockopt: {
                        tcpcongestion: "bbr",
                        domainStrategy: "UseIP",
                        happyEyeballs: { tryDelayMs: 250 }
                    }
                }
            },
            { protocol: "blackhole", tag: "block" }
        ]
    }' > "$CONFIG_FILE"

# 6. 输出链接并启动 Xray 前台挂起
ENCODED_DOMAIN=$(printf '%s' "$CUSTOM_DOMAIN" | jq -sRr @uri)
ENCODED_PATH=$(printf '%s' "$XHTTP_PATH" | jq -sRr @uri)
ENCODED_ENCRYPTION=$(printf '%s' "$ENCRYPTION" | jq -sRr @uri)
ENCODED_FLOW=$(printf '%s' "$FLOW" | jq -sRr @uri)
ENCODED_REMARK=$(printf '%s' "$LINK_NAME" | jq -sRr @uri)

echo ""
echo "============== Custom Domain =============="
echo "vless://${UUID}@${CDN_HOST}:443?security=tls&encryption=${ENCODED_ENCRYPTION}&flow=${ENCODED_FLOW}&sni=${ENCODED_DOMAIN}&fp=random&alpn=h2&type=xhttp&path=${ENCODED_PATH}#${ENCODED_REMARK}"
echo "============================================"
echo ""

exec "${TMP_DIR}/xray" run -c "$CONFIG_FILE"
