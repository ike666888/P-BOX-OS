#!/bin/bash

# ================= 配置区域 =================
# 您的备份文件直链
BACKUP_URL="https://github.com/ike666888/P-BOX-LXC/releases/download/v2.7.2/p-box-lxc.tar.zst"
# ===========================================

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

clear
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}    P-Box 旁路网关全自动部署脚本 (v2.7.2)    ${NC}"
echo -e "${YELLOW}    特性：BBR + TUN模式 + 静态IP + 端口8383    ${NC}"
echo -e "${GREEN}=============================================${NC}"

# --- 1. 检查并开启 PVE 宿主机 BBR ---
echo -e "\n${YELLOW}[1/7] 检查 BBR 加速状态...${NC}"
if grep -q "tcp_congestion_control = bbr" /etc/sysctl.conf; then
    echo -e "${GREEN} -> 检测到宿主机已开启 BBR，跳过。${NC}"
else
    echo -e "${YELLOW} -> 宿主机未开启 BBR，正在为您开启...${NC}"
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    echo -e "${GREEN} -> BBR 已成功开启！${NC}"
fi

# --- 2. 智能网络环境检测 ---
HOST_GW=$(ip route | grep default | awk '{print $3}')
SUBNET=$(echo $HOST_GW | cut -d'.' -f1-3)
echo -e "\n${YELLOW}[2/7] 网络环境检测...${NC}"
echo -e " -> 您的主路由 IP 可能是: ${GREEN}${HOST_GW}${NC}"

# --- 3. 交互式配置 ---
echo -e "\n${YELLOW}[3/7] 请输入配置信息 (按回车使用默认值)${NC}"

# 获取容器 ID
while true; do
    read -p " -> 请设置容器 ID [默认 200]: " CT_ID
    CT_ID=${CT_ID:-200}
    if pct status $CT_ID >/dev/null 2>&1; then
        echo -e "${RED}    错误：ID $CT_ID 已存在，请换一个！${NC}"
    else
        break
    fi
done

# 获取静态 IP
echo -e " -> 建议 IP: ${GREEN}${SUBNET}.200${NC} (请确保未被占用)"
read -p " -> 请输入 IP 地址 [默认 ${SUBNET}.200]: " USER_IP
USER_IP=${USER_IP:-"${SUBNET}.200"}
if [[ "$USER_IP" != *"/"* ]]; then USER_IP="${USER_IP}/24"; fi

# 获取网关
read -p " -> 请输入网关 IP [默认 ${HOST_GW}]: " USER_GW
USER_GW=${USER_GW:-$HOST_GW}

# --- 4. 下载备份文件 ---
BACKUP_FILE="/var/lib/vz/dump/p-box-import.tar.zst"
echo -e "\n${YELLOW}[4/7] 正在下载系统镜像...${NC}"
# 强制覆盖旧文件，防止版本混淆
if [ -f "$BACKUP_FILE" ]; then rm -f "$BACKUP_FILE"; fi

wget -O "$BACKUP_FILE" "$BACKUP_URL" --show-progress
if [ $? -ne 0 ]; then
    echo -e "${RED}下载失败！请检查 GitHub 连接或网络。${NC}"
    rm -f "$BACKUP_FILE"
    exit 1
fi

# --- 5. 恢复容器 (关键：重置 MAC 地址) ---
echo -e "\n${YELLOW}[5/7] 正在解压并恢复容器...${NC}"
# --unique 防止 MAC 地址冲突
pct restore $CT_ID "$BACKUP_FILE" --storage local-lvm --unprivileged 1 --force --unique

if [ $? -ne 0 ]; then
    echo -e "${RED} -> 恢复失败，尝试使用 local 存储池...${NC}"
    pct restore $CT_ID "$BACKUP_FILE" --storage local --unprivileged 1 --force --unique
    if [ $? -ne 0 ]; then
        echo -e "${RED} -> 依然失败，请检查 PVE 存储空间。${NC}"
        exit 1
    fi
fi

# --- 6. 配置网络与 TUN 权限 (核心步骤) ---
echo -e "\n${YELLOW}[6/7] 注入硬件权限与网络配置...${NC}"

# 修改为静态 IP
pct set $CT_ID -net0 name=eth0,bridge=vmbr0,ip=$USER_IP,gw=$USER_GW

# 开启嵌套虚拟化
pct set $CT_ID -features nesting=1

# 注入 TUN 设备权限
CONF_FILE="/etc/pve/lxc/$CT_ID.conf"
if ! grep -q "lxc.cgroup2.devices.allow" "$CONF_FILE"; then
cat <<EOF >> "$CONF_FILE"
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF
fi

# 强制锁定 DNS (防止小白环境解析不了)
pct set $CT_ID -nameserver "223.5.5.5 1.1.1.1"

# --- 7. 启动与验证 ---
echo -e "\n${YELLOW}[7/7] 正在启动服务...${NC}"
pct start $CT_ID
sleep 5

# 再次确保 IP 转发开启
pct exec $CT_ID -- bash -c "sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1"

# 检查运行状态
STATUS=$(pct status $CT_ID)
if [[ "$STATUS" == *"running"* ]]; then
    REAL_IP=$(echo $USER_IP | cut -d'/' -f1)
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN} 🎉 部署成功！ ${NC}"
    echo -e " 🚀 BBR 加速：   [已开启]"
    echo -e " 🛡️ TUN 模式：   [已授权]"
    echo -e " 🌍 管理面板：   ${YELLOW}http://${REAL_IP}:8383${NC}"
    echo -e " ⚠️ 注意：面板端口已更改为 8383，无需 /ui/ 后缀"
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${YELLOW}下一步：请登录面板配置订阅信息。${NC}"
else
    echo -e "${RED}警告：容器似乎未能启动，请检查日志。${NC}"
fi
