FROM debian:stable-slim

WORKDIR /app

# 安装必要的工具并清理 apt 缓存以减少体积
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    unzip \
    openssl \
    ca-certificates \
    netcat-traditional \
    && rm -rf /var/lib/apt/lists/*

# 拷贝启动脚本并赋予执行权限
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# 暴露端口
EXPOSE 3000

ENTRYPOINT ["/app/entrypoint.sh"]
