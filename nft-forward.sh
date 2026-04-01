#!/bin/bash

set -e

CONFIG_FILE="/etc/nftables.conf"
BACKUP_FILE="/etc/nftables.conf.bak"

RULES=""
SNAT_MODE="masquerade"
SNAT_IP=""

# 自动获取出口网卡（带兜底）
WAN_IF=$(ip route | awk '/default/ {print $5; exit}')
WAN_IF=${WAN_IF:-eth0}

# =========================
# 工具函数
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

disable_iptables() {
    echo "[+] 关闭 iptables..."
    systemctl stop iptables 2>/dev/null || true
    systemctl disable iptables 2>/dev/null || true
    iptables -F 2>/dev/null || true
    iptables -t nat -F 2>/dev/null || true
}

install_nft() {
    echo "[+] 安装 nftables..."
    if ! command -v nft >/dev/null; then
        apt update
        apt install -y nftables
    fi
}

backup_config() {
    echo "[+] 备份配置..."
    cp $CONFIG_FILE $BACKUP_FILE 2>/dev/null || true
}

rollback() {
    echo "[!] 发生错误，回滚配置..."
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

        read -r -p "入站端口（回车结束）: " IN_PORT || continue
        [ -z "$IN_PORT" ] && break

        read -r -p "目标 IP: " DEST_IP || continue
        read -r -p "目标端口: " DEST_PORT || continue
        read -r -p "协议 (tcp/udp/both): " PROTO || continue

        case $PROTO in
            tcp)
                RULES+="        iifname \"$WAN_IF\" tcp dport $IN_PORT dnat to $DEST_IP:$DEST_PORT\n"
                ;;
            udp)
                RULES+="        iifname \"$WAN_IF\" udp dport $IN_PORT dnat to $DEST_IP:$DEST_PORT\n"
                ;;
            both)
                RULES+="        iifname \"$WAN_IF\" tcp dport $IN_PORT dnat to $DEST_IP:$DEST_PORT\n"
                RULES+="        iifname \"$WAN_IF\" udp dport $IN_PORT dnat to $DEST_IP:$DEST_PORT\n"
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
    echo "1. 自动 (masquerade)"
    echo "2. 指定出口 IP"

    read -r -p "选择: " CHOICE || return

    if [ "$CHOICE" == "2" ]; then
        read -r -p "请输入出口 IP: " SNAT_IP || return
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
    SNAT_RULE="oifname \"$WAN_IF\" snat to $SNAT_IP"
else
    SNAT_RULE="oifname \"$WAN_IF\" masquerade"
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
        ct state new accept
    }

    chain input {
        type filter hook input priority 0;
        policy drop;

        iif lo accept
        ct state established,related accept

        # 防 SSH 断线（重要）
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

    echo "[+] 应用配置..."

    systemctl enable nftables
    systemctl restart nftables
}

# =========================
# 菜单
# =========================

menu() {
    clear

    pub_ip=$(get_public_ip 2>/dev/null || echo "获取失败")

    echo "=============================="
    echo " nftables 转发管理工具"
    echo "=============================="
    echo "公网 IP: $pub_ip"
    echo "出口网卡: $WAN_IF"
    echo "------------------------------"
    echo "1. 一键配置转发"
    echo "2. 查看当前规则"
    echo "3. 清空规则"
    echo "0. 退出"
    echo "=============================="
}

# =========================
# 主逻辑
# =========================

case_action() {
    case $1 in
        1)
            echo "⚠️ 可能影响 SSH，请确认"
            read -r -p "继续? (y/n): " CONFIRM || return
            [ "$CONFIRM" != "y" ] && return

            backup_config
            enable_forward
            disable_iptables
            install_nft

            add_rules
            set_snat
            write_config
            apply_config

            read -r -p "完成，回车返回"
            ;;
        2)
            nft list ruleset
            read -r -p "回车返回"
            ;;
        3)
            echo "flush ruleset" > $CONFIG_FILE
            systemctl restart nftables
            echo "已清空"
            read -r -p "回车返回"
            ;;
        0)
            exit 0
            ;;
        *)
            echo "无效选择"
            sleep 1
            ;;
    esac
}

# =========================
# 循环
# =========================

while true; do
    menu
    read -r -p "请选择: " CHOICE || continue
    case_action "$CHOICE"
done
