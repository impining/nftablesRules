#!/bin/bash

set -e

CONFIG_FILE="/etc/nftables.conf"
RULES=""
SNAT_MODE="masquerade"
SNAT_IP=""

# =========================
# 工具函数
# =========================

get_public_ip() {
    curl -s ifconfig.me || curl -s ip.sb || echo "获取失败"
}

set_dns() {
    echo "[+] 设置 DNS 为 223.5.5.5 ..."
    echo "nameserver 223.5.5.5" > /etc/resolv.conf
}

enable_forward() {
    echo "[+] 开启 IP 转发..."
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || \
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
}

disable_iptables() {
    echo "[+] 检查 iptables..."
    systemctl stop iptables 2>/dev/null || true
    systemctl disable iptables 2>/dev/null || true
    iptables -F || true
    iptables -t nat -F || true
}

install_nft() {
    echo "[+] 安装 nftables..."
    if ! command -v nft >/dev/null; then
        apt update
        apt install nftables -y
    fi
}

# =========================
# 规则输入
# =========================

add_rules() {
    while true; do
        echo "---------------------------"
        read -p "入站端口（回车结束）: " IN_PORT
        [ -z "$IN_PORT" ] && break

        read -p "目标 IP: " DEST_IP
        read -p "目标端口: " DEST_PORT
        read -p "协议 (tcp/udp/both): " PROTO

        case $PROTO in
            tcp)
                RULES+="        tcp dport $IN_PORT dnat ip to $DEST_IP:$DEST_PORT\n"
                ;;
            udp)
                RULES+="        udp dport $IN_PORT dnat ip to $DEST_IP:$DEST_PORT\n"
                ;;
            both)
                RULES+="        tcp dport $IN_PORT dnat ip to $DEST_IP:$DEST_PORT\n"
                RULES+="        udp dport $IN_PORT dnat ip to $DEST_IP:$DEST_PORT\n"
                ;;
            *)
                echo "协议错误"
                ;;
        esac
    done
}

# =========================
# SNAT 设置
# =========================

set_snat() {
    echo "SNAT 模式："
    echo "1. 自动 (masquerade) [推荐]"
    echo "2. 指定出口 IP"

    read -p "选择: " CHOICE

    if [ "$CHOICE" == "2" ]; then
        read -p "请输入出口 IP: " SNAT_IP
        SNAT_MODE="snat"
    else
        SNAT_MODE="masquerade"
    fi
}

# =========================
# 写配置
# =========================

write_config() {

if [ "$SNAT_MODE" == "snat" ]; then
    SNAT_RULE="snat ip to $SNAT_IP"
else
    SNAT_RULE="masquerade"
fi

cat > $CONFIG_FILE <<EOF
flush ruleset

table inet nat {
    chain prerouting {
        type nat hook prerouting priority dstnat;
$RULES
    }

    chain postrouting {
        type nat hook postrouting priority srcnat;
        $SNAT_RULE
    }
}

table inet filter {
    chain forward {
        type filter hook forward priority 0;
        policy drop;

        ct state established,related accept
        accept
    }
}
EOF
}

# =========================
# 应用配置
# =========================

apply_config() {
    echo "[+] 检查配置..."
    nft -c -f $CONFIG_FILE

    echo "[+] 启动 nftables..."
    systemctl enable nftables
    systemctl restart nftables
}

# =========================
# 主菜单
# =========================

menu() {
    clear
    echo "=============================="
    echo " nftables 转发管理工具"
    echo "=============================="
    echo "公网 IP: $(get_public_ip)"
    echo "------------------------------"
    echo "1. 一键配置转发"
    echo "2. 查看当前规则"
    echo "3. 清空规则"
    echo "0. 退出"
    echo "=============================="
}

# =========================
# 功能实现
# =========================

case_action() {
    case $1 in
        1)
            set_dns
            enable_forward
            disable_iptables
            install_nft
            add_rules
            set_snat
            write_config
            apply_config
            echo "完成！按回车返回菜单"
            read
            ;;
        2)
            nft list ruleset
            read -p "回车返回"
            ;;
        3)
            echo "flush ruleset" > $CONFIG_FILE
            systemctl restart nftables
            echo "已清空"
            read
            ;;
        0)
            exit
            ;;
        *)
            echo "无效选择"
            sleep 1
            ;;
    esac
}

# =========================
# 循环菜单
# =========================

while true; do
    menu
    read -p "请选择: " CHOICE
    case_action $CHOICE
done