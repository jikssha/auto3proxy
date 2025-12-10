#!/bin/bash
echo ">>> 正在停止服务..."
tmux kill-session -t socksproxyd 2>/dev/null
pkill 3proxy
echo ">>> 正在清理文件..."
rm -rf /etc/3proxy
rm -rf /usr/bin/3proxy
rm -rf /root/socks5_export.txt
echo ">>> 卸载完成。(请记得手动去云服务商后台关闭防火墙端口)"
