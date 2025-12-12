FROM alpine:latest

# 设置工作目录
WORKDIR /app

# 安装编译依赖和运行时工具
RUN apk add --no-cache \
    git \
    gcc \
    g++ \
    make \
    linux-headers \
    bash \
    openssl \
    && git clone https://github.com/z3APA3A/3proxy.git /tmp/3proxy \
    && cd /tmp/3proxy \
    && make -f Makefile.Linux \
    && mkdir -p /app/bin \
    && cp /tmp/3proxy/bin/3proxy /app/bin/ \
    && chmod +x /app/bin/3proxy \
    && cd / \
    && rm -rf /tmp/3proxy \
    && apk del git gcc g++ make linux-headers \
    && apk add --no-cache bash openssl

# 复制启动脚本
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# 创建配置文件目录
RUN mkdir -p /app/config

# 暴露端口范围（仅作文档说明，实际端口动态决定）
EXPOSE 30000-50000

# 使用启动脚本作为入口点
ENTRYPOINT ["/app/entrypoint.sh"]
