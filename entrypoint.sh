#!/bin/bash

set -e

#============================================================
# 3proxy 智能启动脚本
# 功能：智能端口选择、自动多用户生成、零配置启动
#============================================================

CONFIG_FILE="/app/config/3proxy.cfg"
USER_COUNT=5

echo "========================================"
echo "  🚀 3proxy SOCKS5 代理服务启动中..."
echo "========================================"

#------------------------------------------------------------
# 1. 智能端口选择逻辑
#------------------------------------------------------------
if [ -n "$PORT" ]; then
    # Railway/ClawCloud 等平台会设置 PORT 环境变量
    PROXY_PORT=$PORT
    echo "✅ 检测到平台端口变量: $PROXY_PORT"
else
    # 自动生成随机端口 (30000-50000)
    PROXY_PORT=$((30000 + RANDOM % 20001))
    echo "🎲 自动生成随机端口: $PROXY_PORT"
fi

#------------------------------------------------------------
# 2. 自动生成多用户凭证
#------------------------------------------------------------
echo ""
echo "🔐 正在生成 $USER_COUNT 组随机用户凭证..."
USERS=()

for i in $(seq 1 $USER_COUNT); do
    # 生成随机用户名（8字符）和密码（16字符）
    USERNAME=$(openssl rand -hex 4)
    PASSWORD=$(openssl rand -base64 12 | tr -d '/+=' | head -c 16)
    USERS+=("$USERNAME:$PASSWORD")
done

#------------------------------------------------------------
# 3. 动态生成 3proxy 配置文件
#------------------------------------------------------------
echo ""
echo "📝 生成配置文件: $CONFIG_FILE"

cat > "$CONFIG_FILE" <<EOF
# 3proxy 配置文件 - 自动生成
# 禁用 daemon 模式（前台运行）
daemon

# 日志输出到 stdout（利用 Docker logs）
log /dev/stdout D
logformat "- +_L%t.%.  %N.%p %E %U %C:%c %R:%r %O %I %h %T"

# DNS 服务器
nserver 1.1.1.1
nserver 8.8.8.8
nscache 65536

# 设置超时时间
timeouts 1 5 30 60 180 1800 15 60

# 多用户认证
EOF

# 添加所有用户
for user in "${USERS[@]}"; do
    echo "users $user" >> "$CONFIG_FILE"
done

cat >> "$CONFIG_FILE" <<EOF

# 访问控制
auth strong

# 允许所有源 IP
allow *

# SOCKS5 代理监听
socks -p$PROXY_PORT
EOF

#------------------------------------------------------------
# 4. 打印关键信息 Banner
#------------------------------------------------------------
echo ""
echo "========================================"
echo "  ✨ 3proxy 服务配置完成"
echo "========================================"
echo ""
echo "📌 监听端口: $PROXY_PORT"
echo ""
echo "👥 用户列表:"
for i in "${!USERS[@]}"; do
    USER_INFO="${USERS[$i]}"
    USERNAME="${USER_INFO%%:*}"
    PASSWORD="${USER_INFO##*:}"
    echo "   [$((i+1))] 用户名: $USERNAME | 密码: $PASSWORD"
done

echo ""
echo "🔗 连接串示例 (请替换 <服务器IP>):"
FIRST_USER="${USERS[0]}"
FIRST_USERNAME="${FIRST_USER%%:*}"
FIRST_PASSWORD="${FIRST_USER##*:}"
echo "   socks5://${FIRST_USERNAME}:${FIRST_PASSWORD}@<服务器IP>:${PROXY_PORT}"
echo ""
echo "========================================"
echo "  🎯 服务正在启动..."
echo "========================================"
echo ""

#------------------------------------------------------------
# 5. 启动 3proxy（前台运行）
#------------------------------------------------------------
exec /app/bin/3proxy "$CONFIG_FILE"
