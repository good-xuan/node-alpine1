const fs = require("fs/promises");
const { createWriteStream } = require("fs");
const { createServer } = require("http");
const path = require("path");
const { spawn, exec } = require("child_process");
const crypto = require("crypto");
const util = require("util");
const { pipeline } = require("stream/promises");

const execAsync = util.promisify(exec);

const PORT = parseInt(process.env.SERVER_PORT || process.env.PORT || 3000, 10);
const LINK_NAME = process.env.LINK_NAME || "Node";
const CDN_HOST = process.env.CDN_HOST || "www.visa.com.sg";
const CUSTOM_DOMAIN = process.env.CUSTOM_DOMAIN || "www.visa.com.sg";
const ENABLE_PQ = process.env.ENABLE_PQ !== "false";
const FLOW = ENABLE_PQ ? "xtls-rprx-vision" : "";
const PERSIST_FILE = path.join(__dirname, ".sys_data");

const TMP = path.join(__dirname, "tmp");
const BIN = path.join(TMP, "xray");
const CFG = path.join(TMP, "config.json");

const download = async (url, dest) => {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Fetch failed: ${res.statusText}`);
  await pipeline(res.body, createWriteStream(dest));
};

const State = {
  async load() {
    try {
      return JSON.parse(await fs.readFile(PERSIST_FILE, "utf-8"));
    } catch {
      return {};
    }
  },
  async save(data) {
    const current = await this.load();
    await fs.writeFile(PERSIST_FILE, JSON.stringify({ ...current, ...data }, null, 2), "utf8");
  },
};

// 伪装服务：匹配 UUID 后12位的路径提供订阅输出，其余路径返回 401
const startStaticServer = (subPath, getNodeLink) => {
  createServer((req, res) => {
    const reqUrl = (req.url || "").split("?")[0];

    // 如果匹配订阅路径 (如 /xxxx-xxxx-xxxx 或纯12位字符)
    if (reqUrl === `/${subPath}`) {
      const link = typeof getNodeLink === "function" ? getNodeLink() : getNodeLink;
      const base64Content = Buffer.from(link + "\n").toString("base64");
      
      res.writeHead(200, {
        "Content-Type": "text/plain; charset=utf-8",
        "Cache-Control": "no-store, no-cache, must-revalidate",
        "Profile-Update-Interval": "24",
      });
      return res.end(base64Content);
    }

    // 默认回落伪装：永久 401 强制浏览器弹出认证窗口
    res.writeHead(401, {
      "WWW-Authenticate": 'Basic realm="Restricted Access"',
      "Content-Type": "text/plain; charset=utf-8",
    });
    res.end("Access Denied");
  }).listen(PORT + 2, "127.0.0.1");
};

const genLink = (uuid, xhttpPath, host, port, remarks, keys) => {
  const url = new URL(`vless://${uuid}@${CDN_HOST}:${port}`);
  const p = url.searchParams;
  p.set("security", "tls");
  if (ENABLE_PQ && keys?.encryption) {
    p.set("encryption", keys.encryption);
  }
  if (FLOW) p.set("flow", FLOW);
  p.set("sni", host);
  p.set("fp", "random");
  p.set("alpn", "h2");
  p.set("type", "xhttp");
  p.set("path", xhttpPath);
  url.hash = remarks;
  return url.toString();
};

(async () => {
  try {
    await fs.mkdir(TMP, { recursive: true });

    // 1. 下载并解压 Xray
    const zipPath = path.join(TMP, "x.zip");
    await download(
      "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip",
      zipPath
    );
    await execAsync(`unzip -o "${zipPath}" xray -d "${TMP}" && chmod +x "${BIN}"`);
    await fs.unlink(zipPath).catch(() => {});

    // 2. 状态读取与 UUID/Path/PQ 密钥持久化保存
    const state = await State.load();
    const uuid = process.env.UUID || state.uuid || crypto.randomUUID();
    const xhttpPath = process.env.XHTTP_PATH || state.xhttp || `/${crypto.randomBytes(4).toString("hex")}`;

    // 获取 UUID 后 12 位作为 sub 路径 (标准 UUID 类似 xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx，后12位正好是最后一段 Hex)
    const subPath = uuid.slice(-12);

    let keys = state.keys || {
      decryption: process.env.VLESS_DECRYPTION || "",
      encryption: process.env.VLESS_ENCRYPTION || "",
    };

    if (ENABLE_PQ && (!keys.decryption || !keys.encryption)) {
      try {
        const { stdout } = await execAsync(`"${BIN}" vlessenc`, { encoding: "utf8" });
        const match = stdout.match(
          /ML-KEM-768[\s\S]+?"decryption":\s*"([^"]+)"[\s\S]+?"encryption":\s*"([^"]+)"/
        );
        if (match) {
          keys = { decryption: match[1], encryption: match[2] };
        }
      } catch {}
    }

    // 保存 uuid, xhttp, keys 到 .sys_data
    await State.save({ uuid, xhttp: xhttpPath, keys });

    // 3. 原版 Xray 配置
    const xrayConfig = {
      log: { loglevel: "none" },
      inbounds: [
        {
          port: PORT,
          protocol: "vless",
          settings: {
            fallbacks: [
              { dest: PORT + 1 },
              { path: "/", dest: PORT + 2 }, // 回落至 127.0.0.1:PORT+2（包含伪装和Sub服务）
            ],
            decryption: "none",
          },
        },
        {
          port: PORT + 1,
          protocol: "vless",
          settings: {
            clients: [{ id: uuid, flow: FLOW }],
            decryption: ENABLE_PQ && keys.decryption ? keys.decryption : "none",
          },
          streamSettings: {
            sockopt: {
              trustedXForwardedFor: ["CF-Connecting-IP", "X-Real-IP"],
              tcpcongestion: "bbr",
            },
            network: "xhttp",
            xhttpSettings: { path: xhttpPath },
          },
        },
      ],
      dns: { servers: ["https+local://1.1.1.1/dns-query"] },
      outbounds: [
        {
          protocol: "freedom",
          tag: "direct",
          streamSettings: {
            sockopt: {
              tcpcongestion: "bbr",
              domainStrategy: "UseIPv4v6",
            },
          },
        },
        { protocol: "blackhole", tag: "block" },
      ],
    };

    await fs.writeFile(CFG, JSON.stringify(xrayConfig));

    // 4. 生成节点链接与订阅链接
    const link = genLink(uuid, xhttpPath, CUSTOM_DOMAIN, 443, LINK_NAME, keys);
    const subUrl = `https://${CUSTOM_DOMAIN}/${subPath}`;

    // 5. 启动伪装与订阅服务 & Xray 核心
    startStaticServer(subPath, link);
    const child = spawn(BIN, ["-c", CFG], { stdio: "ignore" });
    child.on("exit", () => process.exit(1));

    // 6. 保存链接至本地文件
    const outputContent = `Node Link:\n${link}\n\nSubscription URL:\n${subUrl}\n`;
    await fs.writeFile(path.join(__dirname, "LINK.txt"), outputContent, "utf8");

    console.log("✅ Running...");
    //console.log(`📡 Subscription URL: ${subUrl}`);
  } catch (err) {
    console.error("❌ Failed:", err.message);
    process.exit(1);
  }
})();
