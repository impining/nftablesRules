#!/bin/bash

set -e

TABLE="ip nat"
PREROUTING="prerouting"
POSTROUTING="postrouting"

WAN_IF=$(ip route get 1.1.1.1 | awk '{print $5; exit}')

pause() {
    echo
    read -r -p "按回车继续..."
}

# =========================
# 初始化基础环境
# =========================

init() {
    echo "[+] 初始化环境..."

    command -v nft >/dev/null || apt update && apt install -y nftables

    systemctl enable nftables >/dev/null 2>&1 || true
    systemctl start nftables

    # 创建基础表（如果不存在）
    nft list table ip nat >/dev/null 2>&1 || {
        nft add table ip nat
    }

    # 创建 chain
    nft list chain ip nat prerouting >/dev/null 2>&1 || \
    nft add chain ip nat prerouting { type nat hook prerouting priority 0 \; }

    nft list chain ip nat postrouting >/dev/null 2>&1 || \
    nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; }

    # masquerade
    nft list ruleset | grep masquerade >/dev/null 2>&1 || \
    nft add rule ip nat postrouting oifname "$WAN_IF" masquerade

    echo "[OK] 初始化完成"
    pause
}

# =========================
# IP 转发
# =========================

enable_forward() {
    echo "[+] 开启 IP 转发..."
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || \
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    echo "[OK] 已开启"
    pause
}

# =========================
# DNS
# =========================

set_dns() {
    read -r -p "DNS (默认 223.5.5.5): " DNS
    DNS=${DNS:-223.5.5.5}
    echo "nameserver $DNS" > /etc/resolv.conf
    echo "[OK] DNS = $DNS"
    pause
}

# =========================
# 添加规则（增量）
# =========================

add_rule() {
    read -r -p "外部端口: " PORT
    read -r -p "目标IP: " DEST_IP
    read -r -p "目标端口: " DEST_PORT

    echo "[+] 添加规则..."

    nft add rule ip nat prerouting tcp dport $PORT dnat to $DEST_IP:$DEST_PORT
    nft add rule ip nat prerouting udp dport $PORT dnat to $DEST_IP:$DEST_PORT

    echo "[OK] 规则已添加"
    pause
}

# =========================
# 查看规则（带编号）
# =========================

view_rules() {
    echo "[+] 当前规则："
    nft list chain ip nat prerouting
    pause
}

# =========================
# 删除规则（按端口匹配）
# =========================

delete_rule() {
    read -r -p "输入端口（删除匹配规则）: " PORT

    RULES=$(nft list chain ip nat prerouting | grep "$PORT")

    if [ -z "$RULES" ]; then
        echo "[!] 未找到规则"
        pause
        return
    fi

    echo "$RULES"
    read -r -p "确认删除? (yes): " CONFIRM

    if [ "$CONFIRM" == "yes" ]; then
        nft delete rule ip nat prerouting handle $(nft -a list chain ip nat prerouting | grep "$PORT" | awk '{print $NF}')
        echo "[OK] 已删除"
    else
        echo "[取消]"
    fi

    pause
}

# =========================
# 状态
# =========================

status() {
    echo "======================"
    echo "网卡: $WAN_IF"
    echo -n "IP转发: "
    [ "$(cat /proc/sys/net/ipv4/ip_forward)" == "1" ] && echo "开启" || echo "关闭"

    echo "[规则]"
    nft list ruleset | grep nat
    echo "======================"
    pause
}

# =========================
# 菜单
# =========================

menu() {
    clear
    echo "====== NAT 专业版 ======"
    echo "网卡: $WAN_IF"
    echo "========================"
    echo "1. 初始化"
    echo "2. 添加端口转发"
    echo "3. 删除端口转发"
    echo "4. 查看规则"
    echo "5. 开启 IP 转发"
    echo "6. 设置 DNS"
    echo "7. 查看状态"
    echo "0. 退出"
    echo "========================"
}

# =========================
# 主循环
# =========================

while true; do
    menu
    read -r -p "请选择: " CHOICE

    case $CHOICE in
        1) init ;;
        2) add_rule ;;
        3) delete_rule ;;
        4) view_rules ;;
        5) enable_forward ;;
        6) set_dns ;;
        7) status ;;
        0) exit ;;
        *) echo "无效选项"; sleep 1 ;;
    esac
done
