FROM alpine:3.24

RUN apk add --no-cache \
        ca-certificates \
        wget \
        unzip \
        jq \
        gcompat \
        libstdc++ \
    && update-ca-certificates

WORKDIR /app

COPY start.sh /app/start.sh

RUN chmod +x /app/start.sh

EXPOSE 3000

STOPSIGNAL SIGTERM

ENTRYPOINT ["/app/start.sh"]
