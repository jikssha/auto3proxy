#!/bin/bash
# =========================================================
# 3Proxy Manager Pro Plus (No-Log + Monitor)
# Author: Gemini for Crypto Trader
# =========================================================

# --- 全局变量 ---
PATH_BIN="/usr/bin/3proxy"
PATH_CONF="/etc/3proxy"
CONF_FILE="/etc/3proxy/3proxy.cfg"
EXPORT_FILE="/root/socks5_export.txt"
SHORTCUT_NAME="socks"

# --- 1. 基础检查与快捷键安装 ---
install_shortcut() {
    if [ ! -f "/usr/bin/$SHORTCUT_NAME" ]; then
        echo ">>> 正在安装快捷指令 '$SHORTCUT_NAME'..."
        cp "$0" "/usr/bin/$SHORTCUT_NAME"
        chmod +x "/usr/bin/$SHORTCUT_NAME"
        echo ">>> 快捷指令安装成功！以后输入 '$SHORTCUT_NAME' 即可管理。"
        sleep 1
    else
        if ! cmp -s "$0" "/usr/bin/$SHORTCUT_NAME"; then
            cp "$0" "/usr/bin/$SHORTCUT_NAME"
            chmod +x "/usr/bin/$SHORTCUT_NAME"
        fi
    fi
}

check_root() {
    [ $(id -u) != "0" ] && { echo "Error: 请使用 root 运行"; exit 1; }
}

get_public_ip() {
    PUB_IP=$(curl -s -4 ifconfig.me)
    [ -z "$PUB_IP" ] && PUB_IP=$(curl -s -4 icanhazip.com)
}

# --- 2. 核心安装逻辑 ---
install_dependencies() {
    # 检查是否安装了 net-tools (netstat需要)
    if ! command -v netstat > /dev/null; then
        echo ">>> 安装网络工具包..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq -y
        apt-get install -y net-tools >/dev/null 2>&1
    fi

    if [ ! -f "$PATH_BIN" ]; then
        echo ">>> 检测到未安装 3Proxy，开始初始化环境..."
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
        
        init_config_header
    fi
}

init_config_header() {
    # Pro Plus: 这里加入了 log /dev/null 实现彻底无日志
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

# --- 3. 进程守护管理 ---
reload_process() {
    echo ">>> 正在重载进程..."
    tmux kill-session -t socksproxyd 2>/dev/null
    pkill 3proxy
    tmux new-session -d -s socksproxyd "while true; do $PATH_BIN $CONF_FILE; sleep 1; done"
    echo ">>> 服务已重启，隐匿配置已生效。"
}

# --- 4. 功能：生成节点 ---
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
    echo "操作完成！当前节点列表:"
    echo "========================================================"
    cat $EXPORT_FILE
    echo "========================================================"
    echo "已保存至: $EXPORT_FILE"
}

# --- 5. 功能：实时监控 (新增) ---
action_monitor() {
    while true; do
        clear
        echo "========================================================"
        echo "   👁️  SOCKS5 实时连接监控 (每 2 秒刷新)"
        echo "   按任意键返回主菜单..."
        echo "========================================================"
        printf "%-22s %-25s %s\n" "本地端口" "来源 IP (指纹浏览器)" "状态"
        echo "--------------------------------------------------------"
        
        # 过滤出 3proxy 相关的 ESTABLISHED 连接
        # 显示格式：本地IP:端口  远程IP:端口  ESTABLISHED
        netstat -tnp 2>/dev/null | grep '3proxy' | grep 'ESTABLISHED' | awk '{printf "%-22s %-25s %s\n", $4, $5, $6}'
        
        echo "--------------------------------------------------------"
        echo "提示：如果列表为空，说明当前没有活跃流量。"
        
        # 等待2秒，如果用户按键则退出循环
        read -t 2 -n 1 key
        if [ $? -eq 0 ]; then
            break
        fi
    done
}

# --- 6. 菜单动作 ---

action_add_new() {
    LAST_PORT=$(grep "socks -p" $CONF_FILE | awk -F'p' '{print $2}' | sort -nr | head -n1)
    if [ -z "$LAST_PORT" ]; then
        echo "当前没有运行的端口，请选择【重置/新建】。"
        return
    fi
    echo "当前最大占用端口: $LAST_PORT"
    read -p "请输入要【新增】的节点数量: " ADD_COUNT
    echo "模式: [1] 复用现有端口($LAST_PORT)  [2] 开启新端口(从 $(($LAST_PORT+1)) 开始)"
    read -p "选择: " ADD_MODE
    if [ "$ADD_MODE" == "1" ]; then
        generate_nodes $ADD_COUNT $LAST_PORT 1 "true"
    else
        NEXT_PORT=$(($LAST_PORT + 1))
        generate_nodes $ADD_COUNT $NEXT_PORT 2 "true"
    fi
}

action_reset() {
    echo "警告：这将删除所有现有节点配置！"
    read -p "确认？(y/n): " CONFIRM
    [ "$CONFIRM" != "y" ] && return
    init_config_header
    read -p "请输入节点数量: " R_COUNT
    read -p "请输入起始端口: " R_PORT
    echo "模式: [1] 单端口多用户  [2] 多端口多用户"
    read -p "选择: " R_MODE
    generate_nodes $R_COUNT $R_PORT $R_MODE "false"
}

action_clear() {
    echo ">>> 正在清空所有配置..."
    init_config_header
    > $EXPORT_FILE
    reload_process
    echo ">>> 所有节点已删除，进程已重置 (空载状态)。"
}

action_uninstall() {
    echo ">>> 正在彻底卸载..."
    tmux kill-session -t socksproxyd 2>/dev/null
    pkill 3proxy
    rm -rf $PATH_CONF $PATH_BIN $EXPORT_FILE /usr/bin/$SHORTCUT_NAME
    echo ">>> 卸载完成。"
    exit 0
}

# --- 7. 主菜单 ---
show_menu() {
    clear
    echo "========================================================"
    echo "   3Proxy Manager Pro+ (Cmd: $SHORTCUT_NAME)"
    echo "========================================================"
    echo " 1. 🔥 新增/追加节点"
    echo " 2. 🔄 重置/新建节点 (无日志模式)"
    echo " 3. 🧹 清空所有节点"
    echo " 4. 🗑️ 彻底卸载"
    echo " 5. 👁️ 实时连接监控 (看谁在连我)"
    echo " 0. 退出"
    echo "========================================================"
    read -p "请选择 [0-5]: " OPTION
    
    case $OPTION in
        1) action_add_new; read -p "按回车继续..." ;;
        2) action_reset; read -p "按回车继续..." ;;
        3) action_clear; read -p "按回车继续..." ;;
        4) action_uninstall ;;
        5) action_monitor; show_menu ;; # 监控退出后返回菜单
        0) exit 0 ;;
        *) echo "无效选项"; sleep 1; show_menu ;;
    esac
}

# --- 入口 ---
check_root
install_shortcut
install_dependencies
if [ $# -gt 0 ]; then
    echo "暂不支持参数模式"
else
    show_menu
fi
