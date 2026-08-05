const fs = require('fs/promises');
const { createWriteStream } = require('fs');
const path = require('path');
const { spawn, exec } = require('child_process');
const crypto = require('crypto');
const util = require('util');
const { pipeline } = require('stream/promises');

const execAsync = util.promisify(exec);

// ==============================================================================
// 1. 配置与常量
// ==============================================================================
const CONFIG = {
    PORT: parseInt(process.env.SERVER_PORT || process.env.PORT || 3000),
    UUID: process.env.UUID || '',
    LINK_NAME: process.env.LINK_NAME || 'Node',
    CDN_HOST: process.env.CDN_HOST || 'www.visa.com.sg',
    SERVER_IP: process.env.SERVER_IP || '127.0.0.1',
    XRAY_URL: 'https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip',
    ENABLE_XRAY: process.env.ENABLE_XRAY !== 'false',
    CUSTOM_DOMAIN: process.env.CUSTOM_DOMAIN || 'www.visa.com.sg',
    PERSIST_FILE: path.join(__dirname, '.sys_data')
};

const randomStr = () => crypto.randomBytes(4).toString('hex');
const TMP = path.join(__dirname, 'tmp');
const FILES = {
    BIN: path.join(TMP, randomStr()),
    ZIP: path.join(TMP, `${randomStr()}.zip`),
    CFG: path.join(TMP, 'config.json'),
    LINKS: path.join(__dirname, 'LINK.txt')
};

// 工具函数
const exists = async (p) => fs.access(p).then(() => true).catch(() => false);

// 流式管道（Pipeline）写入文件
const download = async (url, dest) => {
    const res = await fetch(url);
    if (!res.ok || !res.body) throw new Error(`Download failed: ${res.statusText}`);
    await pipeline(res.body, createWriteStream(dest));
};

// 状态持久化管理
const State = {
    async load() {
        if (await exists(CONFIG.PERSIST_FILE)) {
            try { return JSON.parse(await fs.readFile(CONFIG.PERSIST_FILE, 'utf-8')); } catch {}
        }
        return {};
    },
    async save(data) {
        const current = await this.load();
        await fs.writeFile(CONFIG.PERSIST_FILE, JSON.stringify({ ...current, ...data }));
    }
};

// ==============================================================================
// 2. 主流程
// ==============================================================================
(async () => {
    // 清理旧链接与临时目录
    if (await exists(FILES.LINKS)) await fs.unlink(FILES.LINKS).catch(() => {});
    if (await exists(TMP)) await fs.rm(TMP, { recursive: true, force: true }).catch(() => {});
    await fs.mkdir(TMP, { recursive: true });

    try {
        const state = await State.load();
        
        // 1. 初始化 UUID 与路径
        const uuid = CONFIG.UUID || state.uuid || crypto.randomUUID();
        const xhttpPath = process.env.XHTTP_PATH || state.xhttp || '/' + randomStr();
        await State.save({ uuid, xhttp: xhttpPath });


        // 2. 节点链接生成函数 (已移除 TLS 与 PQ 参数)
        const genVlessLink = (host, port, remarks, isDomainLink) => {
            const link = new URL(`vless://${uuid}@${isDomainLink ? CONFIG.CDN_HOST : host}:${port}`);
            const params = link.searchParams;
            params.set('security', 'none');
            params.set('type', 'xhttp');
            params.set('path', xhttpPath);
            link.hash = remarks;
            return link.toString();
        };

        const saveLink = async (content, title = '') => {
            await fs.appendFile(FILES.LINKS, `\n${title}\n${content}\n`, 'utf-8').catch(() => {});
        };

        if (CONFIG.ENABLE_XRAY) {
            // 3. 流式下载并解压 Xray
            await download(CONFIG.XRAY_URL, FILES.ZIP);
            await execAsync(`unzip -o ${FILES.ZIP} -d ${TMP}`);
            
            const { stdout: findOut } = await execAsync(`find ${TMP} -type f -name "xray" | head -n 1`);
            await fs.rename(findOut.trim(), FILES.BIN);
            await fs.chmod(FILES.BIN, 0o755);

            // 4. 构建 Xray 配置
            const xrayConfig = {
                log: { loglevel: 'none' },
                inbounds: [{
                    port: CONFIG.PORT,
                    protocol: 'vless',
                    settings: {
                        clients: [{ id: uuid }],
                        decryption: "none"
                    },
                    streamSettings: {
                        sockopt: { trustedXForwardedFor: ["CF-Connecting-IP", "X-Real-IP"], tcpcongestion: "bbr" },
                        network: "xhttp",
                        security: "none",
                        xhttpSettings: { path: xhttpPath }
                    }
                }],
                dns: { servers: ["https+local://1.1.1.1/dns-query", "localhost"] },
                outbounds: [
                    {
                        protocol: 'freedom',
                        tag: 'direct',
                        streamSettings: {
                            sockopt: { tcpcongestion: 'bbr', domainStrategy: 'UseIP', happyEyeballs: { tryDelayMs: 250 } }
                        }
                    },
                    { protocol: 'blackhole', tag: 'block' }
                ]
            };

            await fs.writeFile(FILES.CFG, JSON.stringify(xrayConfig));

            // 5. 启动进程
            spawn(FILES.BIN, ['-c', FILES.CFG], { stdio: 'ignore', env: process.env })
                .on('exit', () => process.exit(1));

            // 6. 导出链接
            if (CONFIG.SERVER_IP) {
                await saveLink(genVlessLink(CONFIG.SERVER_IP, CONFIG.PORT, `${CONFIG.LINK_NAME}-Direct`, false), 'Direct IP');
            }
            if (CONFIG.CUSTOM_DOMAIN) {
                await saveLink(genVlessLink(CONFIG.CUSTOM_DOMAIN, CONFIG.PORT, CONFIG.LINK_NAME, true), 'Custom Domain');
            }
        }

        console.log('✅ Initialized successfully.');
        // 🌟 打印 UUID 和 xhttpPath 日志
        console.log(`🔑 UUID: ${uuid}`);
        console.log(`🛣️  Path: ${xhttpPath}`);
    } catch (e) {
        console.error(e);
        process.exit(1);
    }

    // 延迟清理临时文件
    setTimeout(async () => {
        if (await exists(TMP)) await fs.rm(TMP, { recursive: true, force: true }).catch(() => {});
    }, 20000);

    setInterval(() => console.log('💓 Heartbeat', new Date().toISOString()), 3600000);
})();
