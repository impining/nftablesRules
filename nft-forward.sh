#!/bin/bash

set -e

CONFIG_FILE="/etc/nftables.conf"
BACKUP_FILE="/etc/nftables.conf.bak"

WAN_IF=$(ip route get 1 2>/dev/null | awk '{print $5; exit}')

RULES_TCP=()
RULES_UDP=()

SNAT_MODE="masquerade"
SNAT_IP=""

# =========================
# 基础功能
# =========================

get_public_ip() {
    curl -s ifconfig.me || curl -s ip.sb || echo "获取失败"
}

enable_forward() {
    echo "[+] 开启 IP 转发..."
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || \
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
}

install_nft() {
    echo "[+] 安装 nftables..."
    command -v nft >/dev/null || (apt update && apt install -y nftables)
}

backup_config() {
    cp $CONFIG_FILE $BACKUP_FILE 2>/dev/null || true
}

rollback() {
    echo "[!] 回滚配置..."
    cp $BACKUP_FILE $CONFIG_FILE 2>/dev/null || true
    systemctl restart nftables
    exit 1
}

# =========================
# 输入规则
# =========================

add_rules() {
    while true; do
        echo "---------------------------"
        read -r -p "入站端口（回车结束）: " IN_PORT
        [ -z "$IN_PORT" ] && break

        read -r -p "目标 IP: " DEST_IP
        read -r -p "目标端口: " DEST_PORT
        read -r -p "协议 (tcp/udp/both): " PROTO

        case $PROTO in
            tcp)
                RULES_TCP+=("ip protocol tcp iifname \"$WAN_IF\" tcp dport $IN_PORT dnat to $DEST_IP:$DEST_PORT")
                ;;
            udp)
                RULES_UDP+=("ip protocol udp iifname \"$WAN_IF\" udp dport $IN_PORT dnat to $DEST_IP:$DEST_PORT")
                ;;
            both)
                RULES_TCP+=("ip protocol tcp iifname \"$WAN_IF\" tcp dport $IN_PORT dnat to $DEST_IP:$DEST_PORT")
                RULES_UDP+=("ip protocol udp iifname \"$WAN_IF\" udp dport $IN_PORT dnat to $DEST_IP:$DEST_PORT")
                ;;
            *)
                echo "协议错误"
                ;;
        esac
    done
}

# =========================
# SNAT
# =========================

set_snat() {
    echo "SNAT 模式:"
    echo "1. masquerade（推荐）"
    echo "2. 指定 IP"

    read -r -p "选择: " CHOICE

    if [ "$CHOICE" == "2" ]; then
        read -r -p "出口 IP: " SNAT_IP
        SNAT_MODE="snat"
    else
        SNAT_MODE="masquerade"
    fi
}

# =========================
# 写 nft 配置
# =========================

write_config() {

if [ "$SNAT_MODE" == "snat" ]; then
    SNAT_RULE="oifname \"$WAN_IF\" snat to $SNAT_IP"
else
    SNAT_RULE="oifname \"$WAN_IF\" masquerade"
fi

cat > $CONFIG_FILE <<EOF
flush ruleset

table inet nat {

    chain prerouting {
        type nat hook prerouting priority dstnat;

$(for r in "${RULES_TCP[@]}"; do echo "        $r"; done)
$(for r in "${RULES_UDP[@]}"; do echo "        $r"; done)

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
        ct state new accept
    }

    chain input {
        type filter hook input priority 0;
        policy drop;

        iif lo accept
        ct state established,related accept

        tcp dport 22 accept
    }
}
EOF
}

# =========================
# 应用配置
# =========================

apply_config() {
    echo "[+] 检查配置..."
    nft -c -f $CONFIG_FILE || rollback

    echo "[+] 应用配置（10秒回滚保护）..."

    (sleep 10 && echo "[!] 未确认自动回滚" && rollback) & RPID=$!

    systemctl enable nftables
    systemctl restart nftables

    read -r -p "输入 yes 确认: " CONFIRM

    if [ "$CONFIRM" == "yes" ]; then
        kill $RPID 2>/dev/null || true
        echo "[+] 配置成功 ✅"
    else
        rollback
    fi
}

# =========================
# 菜单
# =========================

menu() {
    clear
    echo "=============================="
    echo " nftables 转发工具"
    echo "=============================="
    echo "公网IP: $(get_public_ip)"
    echo "出口网卡: $WAN_IF"
    echo "------------------------------"
    echo "1. 一键配置"
    echo "2. 查看规则"
    echo "3. 清空规则"
    echo "0. 退出"
    echo "=============================="
}

case_action() {
    case $1 in
        1)
            read -r -p "确认继续? (y/n): " c
            [ "$c" != "y" ] && return

            backup_config
            enable_forward
            install_nft
            add_rules
            set_snat
            write_config
            apply_config
            ;;
        2)
            nft list ruleset
            read
            ;;
        3)
            echo "flush ruleset" > $CONFIG_FILE
            systemctl restart nftables
            ;;
        0)
            exit
            ;;
    esac
}

while true; do
    menu
    read -r -p "请选择: " CHOICE
    case_action $CHOICE
done
