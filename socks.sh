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

        # 核心修复：确保认证配置在服务定义之前生效
        echo "users $user:CL:$pass" >> $CONF_FILE
        
        if [ "$protocol" == "http" ]; then
            # HTTP/HTTPS 代理配置块
            echo "auth strong" >> $CONF_FILE
            echo "allow $user" >> $CONF_FILE
            echo "proxy -p$real_port" >> $CONF_FILE
            echo "" >> $CONF_FILE  # 空行分隔配置块
        else
            # SOCKS5 代理配置块
            echo "auth strong" >> $CONF_FILE
            echo "allow $user" >> $CONF_FILE
            echo "socks -n -p$real_port" >> $CONF_FILE
            echo "" >> $CONF_FILE  # 空行分隔配置块
        fi
        
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
    echo " [2] HTTP/HTTPS (适合浏览器环境)"
    read -p "选择 [1-2]: " p_choice
    [ "$p_choice" == "2" ] && PROTO_TYPE="http" || PROTO_TYPE="socks"
}

# --- 4.1 智能节点创建/追加 ---
action_create_or_append() {
    if [ -f "$CONF_FILE" ] && grep -qE "(socks|proxy) -p" "$CONF_FILE"; then
        echo "================================================"
        echo "检测到已有节点配置。"
        echo " [1] 追加新节点（保留现有）"
        echo " [2] 覆盖所有节点（清空重建）"
        echo " [0] 返回上一级"
        read -p "请选择: " mode
        case $mode in
            0) submenu_node_manage; return ;;
            2) init_config_header ;;
            1) ;; # 保持配置文件
            *) action_create_or_append; return ;;
        esac
    else
        echo "当前无节点配置，将创建新节点。"
        init_config_header
    fi
    
    read -p "节点数量: " count
    [ -z "$count" ] || [ "$count" -le 0 ] && { echo "数量无效"; read -p "回车继续..."; action_create_or_append; return; }
    
    select_protocol_ui
    
    # 获取起始端口
    local last_port=$(grep -E "(socks|proxy) -p" $CONF_FILE 2>/dev/null | grep -oP 'p\K[0-9]+' | sort -nr | head -n1)
    if [ -z "$last_port" ]; then
        read -p "起始端口 (建议10000-60000): " start_port
    else
        echo "检测到最后使用端口: $last_port"
        echo " [1] 复用端口 $last_port (单端口多用户)"
        echo " [2] 从端口 $((last_port + 1)) 开始 (多端口)"
        read -p "选择: " port_mode
        if [ "$port_mode" == "1" ]; then
            start_port=$last_port
            port_reuse=1
        else
            start_port=$((last_port + 1))
            port_reuse=2
        fi
    fi
    
    generate_nodes "$count" "$start_port" "${port_reuse:-2}" "true" "$PROTO_TYPE"
    read -p "回车继续..."
    submenu_node_manage
}

# --- 4.2 删除单个节点 ---
action_delete_single() {
    if [ ! -f "$EXPORT_FILE" ] || [ ! -s "$EXPORT_FILE" ]; then
        echo "当前无节点记录。"
        read -p "回车返回..."
        submenu_reset
        return
    fi
    
    echo "========== 节点列表 =========="
    nl -w2 -s'. ' "$EXPORT_FILE"
    echo "============================="
    read -p "请输入要删除的节点序号（0 返回）: " num
    
    [ "$num" == "0" ] && submenu_reset && return
    
    # 验证输入
    local total_lines=$(wc -l < "$EXPORT_FILE")
    if [ "$num" -lt 1 ] || [ "$num" -gt "$total_lines" ]; then
        echo "无效序号"
        read -p "回车继续..."
        action_delete_single
        return
    fi
    
    # 获取目标行信息
    local target_line=$(sed -n "${num}p" "$EXPORT_FILE")
    local target_port=$(echo "$target_line" | cut -d':' -f2)
    local target_user=$(echo "$target_line" | cut -d':' -f3)
    
    echo "准备删除: $target_line"
    read -p "确认删除？(y/n): " confirm
    [ "$confirm" != "y" ] && action_delete_single && return
    
    # 备份配置文件
    cp "$CONF_FILE" "${CONF_FILE}.bak"
    
    # 从配置文件删除（匹配用户名对应的配置块：users -> auth -> allow -> proxy/socks -> 空行）
    # 使用更精确的匹配：删除从users行开始，到下一个空行为止的配置块
    sed -i "/users $target_user:/,/^$/d" "$CONF_FILE"
    
    # 从导出文件删除
    sed -i "${num}d" "$EXPORT_FILE"
    
    reload_process
    echo "节点已删除。"
    read -p "回车继续..."
    submenu_reset
}

