#!/bin/bash

# ================= 配置区域 =================
# 备份文件下载直链
BACKUP_URL="https://github.com/ike666888/P-BOX-LXC/releases/download/v2.7.2/p-box-lxc.tar.zst"
# 备份文件本地路径
BACKUP_FILE="/var/lib/vz/dump/p-box-import.tar.zst"
# ===========================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

clear
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}    P-Box 智能部署脚本 (v3.0)                ${NC}"
echo -e "${GREEN}=============================================${NC}"

# =================================================================
# 检测环境 (PVE vs 非PVE)
# =================================================================
if ! command -v pveversion >/dev/null 2>&1; then
    echo -e "${YELLOW}检测环境: 非 Proxmox VE (PVE) 环境${NC}"
    echo -e "${GREEN}请选择操作：${NC}"
    echo -e "1. 安装 P-BOX (官方脚本 + 常用工具)"
    echo -e "2. 退出脚本"
    read -p "请输入数字 [1-2]: " CHOICE

    case $CHOICE in
        1)
            echo -e "\n${YELLOW}正在准备安装环境...${NC}"
            # 安装基础依赖防止报错
            if [ -f /etc/debian_version ]; then
                apt-get update && apt-get install -y curl sudo
            elif [ -f /etc/redhat-release ]; then
                yum install -y curl sudo
            fi
            echo -e "${YELLOW}开始执行官方安装...${NC}"
            curl -fsSL https://raw.githubusercontent.com/p-box2025/P-BOX/main/install.sh | sudo bash
            ;;
        2)
            echo -e "${GREEN}已退出。${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效输入，退出。${NC}"
            exit 1
            ;;
    esac
    
    # 非PVE环境安装完后清理脚本自身 
    rm -f "$0"
    exit 0
fi

# =================================================================
# PVE 环境的部署逻辑
# =================================================================
echo -e "${GREEN}检测环境: Proxmox VE 宿主机${NC}"

# --- 检测并开启 TUN ---
if [ ! -c /dev/net/tun ]; then
    echo -e "${YELLOW}正在加载 TUN 模块...${NC}"
    modprobe tun
fi
if [ ! -c /dev/net/tun ]; then
    echo -e "${RED}错误：无法加载 TUN 模块，请检查 PVE 内核。${NC}"
    rm -f "$0" # 失败也清理脚本
    exit 1
else
    echo -e "${GREEN} -> TUN 模式已就绪${NC}"
fi

# --- 检测并开启 BBR (智能跳过) ---
CURRENT_ALGO=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
if [[ "$CURRENT_ALGO" == "bbr" ]]; then
    echo -e "${GREEN} -> BBR 已开启 (跳过配置)${NC}"
else
    echo -e "${YELLOW} -> BBR 未开启，正在配置...${NC}"
    if ! grep -q "tcp_congestion_control = bbr" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    sysctl -p >/dev/null 2>&1
    echo -e "${GREEN} -> BBR 已成功开启${NC}"
fi

# --- 网络环境检测 ---
HOST_GW=$(ip route | grep default | awk '{print $3}')
SUBNET=$(echo $HOST_GW | cut -d'.' -f1-3)
echo -e "\n${YELLOW}网络环境检测：${NC} 主路由 IP：${GREEN}${HOST_GW}${NC}"

# --- 用户交互配置 ---
while true; do
    read -p "请输入容器 ID [默认 200]: " CT_ID
    CT_ID=${CT_ID:-200}
    if pct status $CT_ID >/dev/null 2>&1; then
        echo -e "${RED}错误：ID $CT_ID 已存在，请换一个。${NC}"
    else
        break
    fi
done

read -p "请输入静态 IP [默认 ${SUBNET}.200]: " USER_IP
USER_IP=${USER_IP:-"${SUBNET}.200"}
if [[ "$USER_IP" != *"/"* ]]; then USER_IP="${USER_IP}/24"; fi

read -p "请输入网关 IP [默认 ${HOST_GW}]: " USER_GW
USER_GW=${USER_GW:-$HOST_GW}

# --- 下载检测 (存在则跳过) ---
echo -e "\n${YELLOW}[Step 1/3] 准备镜像文件...${NC}"
if [ -f "$BACKUP_FILE" ]; then
    echo -e "${GREEN} -> 检测到本地已有备份文件，跳过下载。${NC}"
else
    echo -e "${YELLOW} -> 正在下载系统镜像...${NC}"
    wget -O "$BACKUP_FILE" "$BACKUP_URL" -q --show-progress
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败，请检查网络。${NC}"
        rm -f "$BACKUP_FILE"
        rm -f "$0"
        exit 1
    fi
fi

# --- 恢复容器 ---
echo -e "\n${YELLOW}[Step 2/3] 解压并恢复容器...${NC}"
pct restore $CT_ID "$BACKUP_FILE" --storage local-lvm --unprivileged 1 --force --unique >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${YELLOW} -> 尝试使用 local 存储...${NC}"
    pct restore $CT_ID "$BACKUP_FILE" --storage local --unprivileged 1 --force --unique
    if [ $? -ne 0 ]; then
        echo -e "${RED}恢复失败，请检查 PVE 存储空间。${NC}"
        # 即使失败，是否删除文件取决于策略，这里保留文件以便排查，但清理脚本
        rm -f "$0"
        exit 1
    fi
fi

# --- 部署完成后清理备份文件 ---
echo -e "${GREEN} -> 清理临时备份文件...${NC}"
rm -f "$BACKUP_FILE"

# --- 系统配置 ---
echo -e "\n${YELLOW}[Step 3/3] 配置网络与权限...${NC}"
pct set $CT_ID -net0 name=eth0,bridge=vmbr0,ip=$USER_IP,gw=$USER_GW
pct set $CT_ID -features nesting=1
pct set $CT_ID -nameserver "223.5.5.5 1.1.1.1"

CONF_FILE="/etc/pve/lxc/$CT_ID.conf"
if ! grep -q "lxc.cgroup2.devices.allow" "$CONF_FILE"; then
cat <<EOF >> "$CONF_FILE"
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF
fi

# --- 启动 ---
echo -e "${YELLOW}正在启动容器...${NC}"
pct start $CT_ID
sleep 5
pct exec $CT_ID -- bash -c "sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1"

# --- 最终展示 ---
REAL_IP=$(echo $USER_IP | cut -d'/' -f1)
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN} 🎉 部署成功！ ${NC}"
echo -e " 管理面板:    ${YELLOW}http://${REAL_IP}:8383${NC}"
echo -e " Root 密码:   ${YELLOW}aa123123${NC}"
echo -e "${GREEN}=============================================${NC}"

# --- 部署完成后清理脚本自身 ---
rm -f "$0"
