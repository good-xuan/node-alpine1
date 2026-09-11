FROM alpine:latest

WORKDIR /app

# 安装必要的轻量级网络与加解密工具
RUN apk add --no-cache \
    curl \
    unzip \
    openssl \
    ca-certificates


COPY start.sh /app/start.sh

RUN chmod +x /app/start.sh

EXPOSE 3000

ENTRYPOINT ["/app/start.sh"]
