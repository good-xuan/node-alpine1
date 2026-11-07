FROM node:alpine

RUN apk add --no-cache unzip ca-certificates curl

# 设置工作目录
WORKDIR /app

# 拷贝服务端脚本
COPY index.js ./

# 暴露服务端口
EXPOSE 3000

# 启动服务
CMD ["node", "index.js"]
