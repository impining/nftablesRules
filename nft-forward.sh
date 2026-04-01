#!/bin/bash

set -e

CONFIG_FILE="/etc/nftables.conf"
BACKUP_FILE="/etc/nftables.conf.bak"

WAN_IF=$(ip route get 1.1.1.1 | awk '{print $5; exit}')

# =========================
# 工具函数
# =========================

pause() {
    echo
    read -r -p "按回车继续..."
}

backup() {
    cp $CONFIG_FILE $BACKUP_FILE 2>/dev/null || true
}

rollback() {
    echo "[!] 发生错误，正在回滚..."
    cp $BACKUP_FILE $CONFIG_FILE 2>/dev/null || true
    systemctl restart nftables
    pause
    exit 1
}

# =========================
# 系统状态
# =========================

show_status() {
    echo "=============================="
    echo "系统状态"
    echo "=============================="

    echo "[网卡] $WAN_IF"

    echo -n "[IP转发] "
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" == "1" ]; then
        echo "开启"
    else
        echo "关闭"
    fi

    echo "[DNS]"
    cat /etc/resolv.conf 2>/dev/null | grep nameserver || echo "未设置"

    echo "[nftables 服务]"
    systemctl is-active nftables >/dev/null && echo "运行中" || echo "未运行"

    echo "=============================="
    pause
}

# =========================
# 功能模块
# =========================

enable_forward() {
    echo "[+] 开启 IP 转发..."
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || \
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    echo "[OK] IP 转发已开启"
    pause
}

set_dns() {
    echo "[+] 设置 DNS"

    read -r -p "DNS (默认 223.5.5.5): " DNS
    DNS=${DNS:-223.5.5.5}

    echo "nameserver $DNS" > /etc/resolv.conf

    echo "[OK] DNS 已设置为 $DNS"
    pause
}

install_nft() {
    command -v nft >/dev/null || {
        echo "[+] 安装 nftables..."
        apt update && apt install -y nftables
    }
}

# =========================
# 转发规则
# =========================

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

add_forward() {
    echo "[+] 添加端口转发规则"

    while true; do
        echo "----------------------"
        read -r -p "外部端口(回车结束): " PORT
        [ -z "$PORT" ] && break

        read -r -p "目标IP: " DEST_IP
        read -r -p "目标端口: " DEST_PORT

        add_rule "$PORT" "$DEST_IP" "$DEST_PORT"
    done
}

apply_rules() {
    echo "[+] 检查配置..."

    nft -c -f $CONFIG_FILE || rollback

    echo "[+] 应用配置（10秒内可回滚）"

    (sleep 10 && echo "[!] 自动回滚触发" && rollback) &
    RPID=$!

    systemctl enable nftables
    systemctl restart nftables

    read -r -p "输入 yes 确认应用: " CONFIRM

    if [ "$CONFIRM" == "yes" ]; then
        kill $RPID 2>/dev/null || true
        echo "[OK] 配置已应用"
    else
        rollback
    fi

    pause
}

view_rules() {
    nft list ruleset
    pause
}

clear_rules() {
    echo "[!] 即将清空所有 nft 规则"
    read -r -p "确认输入 yes: " CONFIRM

    if [ "$CONFIRM" == "yes" ]; then
        echo "flush ruleset" > $CONFIG_FILE
        systemctl restart nftables
        echo "[OK] 已清空"
    fi

    pause
}

# =========================
# 初始化
# =========================

init() {
    install_nft
    enable_forward
    backup
}

# =========================
# 菜单
# =========================

menu() {
    echo
    echo "=============================="
    echo " NAT 控制面板（增强版）"
    echo " 网卡: $WAN_IF"
    echo "=============================="
    echo "1. 添加端口转发"
    echo "2. 查看规则"
    echo "3. 清空规则"
    echo "4. 设置 DNS"
    echo "5. 开启 IP 转发"
    echo "6. 查看系统状态"
    echo "0. 退出"
    echo "=============================="
}

# =========================
# 主流程
# =========================

init

while true; do
    menu
    read -r -p "请选择: " CHOICE

    case $CHOICE in
        1)
            RULES=()
            add_forward
            write_config
            apply_rules
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
        6)
            show_status
            ;;
        0)
            exit
            ;;
        *)
            echo "无效选项"
            ;;
    esac
done
