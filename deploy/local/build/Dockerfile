# 本地 fastclaw 镜像, 镜像上游 Dockerfile runtime stage
# 构建上下文应为 fastclaw 源码根 (含 bin/fastclaw)
FROM alpine:3.21
RUN apk add --no-cache ca-certificates tzdata
COPY bin/fastclaw /usr/local/bin/fastclaw

ENV FASTCLAW_HOME=/data/.fastclaw \
    HOME=/data
RUN mkdir -p /data/.fastclaw /data/.fastclaw/skills

EXPOSE 18953
ENTRYPOINT ["/usr/local/bin/fastclaw"]
