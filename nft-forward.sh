#!/bin/bash

set -e

CONFIG_FILE="/etc/nftables.conf"
BACKUP_FILE="/etc/nftables.conf.bak"
RULES=""
SNAT_MODE="masquerade"
SNAT_IP=""

# 自动获取出口网卡
WAN_IF=$(ip route get 1 | awk '{print $5; exit}')

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
    iptables -F || true
    iptables -t nat -F || true
}

install_nft() {
    echo "[+] 安装 nftables..."
    if ! command -v nft >/dev/null; then
        apt update
        apt install -y nftables
    fi
}

backup_config() {
    echo "[+] 备份旧配置..."
    cp $CONFIG_FILE $BACKUP_FILE 2>/dev/null || true
}

rollback() {
    echo "[!] 配置失败，正在回滚..."
    cp $BACKUP_FILE $CONFIG_FILE 2>/dev/null || true
    systemctl restart nftables
    exit 1
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

        # 防断线关键规则（SSH）
        tcp dport 22 accept
    }
}
EOF
}

# =========================
# 应用配置（带回滚）
# =========================

apply_config() {
    echo "[+] 检查配置..."
    nft -c -f $CONFIG_FILE || rollback

    echo "[+] 应用配置（10秒内自动回滚保护）..."

    # 启动回滚保护
    (sleep 10 && echo "[!] 未确认，自动回滚..." && rollback) & ROLLBACK_PID=$!

    systemctl enable nftables
    systemctl restart nftables

    echo "[+] 如果网络正常请输入 yes 确认："
    read CONFIRM

    if [ "$CONFIRM" == "yes" ]; then
        kill $ROLLBACK_PID 2>/dev/null || true
        echo "[+] 配置已确认 ✅"
    else
        rollback
    fi
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
    echo "出口网卡: $WAN_IF"
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
            echo "⚠️ 即将修改防火墙规则，可能影响 SSH"
            read -p "确认继续？(y/n): " CONFIRM
            [ "$CONFIRM" != "y" ] && return

            backup_config
            enable_forward
            disable_iptables
            install_nft
            add_rules
            set_snat
            write_config
            apply_config
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

while true; do
    menu
    read -p "请选择: " CHOICE
    case_action $CHOICE
done
