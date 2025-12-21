#!/bin/bash
# =========================================================
# 3Proxy Manager Pro (v2.1 Final)
# 支持 SOCKS5 / HTTP 协议，修复 GCP/Oracle 环境下的认证与启动问题
# =========================================================

# --- 核心配置 ---
REPO_URL="https://raw.githubusercontent.com/jikssha/auto3proxy/main/socks.sh"
SHORTCUT_PATH="/usr/bin/socks"
PATH_BIN="/usr/bin/3proxy"
PATH_CONF="/etc/3proxy"
CONF_FILE="/etc/3proxy/3proxy.cfg"
EXPORT_FILE="/root/proxies_export.txt"

# --- 1. 自我修复与安装 ---
install_self() {
    if [ "$0" != "$SHORTCUT_PATH" ]; then
        echo ">>> 检测到安装环境，正在同步快捷指令..."
        if curl -fsSL "$REPO_URL" | tr -d '\r' > "$SHORTCUT_PATH"; then
            chmod +x "$SHORTCUT_PATH"
            echo ">>> 快捷指令 'socks' 已更新。"
        fi
    fi
}

# --- 2. 基础环境 ---
check_root() {
    [ $(id -u) != "0" ] && { echo "Error: 请使用 root 运行"; exit 1; }
}

get_public_ip() {
    PUB_IP=$(curl -s -4 ifconfig.me || curl -s -4 icanhazip.com || curl -s -4 ident.me)
}

install_dependencies() {
    if [ ! -f "$PATH_BIN" ]; then
        echo ">>> 正在安装 3Proxy 环境 (编译预计需要 1 分钟)..."
        apt-get update -qq -y
        apt-get install -y build-essential git curl ufw net-tools >/dev/null 2>&1
        rm -rf /tmp/3proxy
        git clone https://github.com/3proxy/3proxy.git /tmp/3proxy >/dev/null 2>&1
        cd /tmp/3proxy && make -f Makefile.Linux >/dev/null 2>&1
        cp bin/3proxy /usr/bin/ && mkdir -p $PATH_CONF
        init_config_header
    fi
}

init_config_header() {
    cat > $CONF_FILE <<EOF
nserver 8.8.8.8
nserver 1.1.1.1
nscache 65536
timeouts 1 5 30 60 180 180 15 60
maxconn 1000
daemon
log /dev/null
EOF
}

# --- 3. 核心生成逻辑 ---
reload_process() {
    echo ">>> 正在重载 3Proxy 服务..."
    pkill 3proxy 2>/dev/null
    sleep 1
    $PATH_BIN $CONF_FILE >/dev/null 2>&1 &
    sleep 2
    if pgrep 3proxy >/dev/null; then
        echo ">>> 服务启动成功！"
    else
        echo ">>> [错误] 3Proxy 启动失败，请检查配置文件内容。"
    fi
}

generate_nodes() {
    local count=$1; local start_port=$2; local mode=$3; local append=$4; local protocol=$5
    get_public_ip
    
    [ "$append" == "false" ] && echo "--- $protocol Proxy List ---" > $EXPORT_FILE
    [ -f "$CONF_FILE" ] || init_config_header

    echo ">>> 正在写入配置 (协议: $protocol)..."
    local i
    for ((i=0; i<count; i++)); do
        local user="u$(tr -dc 'a-z0-9' </dev/urandom | head -c 4)"
        local pass="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)"
        local real_port=$((start_port + i))
        [ "$mode" == "1" ] && real_port=$start_port

        # 核心修复：每个端口段前必须重申 auth strong，并清除之前的 allow
        echo "users $user:CL:$pass" >> $CONF_FILE
        echo "auth strong" >> $CONF_FILE
        echo "allow $user" >> $CONF_FILE
        
        if [ "$protocol" == "http" ]; then
            # -n: 不使用 NTLM 握手 (提升指纹浏览器兼容性)
            # -a: 支持所有认证方式 (匿名+基本)
            echo "proxy -n -a -p$real_port" >> $CONF_FILE
        else
            # SOCKS5 代理
            echo "socks -n -p$real_port" >> $CONF_FILE
        fi
        
        echo "flush" >> $CONF_FILE
        echo "$PUB_IP:$real_port:$user:$pass" >> $EXPORT_FILE
    done

    # 批量开放防火墙 (针对 VPS 内部)
    local end_port=$((start_port + count - 1))
    [ "$mode" == "1" ] && end_port=$start_port
    ufw allow $start_port:$end_port/tcp >/dev/null 2>&1
    
    reload_process
    echo "========================================================"
    cat $EXPORT_FILE
    echo "========================================================"
    echo "提示: 请确保在 GCP/Oracle 后台开放了 $start_port:$end_port 的入站权限。"
}

