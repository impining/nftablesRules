#!/bin/bash

set -e

CONFIG_FILE="/etc/nftables.conf"
BACKUP_FILE="/etc/nftables.conf.bak"

WAN_IF=$(ip route get 1 2>/dev/null | awk '{print $5; exit}')

RULES_V4=()
RULES_V6=()

SNAT_MODE="masquerade"
SNAT_IP=""

# =========================
# 工具函数
# =========================

is_ipv6() {
    [[ "$1" == *:* ]]
}

get_public_ip() {
    curl -s ifconfig.me || echo "unknown"
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

        if is_ipv6 "$DEST_IP"; then
            TABLE="ip6"
            DEST_FMT="[${DEST_IP}]"
        else
            TABLE="ip"
            DEST_FMT="$DEST_IP"
        fi

        add_rule() {
            local proto=$1
            local rule="$proto dport $IN_PORT dnat to $DEST_FMT:$DEST_PORT"
            if [ "$TABLE" == "ip" ]; then
                RULES_V4+=("iifname \"$WAN_IF\" $rule")
            else
                RULES_V6+=("iifname \"$WAN_IF\" $rule")
            fi
        }

        case $PROTO in
            tcp) add_rule "tcp" ;;
            udp) add_rule "udp" ;;
            both)
                add_rule "tcp"
                add_rule "udp"
                ;;
        esac
    done
}

# =========================
# SNAT
# =========================

set_snat() {
    echo "SNAT 模式:"
    echo "1. masquerade"
    echo "2. 指定 IP"
    read -r -p "选择: " CHOICE

    if [ "$CHOICE" == "2" ]; then
        read -r -p "出口 IP: " SNAT_IP
        SNAT_MODE="snat"
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

table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat;
$(for r in "${RULES_V4[@]}"; do echo "        $r"; done)
    }

    chain postrouting {
        type nat hook postrouting priority srcnat;
        $SNAT_RULE
    }
}

table ip6 nat {
    chain prerouting {
        type nat hook prerouting priority dstnat;
$(for r in "${RULES_V6[@]}"; do echo "        $r"; done)
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
# 应用
# =========================

apply_config() {
    echo "[+] 校验配置..."
    nft -c -f $CONFIG_FILE || rollback

    echo "[+] 应用配置（10秒保护）..."

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
# 主流程
# =========================

echo "公网IP: $(get_public_ip)"
echo "网卡: $WAN_IF"

backup_config

add_rules
set_snat
write_config
apply_config
