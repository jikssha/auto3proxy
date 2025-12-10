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
        apt-get install -y build-essential git curl ufw net-tools >/dev/null 2>&1
        
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
# 连接/IO/关闭等超时设置
timeouts 1 5 30 60 180 180 15 60
# 限制最大并发连接数，防止被滥用时压垮 VPS，可按机器性能调整
maxconn 100
# 让 3proxy 自己以守护进程方式跑在后台
daemon
# 强认证（用户名密码）
auth strong
# 默认不写日志，如有需要可自行改为文件路径
log /dev/null
EOF
}

# --- 4. 进程守护 ---
# 修复版：不再使用 tmux 死循环，只启动一份 3proxy 守护进程
reload_process() {
    echo ">>> 正在重载进程..."
    # 结束旧的 3proxy
    pkill 3proxy 2>/dev/null
    # 启动新的 3proxy，3proxy 会根据配置中的 daemon 指令自己退到后台
    $PATH_BIN $CONF_FILE >/dev/null 2>&1 &
    local NEW_PID=$!
    if ps -p "$NEW_PID" >/dev/null 2>&1; then
        echo ">>> 服务已重启 (PID: $NEW_PID)"
    else
        echo "Warning: 3proxy 看起来没有成功启动，请用 ps aux | grep 3proxy 手动确认。"
    fi
}

# --- 5. 节点生成逻辑 ---
generate_nodes() {
    local count=$1
    local start_port=$2
    local mode=$3
    local append=$4
    
    get_public_ip
    if [ -z "$PUB_IP" ]; then
        echo "Error: 无法获取公网 IP，生成节点中止。"
        return 1
    fi
    
    if [ "$append" == "false" ]; then
        echo "================ SOCKS5 list ================" > $EXPORT_FILE
    fi
    
    echo ">>> 正在生成 $count 个节点 (起始端口 $start_port, 模式 $mode)..."
    
    # 确保配置文件已存在
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
            echo "socks -p$real_port" >> $CONF_FILE
            echo "flush" >> $CONF_FILE
            ufw allow $real_port/tcp >/dev/null 2>&1
            ufw allow $real_port/udp >/dev/null 2>&1
        fi
        
        echo "$PUB_IP:$real_port:$user:$pass" >> $EXPORT_FILE
    done

    # 单端口多用户模式：只写一次 socks 行
    if [ "$mode" == "1" ]; then
        if ! grep -q "socks -p$start_port" $CONF_FILE; then
            echo "socks -p$start_port" >> $CONF_FILE
            ufw allow $start_port/tcp >/dev/null 2>&1
            ufw allow $start_port/udp >/dev/null 2>&1
        fi
    fi

    reload_process
    
    echo "========================================================"
    echo "完成！请复制下方内容导入指纹浏览器:"
    echo "========================================================"
    cat $EXPORT_FILE
    echo "========================================================"
}

# --- 6. 查看当前节点 ---
action_show_nodes() {
    clear
    echo "========================================================"
    echo " 当前已生成的 SOCKS5 节点"
    echo " (数据来源: $EXPORT_FILE)"
    echo "========================================================"
    if [ -f "$EXPORT_FILE" ] && [ -s "$EXPORT_FILE" ]; then
        cat "$EXPORT_FILE"
    else
        echo "当前还没有导出的节点记录。"
    fi
    echo "========================================================"
}

# --- 7. 监控功能 ---
action_monitor() {
    while true; do
        clear
        echo "========================================================"
        echo " SOCKS5 实时连接监控 (每 2 秒刷新)"
        echo " 按任意键返回主菜单..."
        echo "========================================================"
        printf "%-22s %-25s %s\n" "本地端口" "来源 IP" "状态"
        echo "--------------------------------------------------------"
        netstat -tnp 2>/dev/null | grep '3proxy' | grep 'ESTABLISHED' | \
          awk '{printf "%-22s %-25s %s\n", $4, $5, $6}'
        echo "--------------------------------------------------------"
        read -t 2 -n 1 key
        if [ $? -eq 0 ]; then
            break
        fi
    done
}

# --- 8. 菜单动作 ---
action_add_new() {
    if [ ! -f "$CONF_FILE" ]; then
        init_config_header
    fi
    
    local last_port
    last_port=$(grep "socks -p" $CONF_FILE | awk -F'p' '{print $2}' | sort -nr | head -n1)
    
    if [ -z "$last_port" ]; then
        echo "当前没有运行的端口，请先选择〖重置/新建〗。"
        return
    fi
    
    echo "当前最大占用端口: $last_port"
    read -p "请输入要〖新增〗的节点数量: " add_count
    if ! [[ "$add_count" =~ ^[0-9]+$ && "$add_count" -gt 0 ]]; then
        echo "输入有误。"
        return
    fi
    
    echo "模式: [1] 复用现有端口($last_port)  [2] 开启新端口(从 $((last_port+1)) 开始)"
    read -p "选择: " add_mode
    
    if [ "$add_mode" == "1" ]; then
        generate_nodes "$add_count" "$last_port" 1 "true"
    else
        local next_port=$((last_port + 1))
        generate_nodes "$add_count" "$next_port" 2 "true"
    fi
}

action_reset() {
    echo "警告：这将删除所有现有节点配置！"
    read -p "确认？(y/n): " confirm
    [ "$confirm" != "y" ] && return
    
    init_config_header
    
    read -p "请输入节点数量: " r_count
    read -p "请输入起始端口: " r_port
    echo "模式: [1] 单端口多用户  [2] 多端口多用户"
    read -p "选择: " r_mode
    
    if ! [[ "$r_count" =~ ^[0-9]+$ && "$r_count" -gt 0 ]]; then
        echo "节点数量输入有误。"
        return
    fi
    if ! [[ "$r_port" =~ ^[0-9]+$ && "$r_port" -gt 0 ]]; then
        echo "端口输入有误。"
        return
    fi
    
    generate_nodes "$r_count" "$r_port" "$r_mode" "false"
}

action_clear() {
    echo ">>> 正在清空所有配置..."
    init_config_header
    : > $EXPORT_FILE
    reload_process
    echo ">>> 所有节点已删除，进程已重置。"
}

action_uninstall() {
    echo ">>> 正在彻底卸载..."
    pkill 3proxy 2>/dev/null
    rm -rf $PATH_CONF $PATH_BIN $EXPORT_FILE $SHORTCUT_PATH
    echo ">>> 卸载完成。"
    exit 0
}

show_menu() {
    clear
    echo "========================================================"
    echo "   3Proxy Manager Pro (Cmd: socks)"
    echo "========================================================"
    echo " 1. 🔥 新增/追加节点"
    echo " 2. 🔄 重置/新建节点 (无日志模式)"
    echo " 3. 📜 查看当前所有节点"
    echo " 4. 🧹 清空所有节点"
    echo " 5. 🗑️ 彻底卸载"
    echo " 6. 👁️ 实时连接监控"
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

# --- 脚本入口 ---
# 顺序执行：检查权限 -> 自我安装 -> 安装依赖 -> 显示菜单
check_root
install_self
install_dependencies
show_menu