# --- 4. 交互菜单 ---
select_protocol_ui() {
    echo "------------------------------------------------"
    echo "请选择代理协议:"
    echo " [1] SOCKS5 (更稳定，推荐)"
    echo " [2] HTTP/HTTPS (适合简单浏览器环境)"
    read -p "选择 [1-2]: " p_choice
    [ "$p_choice" == "2" ] && PROTO_TYPE="http" || PROTO_TYPE="socks"
}

action_add_new() {
    [ ! -f "$CONF_FILE" ] && init_config_header
    local last_port=$(grep -E "(socks|proxy) -p" $CONF_FILE | awk -F'p' '{print $2}' | sort -nr | head -n1)
    [ -z "$last_port" ] && { echo "请先选择 [2] 重置/新建"; return; }
    
    read -p "请输入新增数量: " add_count
    select_protocol_ui
    echo "模式: [1] 复用端口 $last_port  [2] 开启新端口"
    read -p "选择: " add_mode
    if [ "$add_mode" == "1" ]; then
        generate_nodes "$add_count" "$last_port" 1 "true" "$PROTO_TYPE"
    else
        generate_nodes "$add_count" $((last_port + 1)) 2 "true" "$PROTO_TYPE"
    fi
}

action_reset() {
    read -p "确认清除所有节点并重置？(y/n): " confirm
    [ "$confirm" != "y" ] && return
    init_config_header
    read -p "节点数量: " r_count
    select_protocol_ui
    read -p "起始端口: " r_port
    echo "模式: [1] 单端口多用户  [2] 多端口多用户"
    read -p "选择: " r_mode
    generate_nodes "$r_count" "$r_port" "$r_mode" "false" "$PROTO_TYPE"
}

show_menu() {
    clear
    echo "========================================================"
    echo "   3Proxy Manager Pro (GCP/Oracle 优化版)"
    echo "========================================================"
    echo " 1. 🔥 新增节点 (追加)"
    echo " 2. 🔄 重置/新建 (清空旧数据)"
    echo " 3. 📜 查看节点列表"
    echo " 4. 🧹 彻底清空配置"
    echo " 5. 🗑️ 卸载脚本"
    echo " 6. 👁️ 实时监控"
    echo " 0. 退出"
    echo "========================================================"
    read -p "请选择: " OPTION
    case $OPTION in
        1) action_add_new; read -p "回车继续..." ;;
        2) action_reset; read -p "回车继续..." ;;
        3) clear; [ -f "$EXPORT_FILE" ] && cat $EXPORT_FILE || echo "无记录"; read -p "回车继续..." ;;
        4) init_config_header; : > $EXPORT_FILE; reload_process; read -p "已清空，回车继续..." ;;
        5) pkill 3proxy; rm -rf $PATH_CONF $PATH_BIN $SHORTCUT_PATH $EXPORT_FILE; exit 0 ;;
        6) while true; do clear; netstat -tnp | grep 3proxy | grep ESTABLISHED; read -t 2 -n 1 && break; done ;;
        0) exit 0 ;;
        *) show_menu ;;
    esac
    show_menu
}

# --- 执行入口 ---
check_root
install_self
install_dependencies
show_menu