# --- 4.3 清除所有节点 ---
action_reset_all() {
    read -p "确认清除所有节点？(y/n): " confirm
    [ "$confirm" != "y" ] && submenu_reset && return
    
    init_config_header
    : > "$EXPORT_FILE"
    reload_process
    echo "已清空所有节点。"
    read -p "回车继续..."
    submenu_reset
}

# --- 4.4 查看节点列表（按协议分组）---
action_view_list() {
    clear
    if [ ! -f "$EXPORT_FILE" ] || [ ! -s "$EXPORT_FILE" ]; then
        echo "========================================================"
        echo "   无节点记录"
        echo "========================================================"
        return
    fi
    
    echo "========================================================"
    echo "   节点列表 (按协议分组)"
    echo "========================================================"
    
    # SOCKS5 节点
    echo ""
    echo "【SOCKS5 节点】"
    echo "------------------------------------------------"
    local has_socks=false
    grep -E "socks -" "$CONF_FILE" 2>/dev/null | while read line; do
        local port=$(echo "$line" | grep -oP 'p\K[0-9]+')
        if [ -n "$port" ]; then
            grep ":$port:" "$EXPORT_FILE" 2>/dev/null && has_socks=true
        fi
    done
    $has_socks || echo "(无)"
    
    # HTTP 节点
    echo ""
    echo "【HTTP 节点】"
    echo "------------------------------------------------"
    local has_http=false
    grep -E "proxy -" "$CONF_FILE" 2>/dev/null | while read line; do
        local port=$(echo "$line" | grep -oP 'p\K[0-9]+')
        if [ -n "$port" ]; then
            grep ":$port:" "$EXPORT_FILE" 2>/dev/null && has_http=true
        fi
    done
    $has_http || echo "(无)"
    
    echo "========================================================"
}

# --- 4.5 实时监控 ---
action_monitor() {
    # 捕获 Ctrl+C 中断信号
    trap 'show_menu; return' INT
    
    echo "========================================================"
    echo "   实时监控 (按 Ctrl+C 返回主菜单)"
    echo "========================================================"
    while true; do
        clear
        echo "--- 3Proxy 活动连接 ---"
        netstat -tnp 2>/dev/null | grep 3proxy | grep ESTABLISHED || echo "(暂无活动连接)"
        echo ""
        echo "按 Ctrl+C 返回主菜单"
        sleep 2
    done
    
    # 恢复默认信号处理
    trap - INT
}

# --- 4.6 卸载脚本 ---
action_uninstall() {
    read -p "确认卸载 3Proxy 及所有配置？(y/n): " confirm
    [ "$confirm" != "y" ] && show_menu && return
    
    pkill 3proxy 2>/dev/null
    rm -rf $PATH_CONF $PATH_BIN $SHORTCUT_PATH $EXPORT_FILE
    echo "已卸载。"
    exit 0
}

# --- 4.7 子菜单：节点管理 ---
submenu_node_manage() {
    clear
    echo "========================================================"
    echo "   节点管理"
    echo "========================================================"
    echo " 1. 创建/新增节点"
    echo " 2. 查看已有节点"
    echo " 0. 返回主菜单"
    echo "========================================================"
    read -p "请选择: " choice
    case $choice in
        1) action_create_or_append ;;
        2) action_view_list; read -p "回车继续..." ; submenu_node_manage ;;
        0) show_menu ;;
        *) submenu_node_manage ;;
    esac
}

# --- 4.8 子菜单：重置节点 ---
submenu_reset() {
    clear
    echo "========================================================"
    echo "   重置节点"
    echo "========================================================"
    echo " 1. 清除所有节点"
    echo " 2. 删除单个节点"
    echo " 0. 返回主菜单"
    echo "========================================================"
    read -p "请选择: " choice
    case $choice in
        1) action_reset_all ;;
        2) action_delete_single ;;
        0) show_menu ;;
        *) submenu_reset ;;
    esac
}

# --- 4.9 主菜单 ---
show_menu() {
    clear
    echo "========================================================"
    echo "   3Proxy Manager Pro (增强版)"
    echo "========================================================"
    echo " 1. 📦 节点管理"
    echo " 2. 🔄 重置节点"
    echo " 3. 📜 查看节点列表"
    echo " 4. 🗑️  卸载脚本"
    echo " 5. 👁️  实时监控"
    echo " 0. 退出"
    echo "========================================================"
    read -p "请选择: " OPTION
    case $OPTION in
        1) submenu_node_manage ;;
        2) submenu_reset ;;
        3) action_view_list; read -p "回车继续..." ; show_menu ;;
        4) action_uninstall ;;
        5) action_monitor ;;
        0) exit 0 ;;
        *) show_menu ;;
    esac
}

# --- 执行入口 ---
check_root
install_self
install_dependencies
show_menu
