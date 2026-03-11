#!/bin/bash
# -*- coding: utf-8 -*-
# 座舱自动化测试实验室 - Ubuntu 22.04 LTS 初始化脚本
# 功能：系统基础配置 / 代理设置 / 常用工具安装
# 用法：sudo bash init_ubuntu.sh
# 注意：将下方 PROXY_HOST / PROXY_PORT 替换为你自己的代理地址

set -e

# ─────────────────────────────────────────────
# 0. 颜色输出
# ─────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ─────────────────────────────────────────────
# 1. 代理配置（如果实验室无需代理，注释掉此段）
# ─────────────────────────────────────────────
# PROXY_HOST="192.168.1.1"    # ← 改成你的代理服务器 IP
# PROXY_PORT="7890"            # ← 改成你的代理端口

# HTTP_PROXY="http://${PROXY_HOST}:${PROXY_PORT}"
# HTTPS_PROXY="http://${PROXY_HOST}:${PROXY_PORT}"
# NO_PROXY="localhost,127.0.0.1,::1,10.0.0.0/8,192.168.0.0/16,.lab.internal"

# info "配置系统代理 → ${HTTP_PROXY}"

# 写入 /etc/environment（系统全局，重启后生效）
cat > /etc/environment <<EOF
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
http_proxy="${HTTP_PROXY}"
https_proxy="${HTTPS_PROXY}"
HTTP_PROXY="${HTTP_PROXY}"
HTTPS_PROXY="${HTTPS_PROXY}"
no_proxy="${NO_PROXY}"
NO_PROXY="${NO_PROXY}"
EOF

# 写入 /etc/apt/apt.conf.d/95proxy（apt 专用代理）
cat > /etc/apt/apt.conf.d/95proxy <<EOF
Acquire::http::Proxy "${HTTP_PROXY}";
Acquire::https::Proxy "${HTTPS_PROXY}";
EOF

# 写入 /etc/profile.d/proxy.sh（当前 session 立即生效）
cat > /etc/profile.d/proxy.sh <<EOF
export http_proxy="${HTTP_PROXY}"
export https_proxy="${HTTPS_PROXY}"
export HTTP_PROXY="${HTTP_PROXY}"
export HTTPS_PROXY="${HTTPS_PROXY}"
export no_proxy="${NO_PROXY}"
export NO_PROXY="${NO_PROXY}"
EOF

# 当前 shell 立即生效
export http_proxy="${HTTP_PROXY}"
export https_proxy="${HTTPS_PROXY}"
export HTTP_PROXY="${HTTP_PROXY}"
export HTTPS_PROXY="${HTTPS_PROXY}"
export no_proxy="${NO_PROXY}"
export NO_PROXY="${NO_PROXY}"

# ─────────────────────────────────────────────
# 2. 时区 / 主机名 / 语言
# ─────────────────────────────────────────────
info "设置时区为 Asia/Shanghai"
timedatectl set-timezone Asia/Shanghai

info "设置主机名"
HOSTNAME="lab-server"      # ← 按需修改
hostnamectl set-hostname "${HOSTNAME}"
echo "127.0.1.1 ${HOSTNAME}" >> /etc/hosts

# ─────────────────────────────────────────────
# 3. apt 更换国内镜像（加速下载，可与代理二选一）
# ─────────────────────────────────────────────
info "更换 apt 为阿里云镜像源"
cp /etc/apt/sources.list /etc/apt/sources.list.bak
cat > /etc/apt/sources.list <<'EOF'
deb http://mirrors.aliyun.com/ubuntu/ jammy main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ jammy-updates main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ jammy-backports main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ jammy-security main restricted universe multiverse
EOF

apt-get update -y

# ─────────────────────────────────────────────
# 4. 安装常用工具
# ─────────────────────────────────────────────
info "安装基础工具"
apt-get install -y \
    curl wget git vim htop unzip tar \
    ca-certificates gnupg lsb-release \
    net-tools iputils-ping dnsutils \
    build-essential python3-pip \
    nfs-common samba-client \
    jq tree tmux screen \
    openssh-server fail2ban \
    ufw

# ─────────────────────────────────────────────
# 5. 系统内核参数优化（ElasticSearch / Redis 要求）
# ─────────────────────────────────────────────
info "优化内核参数"
cat >> /etc/sysctl.conf <<'EOF'

# ElasticSearch 要求
vm.max_map_count=262144
# Redis 建议
vm.overcommit_memory=1
net.core.somaxconn=65535
# 文件描述符
fs.file-max=1000000
EOF
sysctl -p

# 调整 ulimit
cat >> /etc/security/limits.conf <<'EOF'
* soft nofile 1000000
* hard nofile 1000000
* soft nproc  65536
* hard nproc  65536
EOF

# ─────────────────────────────────────────────
# 6. 禁用 swap（ElasticSearch / K8s 要求）
# ─────────────────────────────────────────────
info "禁用 swap"
swapoff -a
sed -i '/swap/d' /etc/fstab

# ─────────────────────────────────────────────
# 7. 防火墙基础规则
# # ─────────────────────────────────────────────
# info "配置 UFW 防火墙"
# ufw default deny incoming
# ufw default allow outgoing
# ufw allow ssh
# ufw allow 80/tcp
# ufw allow 443/tcp
# ufw allow from 192.168.0.0/16    # 内网全通
# echo "y" | ufw enable

# ─────────────────────────────────────────────
# 8. 创建部署用户（不用 root 跑服务）
# ─────────────────────────────────────────────
info "创建部署用户 labadmin"
if ! id "labadmin" &>/dev/null; then
    useradd -m -s /bin/bash labadmin
    usermod -aG sudo labadmin
    echo "labadmin:Lab@2025!"   | chpasswd    # ← 修改成你自己的密码
fi

# ─────────────────────────────────────────────
# 9. 创建实验室目录结构
# ─────────────────────────────────────────────
info "创建目录结构"
mkdir -p /data/{mysql,redis,mongodb,elasticsearch,minio,gitlab,jenkins,harbor,grafana,prometheus,rabbitmq,influxdb,milvus,ollama,allure,metersphere}
mkdir -p /data/nginx/{conf,html,ssl,logs}
mkdir -p /opt/lab-deploy
chown -R labadmin:labadmin /data /opt/lab-deploy

info "✅ Ubuntu 初始化完成，建议重启后继续安装 Docker"
info "执行：reboot"
