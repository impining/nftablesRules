#!/bin/bash

set -e

CONFIG_FILE="/etc/nftables.conf"
BACKUP_FILE="/etc/nftables.conf.bak"

WAN_IF=$(ip route get 1.1.1.1 | awk '{print $5; exit}')

# =========================
# 基础函数
# =========================

backup() {
    cp $CONFIG_FILE $BACKUP_FILE 2>/dev/null || true
}

rollback() {
    echo "[!] 回滚配置..."
    cp $BACKUP_FILE $CONFIG_FILE 2>/dev/null || true
    systemctl restart nftables
    exit 1
}

enable_forward() {
    echo "[+] 开启 IP 转发..."
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || \
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
}

set_dns() {
    echo "[+] 设置 DNS..."

    read -r -p "DNS (默认 223.5.5.5): " DNS
    DNS=${DNS:-223.5.5.5}

    echo "nameserver $DNS" > /etc/resolv.conf
}

install_nft() {
    command -v nft >/dev/null || (apt update && apt install -y nftables)
}

# =========================
# 生成配置
# =========================

write_config() {

cat > $CONFIG_FILE <<EOF
flush ruleset

table ip nat {

    chain prerouting {
        type nat hook prerouting priority dstnat;
$(generate_rules)
    }

    chain postrouting {
        type nat hook postrouting priority srcnat;
        oifname "$WAN_IF" masquerade
    }
}

table ip filter {

    chain forward {
        type filter hook forward priority 0;
        policy accept;
    }

    chain input {
        type filter hook input priority 0;
        policy accept;
    }
}
EOF
}

RULES=()

add_rule() {
    local port=$1
    local ip=$2
    local dport=$3

    RULES+=("tcp dport $port dnat to $ip:$dport")
    RULES+=("udp dport $port dnat to $ip:$dport")
}

generate_rules() {
    for r in "${RULES[@]}"; do
        echo "        $r"
    done
}

# =========================
# 输入规则
# =========================

add_forward() {
    while true; do
        echo "---------------------------"
        read -r -p "外部端口(回车结束): " PORT
        [ -z "$PORT" ] && break

        read -r -p "目标IP: " DEST_IP
        read -r -p "目标端口: " DEST_PORT

        add_rule "$PORT" "$DEST_IP" "$DEST_PORT"
    done
}

# =========================
# 应用
# =========================

apply() {
    echo "[+] 校验配置..."
    nft -c -f $CONFIG_FILE || rollback

    (sleep 10 && echo "[!] 自动回滚" && rollback) & RPID=$!

    systemctl enable nftables
    systemctl restart nftables

    read -r -p "输入 yes 确认: " CONFIRM

    if [ "$CONFIRM" == "yes" ]; then
        kill $RPID 2>/dev/null || true
        echo "[+] 成功 ✅"
    else
        rollback
    fi
}

# =========================
# 查看 / 清空
# =========================

view_rules() {
    nft list ruleset
    read
}

clear_rules() {
    echo "flush ruleset" > $CONFIG_FILE
    systemctl restart nftables
    echo "[+] 已清空"
    read
}

# =========================
# 初始化
# =========================

init_system() {
    install_nft
    enable_forward
    set_dns
    backup
}

# =========================
# 菜单
# =========================

menu() {
    clear
    echo "=============================="
    echo " NAT 面板（IPv4 版）"
    echo " 网卡: $WAN_IF"
    echo "=============================="
    echo "1. 添加端口转发"
    echo "2. 查看规则"
    echo "3. 清空规则"
    echo "4. 设置 DNS"
    echo "5. 开启 IP 转发"
    echo "0. 退出"
    echo "=============================="
}

# =========================
# 主循环
# =========================

init_system

while true; do
    menu
    read -r -p "请选择: " CHOICE

    case $CHOICE in
        1)
            add_forward
            write_config
            apply
            ;;
        2)
            view_rules
            ;;
        3)
            clear_rules
            ;;
        4)
            set_dns
            ;;
        5)
            enable_forward
            ;;
        0)
            exit
            ;;
    esac
done
