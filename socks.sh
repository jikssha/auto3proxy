#!/bin/bash
# =========================================================
# 3Proxy 指纹浏览器专用一键脚本 (Tmux版)
# Author: Gemini for Crypto Trader
# Output Format: IP:PORT:USER:PASS
# =========================================================

# 1. 检查 Root 权限
[ $(id -u) != "0" ] && { echo "Error: 必须使用 root 运行"; exit 1; }

# 2. 自动获取公网 IP
echo ">>> 正在探测公网 IP..."
PUB_IP=$(curl -s -4 ifconfig.me)
[ -z "$PUB_IP" ] && PUB_IP=$(curl -s -4 icanhazip.com)
echo "当前公网 IP: $PUB_IP"

# 3. 安装依赖 (静默模式)
echo ">>> 安装系统依赖..."
if [ -f /etc/debian_version ]; then
    apt-get update -qq -y
    apt-get install -y build-essential git tmux curl ufw >/dev/null 2>&1
else
    echo "不支持的系统，仅支持 Debian/Ubuntu"
    exit 1
fi

# 4. 编译 3Proxy
echo ">>> 编译 3Proxy (这可能需要 1-2 分钟)..."
rm -rf /tmp/3proxy
git clone https://github.com/3proxy/3proxy.git /tmp/3proxy >/dev/null 2>&1
cd /tmp/3proxy
make -f Makefile.Linux >/dev/null 2>&1
cp bin/3proxy /usr/bin/
mkdir -p /etc/3proxy

# 5. 交互式配置
echo "------------------------------------------------"
read -p "请输入节点数量 (例如 5): " COUNT
read -p "请输入起始端口 (例如 20000): " START_PORT
echo "模式选择:"
echo " [1] 单端口多用户 (所有窗口共用 $START_PORT，推荐，防火墙配置简单)"
echo " [2] 多端口多用户 (窗口1用 $START_PORT, 窗口2用 $(($START_PORT+1))...)"
read -p "请选择 [1/2]: " MODE
echo "------------------------------------------------"

# 6. 生成配置
CONF="/etc/3proxy/3proxy.cfg"
RESULT="/root/socks5_export.txt"

# 写入配置头
cat > $CONF <<EOF
nserver 8.8.8.8
nserver 1.1.1.1
nscache 65536
timeouts 1 5 30 60 180 180 15 60
daemon
auth strong
EOF

# 清空结果文件
> $RESULT

echo ">>> 正在生成 $COUNT 个 SOCKS5 节点..."

for (( i=0; i<COUNT; i++ )); do
    # 生成随机用户名 (u + 4位随机) 和 16位随机密码
    USER="u$(openssl rand -hex 2)"
    PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9')
    
    echo "users $USER:CL:$PASS" >> $CONF
    echo "allow $USER" >> $CONF

    if [ "$MODE" == "1" ]; then
        # 模式1: 记录数据，端口稍后统一开
        REAL_PORT=$START_PORT
    else
        # 模式2: 每个用户独立端口
        REAL_PORT=$(($START_PORT + $i))
        echo "socks -p$REAL_PORT" >> $CONF
        echo "flush" >> $CONF
        # 放行防火墙
        ufw allow $REAL_PORT/tcp >/dev/null 2>&1
        ufw allow $REAL_PORT/udp >/dev/null 2>&1
    fi
    
    # 输出格式: IP:PORT:USER:PASS
    echo "${PUB_IP}:${REAL_PORT}:${USER}:${PASS}" >> $RESULT
done

# 如果是单端口模式，最后开启端口并放行
if [ "$MODE" == "1" ]; then
    echo "socks -p$START_PORT" >> $CONF
    ufw allow $START_PORT/tcp >/dev/null 2>&1
    ufw allow $START_PORT/udp >/dev/null 2>&1
fi

# 7. 启动 Tmux 守护进程
# 杀死旧进程
tmux kill-session -t socksproxyd 2>/dev/null
pkill 3proxy
# 启动新会话，死循环守护
tmux new-session -d -s socksproxyd "while true; do /usr/bin/3proxy /etc/3proxy/3proxy.cfg; sleep 1; done"

echo "========================================================"
echo "安装完成！请复制下方内容导入指纹浏览器："
echo "========================================================"
cat $RESULT
echo "========================================================"
echo "数据已备份至: $RESULT"
echo "Tmux 守护运行中: tmux attach -t socksproxyd"
