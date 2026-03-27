FROM alpine:3.23.3 AS builder

# 安装构建依赖
RUN apk add --no-cache \
    nodejs~24 \
    npm~11 \
    git \
    ca-certificates

WORKDIR /app

# 编译 WhatsApp bridge
COPY nanobot/bridge/ bridge/
WORKDIR /app/bridge
RUN npm install && npm run build

# ============================================
FROM alpine:3.23.3

# 安装运行时依赖
RUN apk add --no-cache \
    nodejs~24 \
    npm~11 \
    python3~3.12 \
    py3-pip \
    git \
    uv \
    curl \
    github-cli \
    tmux \
    jq \
    xsv \
    yq-go \
    ca-certificates && \
    npm install -g @steipete/summarize && \
    rm -f /usr/lib/python3.12/EXTERNALLY-MANAGED

WORKDIR /app

# 安装 Python 依赖
COPY nanobot/pyproject.toml nanobot/README.md nanobot/LICENSE ./
RUN mkdir -p nanobot bridge && touch nanobot/__init__.py && \
    uv pip install --system --no-cache . nanobot-ai[wecom] .[weixin] && \
    rm -rf nanobot bridge

# 复制源码
COPY nanobot/nanobot/ nanobot/
COPY nanobot/bridge/ bridge/
RUN uv pip install --system --no-cache . nanobot-ai[wecom] .[weixin]

# 创建 bridge 目录
RUN mkdir -p bridge

# 从构建阶段复制 bridge 编译产物（只保留 dist）
COPY --from=builder /app/bridge/dist ./bridge/dist

# 创建配置目录
RUN mkdir -p /root/.nanobot

# Gateway 默认端口
EXPOSE 18790

ENTRYPOINT ["nanobot"]
CMD ["status"]
