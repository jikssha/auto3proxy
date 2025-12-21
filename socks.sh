#!/bin/bash
# =========================================================
# 3Proxy Manager (Dual Protocol Edition)
# Author: Gemini for Crypto Trader (Modified by dae)
# =========================================================

# --- 核心配置 ---
REPO_URL="https://raw.githubusercontent.com/jikssha/auto3proxy/main/socks.sh"
SHORTCUT_PATH="/usr/bin/socks"
PATH_BIN="/usr/bin/3proxy"
PATH_CONF="/etc/3proxy"
CONF_FILE="/etc/3proxy/3proxy.cfg"
EXPORT_FILE="/root/proxies_export.txt"  # 修改了文件名以体现通用性

# --- 1. 自我修复与快捷键安装 (修复版) ---
install_self() {
    # 只有当脚本不是通过快捷指令运行时，才执行安装/更新
    if [ "$0" != "$SHORTCUT_PATH" ]; then
        echo ">>> 检测到首次运行，正在安装快捷指令 'socks'..."
        
        # 修复点：必须使用 curl 重新下载，不能使用 cp "$0"
        # 这里的 REPO_URL 必须是你 GitHub 的真实 Raw 地址
        if curl -fsSL "$REPO_URL" | tr -d '\r' > "$SHORTCUT_PATH"; then
            chmod +x "$SHORTCUT_PATH"
            echo ">>> 快捷指令安装成功！以后输入 'socks' 即可呼出菜单。"
        else
            echo "Error: 下载脚本失败，请检查 REPO_URL 地址是否正确。"
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
        echo ">>> 安装系统工具..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq -y
        apt-get install -y net-tools >/dev/null 2>&1
    fi

    if [ ! -f "$PATH_BIN" ]; then
        echo ">>> 开始部署 3Proxy 环境..."
        export DEBIAN_FRONTEND=noninteractive
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
maxconn 200
daemon
auth strong
log /dev/null
EOF
}

# --- 4. 进程守护 ---
reload_process() {
    echo ">>> 正在重载进程..."
    pkill 3proxy 2>/dev/null
    $PATH_BIN $CONF_FILE >/dev/null 2>&1 &
    local NEW_PID=$!
    sleep 1
    if ps -p "$NEW_PID" >/dev/null 2>&1; then
        echo ">>> 服务已重启 (PID: $NEW_PID)"
    else
        echo "Warning: 3proxy 启动失败，请检查配置。"
    fi
}

