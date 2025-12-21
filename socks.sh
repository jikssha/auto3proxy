#!/bin/bash
# =========================================================
# 3Proxy Manager (Fixed Interaction Logic)
# Author: Gemini for Crypto Trader (Refined by dae)
# =========================================================

# --- 核心配置 ---
REPO_URL="https://raw.githubusercontent.com/jikssha/auto3proxy/main/socks.sh"
SHORTCUT_PATH="/usr/bin/socks"
PATH_BIN="/usr/bin/3proxy"
PATH_CONF="/etc/3proxy"
CONF_FILE="/etc/3proxy/3proxy.cfg"
EXPORT_FILE="/root/proxies_export.txt"

# --- 1. 自我修复与快捷键安装 ---
install_self() {
    if [ "$0" != "$SHORTCUT_PATH" ]; then
        echo ">>> 检测到首次运行，正在安装快捷指令 'socks'..."
        if curl -fsSL "$REPO_URL" | tr -d '\r' > "$SHORTCUT_PATH"; then
            chmod +x "$SHORTCUT_PATH"
            echo ">>> 快捷指令安装成功！以后输入 'socks' 即可呼出菜单。"
        else
            echo "Error: 下载失败，请检查 REPO_URL。"
            exit 1
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
    if ! command -v netstat > /dev/null; then
        apt-get update -qq -y && apt-get install -y net-tools >/dev/null 2>&1
    fi

    if [ ! -f "$PATH_BIN" ]; then
        echo ">>> 正在部署 3Proxy 环境..."
        apt-get update -qq -y
        apt-get install -y build-essential git curl ufw net-tools >/dev/null 2>&1
        rm -rf /tmp/3proxy
        git clone https://github.com/3proxy/3proxy.git /tmp/3proxy >/dev/null 2>&1
        cd /tmp/3proxy
        make -f Makefile.Linux >/dev/null 2>&1
        cp bin/3proxy /usr/bin/
        mkdir -p $PATH_CONF
        init_config_header
    fi
}

init_config_header() {
    cat > $CONF_FILE <<EOF
nserver 8.8.8.8
nserver 1.1.1.1
nscache 65536
timeouts 1 5 30 60 180 180 15 60
maxconn 500
daemon
auth strong
log /dev/null
EOF
}

# --- 4. 进程守护 ---
reload_process() {
    echo ">>> 正在重载进程..."
    pkill 3proxy 2>/dev/null
    sleep 1
    $PATH_BIN $CONF_FILE >/dev/null 2>&1 &
    sleep 1
    if pgrep 3proxy >/dev/null; then
        echo ">>> 服务启动成功 (PID: $(pgrep 3proxy))"
    else
        echo "Warning: 3proxy 启动失败！可能是配置文件有误。"
    fi
}

# --- 5. 节点生成核心逻辑 ---
generate_nodes() {
    local count=$1
    local start_port=$2
    local mode=$3
    local append=$4
    local protocol=$5
    
    get_public_ip
    
    if [ "$append" == "false" ]; then
        echo "================ Proxy List ($protocol) ================" > $EXPORT_FILE
    fi
    
    echo ">>> 开始生成：$count 个节点 | 协议: $protocol | 起始端口: $start_port"
    
    [ -f "$CONF_FILE" ] || init_config_header
    
    local i
    for ((i=0; i<count; i++)); do
        local user pass real_port
        user="u$(tr -dc 'a-z0-9' </dev/urandom | head -c 4)"
        pass="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)"
        
        # 写入用户鉴权
        echo "users $user:CL:$pass" >> $CONF_FILE
        echo "allow $user" >> $CONF_FILE
        
        # 端口计算
        if [ "$mode" == "1" ]; then
            real_port=$start_port
        else
            real_port=$((start_port + i))
            
            # 写入代理指令
            if [ "$protocol" == "http" ]; then
                echo "proxy -p$real_port" >> $CONF_FILE
            else
                echo "socks -p$real_port" >> $CONF_FILE
            fi
            
            echo "flush" >> $CONF_FILE
            ufw allow $real_port/tcp >/dev/null 2>&1
            ufw allow $real_port/udp >/dev/null 2>&1
        fi
        
        echo "$PUB_IP:$real_port:$user:$pass" >> $EXPORT_FILE
    done

    # 单端口模式的特殊处理
    if [ "$mode" == "1" ]; then
        if ! grep -qE "(socks|proxy) -p$start_port" $CONF_FILE; then
            if [ "$protocol" == "http" ]; then
                echo "proxy -p$start_port" >> $CONF_FILE
            else
                echo "socks -p$start_port" >> $CONF_FILE
            fi
            echo "flush" >> $CONF_FILE
            ufw allow $start_port/tcp >/dev/null 2>&1
            ufw allow $start_port/udp >/dev/null 2>&1
        fi
    fi

    reload_process
    
    echo "========================================================"
    echo "完成！请复制下方内容 ($protocol):"
    echo "========================================================"
    cat $EXPORT_FILE
    echo "========================================================"
}

