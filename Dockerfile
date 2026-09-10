FROM debian:13-slim

ENV DEBIAN_FRONTEND=noninteractive

# 安装脚本运行所需的全部依赖
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        jq \
        wget \
        unzip \
        lighttpd \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

# 暴露节点端口（默认 3000）
EXPOSE 3000

ENTRYPOINT ["/app/start.sh"]
