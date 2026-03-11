#!/bin/bash
# -*- coding: utf-8 -*-
# 座舱自动化测试实验室 - Docker + Docker Compose 安装脚本
# 支持：Ubuntu 20.04 (focal) / 22.04 (jammy)
# 特性：多镜像源自动重试，WSL2 兼容
# 用法：sudo bash install_docker.sh

set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ─────────────────────────────────────────────
# 0. 检查系统版本
# ─────────────────────────────────────────────
UBUNTU_CODENAME=$(lsb_release -cs)
ARCH=$(dpkg --print-architecture)
info "系统：Ubuntu $(lsb_release -rs) (${UBUNTU_CODENAME}) | 架构：${ARCH}"

# ─────────────────────────────────────────────
# 1. 卸载旧版本
# ─────────────────────────────────────────────
info "清理旧版 Docker"
apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

# ─────────────────────────────────────────────
# 2. 安装基础依赖
# ─────────────────────────────────────────────
info "安装依赖包"
apt-get update -y
apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    apt-transport-https

# ─────────────────────────────────────────────
# 3. 添加 Docker GPG Key 和 apt 源
#    按优先级尝试多个国内镜像源
# ─────────────────────────────────────────────
MIRRORS=(
    "https://mirrors.aliyun.com/docker-ce"
    "https://mirrors.163.com/docker-ce"
    "https://mirrors.ustc.edu.cn/docker-ce"
    "https://download.docker.com"
)

install -m 0755 -d /etc/apt/keyrings

MIRROR_OK=""
for MIRROR in "${MIRRORS[@]}"; do
    info "尝试镜像源：${MIRROR}"
    if curl -fsSL --connect-timeout 10 "${MIRROR}/linux/ubuntu/gpg" \
        | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg 2>/dev/null; then
        MIRROR_OK="${MIRROR}"
        info "✅ 镜像源可用：${MIRROR}"
        break
    else
        warn "⚠️  镜像源不可用：${MIRROR}，尝试下一个..."
    fi
done

if [ -z "$MIRROR_OK" ]; then
    error "所有镜像源均不可用，请检查网络或代理设置"
fi

chmod a+r /etc/apt/keyrings/docker.gpg

# 写入 apt 源
echo \
  "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] \
${MIRROR_OK}/linux/ubuntu \
${UBUNTU_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

info "apt 源已写入：${MIRROR_OK}/linux/ubuntu ${UBUNTU_CODENAME} stable"

apt-get update -y

# ─────────────────────────────────────────────
# 4. 安装 Docker CE
#    --fix-missing：某个包下载失败时跳过，而不是整体失败
#    不安装 docker-ce-rootless-extras（非必需，常超时）
# ─────────────────────────────────────────────
info "安装 Docker CE"
apt-get install -y --fix-missing \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

# ─────────────────────────────────────────────
# 5. 配置 Docker Daemon
# ─────────────────────────────────────────────
info "配置 Docker daemon.json"

# 代理配置（如无代理可删除 httpProxy/httpsProxy 两行）
PROXY_HOST="192.168.1.1"   # ← 改成你的代理，或删除此段
PROXY_PORT="7890"
NO_PROXY_DOCKER="localhost,127.0.0.1,10.0.0.0/8,192.168.0.0/16,.lab.internal"

mkdir -p /etc/docker

# WSL2 检测：WSL2 不支持 systemd cgroup，需要特殊配置
IS_WSL=false
if grep -qi "microsoft" /proc/version 2>/dev/null; then
    IS_WSL=true
    warn "检测到 WSL2 环境，将使用兼容配置"
fi

if [ "$IS_WSL" = true ]; then
    # WSL2 配置（去掉 live-restore，WSL 不支持）
    cat > /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": [
    "https://hub-mirror.c.163.com",
    "https://mirror.baidubce.com",
    "https://reg-mirror.qiniu.com",
    "https://docker.mirrors.ustc.edu.cn"
  ],
  "insecure-registries": [
    "registry.lab.internal"
  ],
  "data-root": "/data/docker",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "5"
  }
}
EOF
else
    # 普通 Linux 配置
    cat > /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": [
    "https://hub-mirror.c.163.com",
    "https://mirror.baidubce.com",
    "https://reg-mirror.qiniu.com",
    "https://docker.mirrors.ustc.edu.cn"
  ],
  "insecure-registries": [
    "registry.lab.internal"
  ],
  "data-root": "/data/docker",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "5"
  },
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 1000000,
      "Soft": 1000000
    }
  },
  "live-restore": true,
  "features": {
    "buildkit": true
  }
}
EOF

    # 代理配置（WSL2 跳过，WSL2 直接继承 Windows 代理）
    mkdir -p /etc/systemd/system/docker.service.d
    cat > /etc/systemd/system/docker.service.d/http-proxy.conf <<EOF
[Service]
Environment="HTTP_PROXY=http://${PROXY_HOST}:${PROXY_PORT}"
Environment="HTTPS_PROXY=http://${PROXY_HOST}:${PROXY_PORT}"
Environment="NO_PROXY=${NO_PROXY_DOCKER}"
EOF
fi

# ─────────────────────────────────────────────
# 6. 确保 /data/docker 目录存在
# ─────────────────────────────────────────────
mkdir -p /data/docker

# ─────────────────────────────────────────────
# 7. 启动 Docker
# ─────────────────────────────────────────────
info "启动 Docker"

if [ "$IS_WSL" = true ]; then
    # WSL2 不一定有 systemd，直接启动 dockerd
    if command -v systemctl &>/dev/null && systemctl is-system-running &>/dev/null; then
        systemctl daemon-reload
        systemctl enable docker
        systemctl restart docker
        info "✅ 使用 systemctl 启动 Docker"
    else
        # 无 systemd，后台直接启动
        pkill dockerd 2>/dev/null || true
        nohup dockerd > /var/log/dockerd.log 2>&1 &
        sleep 3
        info "✅ 使用 nohup 启动 dockerd（WSL2 无 systemd 模式）"
        warn "提示：每次重启 WSL 后需重新执行：sudo nohup dockerd > /var/log/dockerd.log 2>&1 &"
    fi
else
    systemctl daemon-reload
    systemctl enable docker
    systemctl restart docker
fi

# ─────────────────────────────────────────────
# 8. 添加用户到 docker 组
# ─────────────────────────────────────────────
# 将当前 sudo 用户加入 docker 组
SUDO_USER_NAME="${SUDO_USER:-labadmin}"
if id "$SUDO_USER_NAME" &>/dev/null; then
    usermod -aG docker "$SUDO_USER_NAME"
    info "已将 ${SUDO_USER_NAME} 加入 docker 组"
fi

# ─────────────────────────────────────────────
# 9. 验证
# ─────────────────────────────────────────────
sleep 2
info "验证 Docker 版本"
docker --version
docker compose version

info "测试 Docker 拉取镜像"
docker run --rm hello-world && info "✅ Docker 安装成功！" || warn "⚠️  hello-world 运行失败，请检查 Docker 是否正在运行"

info "============================================"
info " Docker 安装完成"
info " 重新登录用户后可不加 sudo 直接使用 docker"
info "============================================"