# --- 5. 节点生成逻辑 (核心修改) ---
generate_nodes() {
    local count=$1
    local start_port=$2
    local mode=$3
    local append=$4
    local protocol=$5  # 新增参数：socks 或 http
    
    get_public_ip
    if [ -z "$PUB_IP" ]; then
        echo "Error: 无法获取公网 IP。"
        return 1
    fi
    
    if [ "$append" == "false" ]; then
        echo "================ Proxy List ($protocol) ================" > $EXPORT_FILE
    fi
    
    echo ">>> 正在生成 $count 个 $protocol 节点 (起始端口 $start_port)..."
    
    [ -f "$CONF_FILE" ] || init_config_header
    
    local i
    for ((i=0; i<count; i++)); do
        local user pass real_port
        user="u$(tr -dc 'a-z0-9' </dev/urandom | head -c 4)"
        pass="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)"
        
        echo "users $user:CL:$pass" >> $CONF_FILE
        echo "allow $user" >> $CONF_FILE
        
        if [ "$mode" == "1" ]; then
            real_port=$start_port
        else
            real_port=$((start_port + i))
            
            # 根据协议写入不同指令
            if [ "$protocol" == "http" ]; then
                echo "proxy -p$real_port" >> $CONF_FILE
            else
                echo "socks -p$real_port" >> $CONF_FILE
            fi
            
            echo "flush" >> $CONF_FILE
            ufw allow $real_port/tcp >/dev/null 2>&1
            ufw allow $real_port/udp >/dev/null 2>&1
        fi
        
        # 导出格式：IP:PORT:USER:PASS (通用格式)
        echo "$PUB_IP:$real_port:$user:$pass" >> $EXPORT_FILE
    done

    # 单端口多用户模式的处理
    if [ "$mode" == "1" ]; then
        # 检查是否已经存在该端口的配置（无论是 socks 还是 proxy）
        if ! grep -qE "(socks|proxy) -p$start_port" $CONF_FILE; then
            if [ "$protocol" == "http" ]; then
                echo "proxy -p$start_port" >> $CONF_FILE
            else
                echo "socks -p$start_port" >> $CONF_FILE
            fi
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

# --- 6. 查看节点 ---
action_show_nodes() {
    clear
    echo "========================================================"
    echo " 当前最后一次导出的节点"
    echo " (文件: $EXPORT_FILE)"
    echo "========================================================"
    if [ -f "$EXPORT_FILE" ] && [ -s "$EXPORT_FILE" ]; then
        cat "$EXPORT_FILE"
    else
        echo "无记录。"
    fi
    echo "========================================================"
}

# --- 7. 监控 ---
action_monitor() {
    while true; do
        clear
        echo "========================================================"
        echo " 实时连接监控 (每 2 秒刷新)"
        echo "========================================================"
        printf "%-22s %-25s %s\n" "本地端口" "来源 IP" "状态"
        echo "--------------------------------------------------------"
        # 监控所有 3proxy 建立的连接
        netstat -tnp 2>/dev/null | grep '3proxy' | grep 'ESTABLISHED' | \
          awk '{printf "%-22s %-25s %s\n", $4, $5, $6}'
        echo "--------------------------------------------------------"
        read -t 2 -n 1 key
        if [ $? -eq 0 ]; then break; fi
    done
}

# --- 8. 菜单动作 (包含协议选择) ---
ask_protocol() {
    echo "请选择协议类型:"
    echo " [1] SOCKS5 (默认)"
    echo " [2] HTTP/HTTPS"
    read -p "选择: " proto_choice
    if [ "$proto_choice" == "2" ]; then
        echo "http"
    else
        echo "socks"
    fi
}

action_add_new() {
    if [ ! -f "$CONF_FILE" ]; then init_config_header; fi
    
    # 修改：同时查找 socks 和 proxy 占用的端口，取最大值
    local last_port
    last_port=$(grep -E "(socks|proxy) -p" $CONF_FILE | awk -F'p' '{print $2}' | sort -nr | head -n1)
    
    if [ -z "$last_port" ]; then
        echo "当前没有运行的端口，请先选择〖重置/新建〗。"
        return
    fi
    
    echo "当前最大占用端口: $last_port"
    read -p "请输入新增数量: " add_count
    
    # 获取协议
    local selected_proto=$(ask_protocol)
    
    echo "模式: [1] 复用现有端口($last_port)  [2] 开启新端口(从 $((last_port+1)) 开始)"
    read -p "选择: " add_mode
    
    if [ "$add_mode" == "1" ]; then
        # 注意：如果在 SOCKS 端口上复用并强制指定 HTTP，可能会导致配置混乱，但在单端口模式下
        # 3proxy 通常按顺序读取。建议不同协议使用不同端口。
        generate_nodes "$add_count" "$last_port" 1 "true" "$selected_proto"
    else
        local next_port=$((last_port + 1))
        generate_nodes "$add_count" "$next_port" 2 "true" "$selected_proto"
    fi
}

action_reset() {
    echo "警告：这将删除所有现有节点配置！"
    read -p "确认？(y/n): " confirm
    [ "$confirm" != "y" ] && return
    
    init_config_header
    
    read -p "请输入节点数量: " r_count
    read -p "请输入起始端口: " r_port
    
    local selected_proto=$(ask_protocol)
    
    echo "模式: [1] 单端口多用户  [2] 多端口多用户"
    read -p "选择: " r_mode
    
    generate_nodes "$r_count" "$r_port" "$r_mode" "false" "$selected_proto"
}

action_clear() {
    echo ">>> 正在清空配置..."
    init_config_header
    : > $EXPORT_FILE
    reload_process
    echo ">>> 已重置。"
}

action_uninstall() {
    pkill 3proxy 2>/dev/null
    rm -rf $PATH_CONF $PATH_BIN $EXPORT_FILE $SHORTCUT_PATH
    echo ">>> 卸载完成。"
    exit 0
}

show_menu() {
    clear
    echo "========================================================"
    echo "   3Proxy Manager (SOCKS5 & HTTP)"
    echo "========================================================"
    echo " 1. 🔥 新增/追加节点"
    echo " 2. 🔄 重置/新建节点"
    echo " 3. 📜 查看当前导出记录"
    echo " 4. 🧹 清空所有节点"
    echo " 5. 🗑️ 彻底卸载"
    echo " 6. 👁️ 实时监控"
    echo " 0. 退出"
    echo "========================================================"
    read -p "请选择 [0-6]: " OPTION

    case $OPTION in
        1) action_add_new; read -p "按回车继续..." ;;
        2) action_reset; read -p "按回车继续..." ;;
        3) action_show_nodes; read -p "按回车继续..." ;;
        4) action_clear; read -p "按回车继续..." ;;
        5) action_uninstall ;;
        6) action_monitor; show_menu ;;
        0) exit 0 ;;
        *) echo "无效选项"; sleep 1; show_menu ;;
    esac
}

check_root
install_self
install_dependencies
show_menu

