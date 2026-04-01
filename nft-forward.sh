#!/bin/bash

set -e

WAN_IF=$(ip route get 1.1.1.1 | awk '{print $5; exit}')

pause() {
    echo
    read -r -p "按回车继续..."
}

# =========================
# 状态检测
# =========================

detect_env() {
    echo "=============================="
    echo "[环境检测]"
    echo "=============================="

    echo "[网卡] $WAN_IF"

    echo -n "[IP转发] "
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" == "1" ]; then
        echo "开启"
    else
        echo "关闭"
    fi

    echo "[iptables 规则数量]"
    iptables -S 2>/dev/null | wc -l

    echo "[nftables 规则]"
    nft list ruleset 2>/dev/null | head -n 5

    echo "=============================="
    pause
}

# =========================
# 安全清理 iptables（可选）
# =========================

clear_iptables_safe() {
    echo "[!] 即将清空 iptables 规则（危险操作）"
    read -r -p "输入 YES 确认: " CONFIRM

    if [ "$CONFIRM" == "YES" ]; then
        iptables -F
        iptables -t nat -F
        iptables -t mangle -F
        iptables -X
        echo "[OK] iptables 已清空"
    else
        echo "[取消]"
    fi

    pause
}

# =========================
# 开启 IP 转发（手动）
# =========================

enable_forward() {
    echo "[!] 开启 IP 转发（系统级修改）"
    read -r -p "输入 YES 确认: " CONFIRM

    if [ "$CONFIRM" == "YES" ]; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null
        grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || \
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        echo "[OK] 已开启"
    else
        echo "[取消]"
    fi

    pause
}

# =========================
# nft NAT 增量规则
# =========================

add_nft_rule() {
    echo "[+] 添加 NAT 转发规则"

    read -r -p "外部端口: " PORT
    read -r -p "目标IP: " DEST_IP
    read -r -p "目标端口: " DEST_PORT

    echo "[!] 确认添加规则:"
    echo "    $PORT -> $DEST_IP:$DEST_PORT"
    read -r -p "输入 YES 确认: " CONFIRM

    if [ "$CONFIRM" == "YES" ]; then
        nft add rule ip nat prerouting tcp dport $PORT dnat to $DEST_IP:$DEST_PORT
        nft add rule ip nat prerouting udp dport $PORT dnat to $DEST_IP:$DEST_PORT
        nft add rule ip nat postrouting oifname "$WAN_IF" masquerade
        echo "[OK] 规则已添加"
    else
        echo "[取消]"
    fi

    pause
}

# =========================
# 查看规则
# =========================

view_rules() {
    nft list ruleset
    pause
}

# =========================
# 菜单
# =========================

menu() {
    clear
    echo "====== 安全生产版 NAT 管理 ======"
    echo "网卡: $WAN_IF"
    echo "================================="
    echo "1. 环境检测（只读）"
    echo "2. 添加 NAT 转发（nft）"
    echo "3. 查看规则"
    echo "4. 开启 IP 转发（手动确认）"
    echo "5. 清空 iptables（危险）"
    echo "0. 退出"
    echo "================================="
}

# =========================
# 主循环
# =========================

while true; do
    menu
    read -r -p "请选择: " CHOICE

    case $CHOICE in
        1) detect_env ;;
        2) add_nft_rule ;;
        3) view_rules ;;
        4) enable_forward ;;
        5) clear_iptables_safe ;;
        0) exit ;;
        *) echo "无效选项"; sleep 1 ;;
    esac
done
