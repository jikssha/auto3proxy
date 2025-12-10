#!/bin/bash
# =========================================================
# 3Proxy Manager (Ultimate Fix)
# Author: Gemini for Crypto Trader
# =========================================================

# --- 核心配置 ---
REPO_URL="https://raw.githubusercontent.com/jikssha/auto3proxy/main/socks.sh"
SHORTCUT_PATH="/usr/bin/socks"
PATH_BIN="/usr/bin/3proxy"
PATH_CONF="/etc/3proxy"
CONF_FILE="/etc/3proxy/3proxy.cfg"
EXPORT_FILE="/root/socks5_export.txt"

# --- 1. 自我修复与快捷键安装 (核心修复逻辑) ---
install_self() {
    # 只有当脚本不是通过快捷指令运行时，才执行安装/更新
    if [ "$0" != "$SHORTCUT_PATH" ]; then
        echo ">>> 检测到首次运行，正在安装快捷指令 'socks'..."
        
        # 强制从 GitHub 下载最新版到 /usr/bin/socks
        # 使用 tr -d '\r' 确保下载下来的文件绝对没有 Windows 换行符
        if curl -fsSL "$REPO_URL" | tr -d '\r' > "$SHORTCUT_PATH"; then
            chmod +x "$SHORTCUT_PATH"
            echo ">>> 快捷指令安装成功！以后输入 'socks' 即可呼出菜单。"
        else
            echo "Warning: 快捷指令安装失败，请检查网络或 GitHub 仓库地址。"
        fi
    fi
}

# --- 2. 基础环境检查 ---
check_root() {
    [ $(id -u) != "0" ] && { echo "Error: 请使用 root 运行"; exit 1; }
}

get_public_ip() {
    PUB_IP=$(curl -s -4 ifconfig.me)
    [ -z "$PUB_IP" ] && PUB_IP=$(curl -s -4 icanhazip.com)
}

# --- 3. 3Proxy 安装逻辑 ---
install_dependencies() {
    # 检查网络工具 (netstat)
    if ! command -v netstat > /dev/null; then
        echo ">>> 安装系统工具..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq -y
        apt-get install -y net-tools >/dev/null 2>&1
    fi

    # 检查 3proxy
    if [ ! -f "$PATH_BIN" ]; then
        echo ">>> 开始部署 3Proxy 环境..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq -y
        apt-get install -y build-essential git tmux curl ufw net-tools >/dev/null 2>&1
        
        echo ">>> 编译安装 3Proxy..."
        rm -rf /tmp/3proxy
        git clone https://github.com/3proxy/3proxy.git /tmp/3proxy >/dev/null 2>&1
        cd /tmp/3proxy
        make -f Makefile.Linux >/dev/null 2>&1
        cp bin/3proxy /usr/bin/
        mkdir -p $PATH_CONF
        
        # 初始化无日志配置
        init_config_header
    fi
}

init_config_header() {
    cat > $CONF_FILE <<EOF
nserver 8.8.8.8
nserver 1.1.1.1
nscache 65536
timeouts 1 5 30 60 180 180 15 60
daemon
auth strong
log /dev/null
EOF
}

# --- 4. 进程守护 ---
reload_process() {
    echo ">>> 正在重载进程..."
    tmux kill-session -t socksproxyd 2>/dev/null
    pkill 3proxy
    # 死循环守护
    tmux new-session -d -s socksproxyd "while true; do $PATH_BIN $CONF_FILE; sleep 1; done"
    echo ">>> 服务已重启。"
}

# --- 5. 节点生成逻辑 ---
generate_nodes() {
    local count=$1
    local start_port=$2
    local mode=$3
    local append=$4
    
    get_public_ip
    
    if [ "$append" == "false" ]; then
        > $EXPORT_FILE
        echo "================ SOCKS5 list ================" >> $EXPORT_FILE
    fi

    echo ">>> 正在生成 $count 个节点 (起始端口 $start_port)..."

    for (( i=0; i<count; i++ )); do
        USER="u$(openssl rand -hex 2)"
        PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9')
        
        echo "users $USER:CL:$PASS" >> $CONF_FILE
        echo "allow $USER" >> $CONF_FILE

        if [ "$mode" == "1" ]; then
            REAL_PORT=$start_port
        else
            REAL_PORT=$(($start_port + $i))
            echo "socks -p$REAL_PORT" >> $CONF_FILE
            echo "flush" >> $CONF_FILE
            ufw allow $REAL_PORT/tcp >/dev/null 2>&1
            ufw allow $REAL_PORT/udp >/dev/null 2>&1
        fi
        
        echo "${PUB_IP}:${REAL_PORT}:${USER}:${PASS}" >> $EXPORT_FILE
    done

    if [ "$mode" == "1" ]; then
        if ! grep -q "socks -p$start_port" $CONF_FILE; then
            echo "socks -p$start_port" >> $CONF_FILE
            ufw allow $start_port/tcp >/dev/null 2>&1
            ufw allow $start_port/udp >/dev/null 2>&1
        fi
    fi

    reload_process
    
    echo "========================================================"
    echo "
