# 使用 Alpine 版 Node.js 镜像（体积小，性能高）
FROM node:26-alpine

# 安装执行 index.js 所需的系统依赖 (unzip 和 findutils/find)
RUN apk add --no-cache unzip findutils ca-certificates

# 设置工作目录
WORKDIR /app

# 复制 package.json
COPY package*.json ./

# 复制脚本源码
COPY index.js ./
COPY public/ ./public/

# 暴露端口（默认 3000）
EXPOSE 3000

# 启动 Node.js 应用
CMD ["node", "index.js"]