# --- 6. 交互辅助函数 (修复重点) ---
# 这个函数不再返回字符串，而是直接设置全局变量 PROTO_TYPE
select_protocol_ui() {
    echo "------------------------------------------------"
    echo "请选择协议类型:"
    echo " [1] SOCKS5 (默认)"
    echo " [2] HTTP/HTTPS"
    read -p "请输入选项 [1-2]: " p_choice
    if [ "$p_choice" == "2" ]; then
        PROTO_TYPE="http"
    else
        PROTO_TYPE="socks"
    fi
    echo ">>> 已选择协议: $PROTO_TYPE"
}

# --- 7. 菜单动作 ---
action_add_new() {
    if [ ! -f "$CONF_FILE" ]; then init_config_header; fi
    
    local last_port
    last_port=$(grep -E "(socks|proxy) -p" $CONF_FILE | awk -F'p' '{print $2}' | sort -nr | head -n1)
    
    if [ -z "$last_port" ]; then
        echo "当前没有运行的端口，请先选择〖重置/新建〗。"
        return
    fi
    
    echo "------------------------------------------------"
    echo "当前最大端口: $last_port"
    read -p "请输入新增数量: " add_count
    
    # 步骤 2：选择协议
    select_protocol_ui
    
    # 步骤 3：选择模式
    echo "------------------------------------------------"
    echo "模式: [1] 复用现有端口($last_port)  [2] 开启新端口(从 $((last_port+1)) 开始)"
    read -p "选择: " add_mode
    
    if [ "$add_mode" == "1" ]; then
        generate_nodes "$add_count" "$last_port" 1 "true" "$PROTO_TYPE"
    else
        local next_port=$((last_port + 1))
        generate_nodes "$add_count" "$next_port" 2 "true" "$PROTO_TYPE"
    fi
}

action_reset() {
    echo "================ WARNING ================"
    echo "这将删除所有现有配置！"
    read -p "确认重置？(y/n): " confirm
    [ "$confirm" != "y" ] && return
    
    # 初始化配置文件（清空旧数据）
    init_config_header
    
    # 步骤 1：输入数量
    read -p "请输入节点数量: " r_count
    if ! [[ "$r_count" =~ ^[0-9]+$ && "$r_count" -gt 0 ]]; then
        echo "错误：请输入有效数字。"
        return
    fi

    # 步骤 2：选择协议 (交互逻辑优化)
    select_protocol_ui
    
    # 步骤 3：输入端口
    read -p "请输入起始端口 (建议 10000+): " r_port
    if ! [[ "$r_port" =~ ^[0-9]+$ && "$r_port" -gt 0 ]]; then
        echo "错误：端口无效。"
        return
    fi
    
    # 步骤 4：选择模式
    echo "------------------------------------------------"
    echo "模式选择:"
    echo " [1] 单端口多用户 (所有用户共用一个端口出口)"
    echo " [2] 多端口多用户 (每个用户一个独立端口，推荐)"
    read -p "选择: " r_mode
    
    # 执行生成
    generate_nodes "$r_count" "$r_port" "$r_mode" "false" "$PROTO_TYPE"
}

action_show_nodes() {
    clear
    if [ -f "$EXPORT_FILE" ]; then
        cat "$EXPORT_FILE"
    else
        echo "当前无导出记录。"
    fi
}

action_monitor() {
    while true; do
        clear
        echo "=== 实时连接监控 (Ctrl+C 退出) ==="
        netstat -tnp 2>/dev/null | grep '3proxy' | grep 'ESTABLISHED'
        read -t 2 -n 1
        [ $? -eq 0 ] && break
    done
}

action_clear() {
    init_config_header
    reload_process
    : > $EXPORT_FILE
    echo ">>> 已清空所有配置。"
}

action_uninstall() {
    pkill 3proxy
    rm -rf $PATH_CONF $PATH_BIN $EXPORT_FILE $SHORTCUT_PATH
    echo ">>> 卸载完成。"
    exit 0
}

show_menu() {
    clear
    echo "========================================================"
    echo "   3Proxy Manager Pro (v2.0 Fixed)"
    echo "========================================================"
    echo " 1. 🔥 新增/追加节点"
    echo " 2. 🔄 重置/新建节点 (清空旧数据)"
    echo " 3. 📜 查看节点列表"
    echo " 4. 🧹 清空配置"
    echo " 5. 🗑️ 卸载脚本"
    echo " 6. 👁️ 连接监控"
    echo " 0. 退出"
    echo "========================================================"
    read -p "请选择: " OPTION
    case $OPTION in
        1) action_add_new; read -p "按回车继续..." ;;
        2) action_reset; read -p "按回车继续..." ;;
        3) action_show_nodes; read -p "按回车继续..." ;;
        4) action_clear; read -p "按回车继续..." ;;
        5) action_uninstall ;;
        6) action_monitor ;;
        0) exit 0 ;;
        *) echo "无效选项"; sleep 1; show_menu ;;
    esac
}

check_root
install_self
install_dependencies
show_menu
