#!/bin/bash
# ============================================================
# 修复 Docker daemon.json - 使用 2025 年国内仍可用的镜像加速
# 更新：2025-03
# 用法：sudo bash fix_docker_mirrors.sh
# ============================================================

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

echo -e "${CYAN}── 配置 Docker 镜像加速源 ──${NC}"

mkdir -p /etc/docker

cat > /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": [
    "https://dockerpull.cn",
    "https://docker.1panel.live",
    "https://docker.unsee.tech",
    "https://docker.hpcloud.cloud"
  ],
  "insecure-registries": ["registry.lab.internal"],
  "data-root": "/data/docker",
  "log-driver": "json-file",
  "log-opts": {"max-size": "100m", "max-file": "5"}
}
EOF

echo -e "${GREEN}✓ daemon.json 已更新${NC}"
cat /etc/docker/daemon.json

# ── 重启 Docker ──────────────────────────────────────────────
if command -v systemctl &>/dev/null && systemctl is-active docker &>/dev/null; then
    # 标准 systemd 环境（物理机 / VM / 普通 WSL2）
    echo -e "\n${CYAN}── 重启 Docker (systemctl) ──${NC}"
    sudo systemctl daemon-reload
    sudo systemctl restart docker
elif pgrep dockerd &>/dev/null; then
    # WSL2 无 systemd 环境：手动重启 dockerd
    echo -e "\n${CYAN}── 重启 Docker (WSL2 手动模式) ──${NC}"
    sudo pkill dockerd 2>/dev/null || true
    sleep 2
    sudo nohup dockerd > /var/log/dockerd.log 2>&1 &
    sleep 5
else
    echo -e "${YELLOW}! Docker 未运行，请手动启动后验证${NC}"
fi

# ── 验证 ─────────────────────────────────────────────────────
echo -e "\n${CYAN}── 验证配置 ──${NC}"
docker info 2>/dev/null | grep -A 10 "Registry Mirrors" || \
    echo -e "${RED}✗ Docker 未响应，请检查是否启动成功${NC}"

# ── 测试拉取 ─────────────────────────────────────────────────
echo -e "\n${CYAN}── 测试拉取 hello-world ──${NC}"
if docker pull hello-world > /tmp/dp_test.txt 2>&1; then
    echo -e "${GREEN}✓ 镜像拉取正常，加速源生效！${NC}"
    docker rmi hello-world > /dev/null 2>&1 || true
else
    echo -e "${YELLOW}! 加速源拉取失败，建议改用 pull_all_images.sh 中的直拉方案${NC}"
    echo "  该脚本不依赖 daemon 镜像源，直接通过中转地址拉取后重新打 tag"
    cat /tmp/dp_test.txt | tail -3
fi

echo -e "\n${GREEN}完成！如加速源仍不稳定，请直接使用：${NC}"
echo "  sudo bash pull_all_images.sh"
