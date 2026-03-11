#!/bin/bash
# -*- coding: utf-8 -*-
# ============================================================
# 无代理环境下批量拉取实验室镜像（中国大陆可用，无需登录）
# 更新：2025-03 - 增加多备用源、LLM镜像支持、ACR模式
#
# 用法：
#   sudo bash pull_all_images.sh            # 中转站模式，拉取全部
#   sudo bash pull_all_images.sh core       # 中转站模式，仅核心镜像
#   sudo bash pull_all_images.sh llm        # 中转站模式，仅LLM镜像
#   sudo bash pull_all_images.sh acr        # ACR模式，从阿里云ACR拉取全部
#   sudo bash pull_all_images.sh acr core   # ACR模式，仅核心镜像
#   sudo bash pull_all_images.sh acr llm    # ACR模式，仅LLM镜像
#
# ACR模式前置条件：
#   需先设置环境变量或修改下方 ACR_* 变量：
#   export ACR_REGISTRY=registry.cn-hangzhou.aliyuncs.com
#   export ACR_NAMESPACE=你的命名空间
#   export ACR_USERNAME=你的阿里云账号
#   export ACR_PASSWORD=你的ACR密码
# ============================================================

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "  ${GREEN}✓${NC} $*"; }
warn()    { echo -e "  ${YELLOW}!${NC} $*"; }
fail()    { echo -e "  ${RED}✗${NC} $*"; }
section() { echo -e "\n${CYAN}${BOLD}── $* ──${NC}"; }

FAILED_IMAGES=()

# 解析参数：支持 acr core / acr llm / acr / core / llm / all
if [ "$1" = "acr" ]; then
    USE_ACR=true
    MODE="${2:-all}"
else
    USE_ACR=false
    MODE="${1:-all}"
fi

# ── ACR 配置（ACR模式时使用）────────────────────────────────
# 优先读取环境变量，未设置则使用下方默认值（请修改为你的实际信息）
ACR_REGISTRY="${ACR_REGISTRY:-registry.cn-hangzhou.aliyuncs.com}"
ACR_NAMESPACE="${ACR_NAMESPACE:-}"
ACR_USERNAME="${ACR_USERNAME:-}"
ACR_PASSWORD="${ACR_PASSWORD:-}"

# ── 国内可用镜像中转前缀（2025年3月可用清单）─────────────────
# 按可靠性排序，脚本会依次尝试，成功则停止
# 格式说明：
#   dockerpull.cn/<org>/<image>:<tag>  （直接替换 docker.io）
#   docker.1panel.live/<org>/<image>:<tag>
#   swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/<org>/<image>:<tag>

# 中转站列表（按优先级）
MIRRORS=(
    "dockerpull.cn"
    "docker.1panel.live"
    "docker.unsee.tech"
    "docker.hpcloud.cloud"
    "9wggzefxo5c8xeipi3.xuanyuan.run"
)
# 华为云 DDN（路径前缀不同，单独处理）
HUAWEI="swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io"

# ── 核心拉取函数 ─────────────────────────────────────────────

# ACR 模式：从阿里云 ACR 拉取并 tag 回原始镜像名
pull_image_acr() {
    local target="$1"  # 原始镜像名，如 mysql:8.0

    echo -e "\n▶ ${BOLD}${target}${NC}"

    if docker image inspect "$target" > /dev/null 2>&1; then
        info "本地已存在，跳过"
        return 0
    fi

    # 还原 ACR 路径规则（与 workflow 中 sync_image 函数保持一致）
    # mysql:8.0          -> ACR_NAMESPACE/mysql:8.0
    # minio/minio:latest -> ACR_NAMESPACE/minio:minio-latest
    # prom/prometheus    -> ACR_NAMESPACE/prometheus:prom-latest
    local name_part="${target%%:*}"
    local tag_part="${target##*:}"

    if [[ "$name_part" == */* ]]; then
        local org="${name_part%%/*}"
        local repo="${name_part##*/}"
        local acr_repo="${repo}"
        local acr_tag="${org}-${tag_part}"
    else
        local acr_repo="${name_part}"
        local acr_tag="${tag_part}"
    fi
    local acr_src="${ACR_REGISTRY}/${ACR_NAMESPACE}/${acr_repo}:${acr_tag}"

    echo -e "  从 ACR 拉取：${BOLD}${acr_src}${NC} ..."
    if docker pull "$acr_src" 2>/tmp/dp_err.txt; then
        docker tag "$acr_src" "$target"
        docker rmi "$acr_src" > /dev/null 2>&1 || true
        info "已就绪：$target"
        return 0
    else
        fail "ACR 拉取失败：$acr_src"
        grep -iE 'error|timeout|denied|not found|unauthorized' /tmp/dp_err.txt | tail -2 | sed 's/^/    /'
        FAILED_IMAGES+=("$target")
        return 1
    fi
}

# 统一入口：根据 USE_ACR 决定走哪条路径
pull_image() {
    local target="$1"
    # ACR 模式直接走 ACR 拉取
    if [ "$USE_ACR" = "true" ]; then
        pull_image_acr "$target"
        return $?
    fi

    local -a extra_sources=()
    # 收集调用者追加的额外源（可选）
    if [ $# -gt 1 ]; then
        shift
        extra_sources=("$@")
    fi

    echo -e "\n▶ ${BOLD}${target}${NC}"

    # 已存在则跳过
    if docker image inspect "$target" > /dev/null 2>&1; then
        info "本地已存在，跳过"
        return 0
    fi

    # 构建所有候选源
    local -a all_sources=()

    # 1. 先放调用者指定的额外源（最高优先级）
    for s in "${extra_sources[@]}"; do
        all_sources+=("$s")
    done

    # 2. 各通用中转站
    for mirror in "${MIRRORS[@]}"; do
        all_sources+=("${mirror}/${target}")
    done

    # 3. 华为云 DDN
    all_sources+=("${HUAWEI}/${target}")

    # 4. 最后尝试原始地址（有代理或运气好时可用）
    all_sources+=("${target}")

    for src in "${all_sources[@]}"; do
        echo -e "  尝试 ${BOLD}${src}${NC} ..."
        # 直接拉取并显示实时进度；失败时捕获错误信息
        if docker pull "$src" 2>/tmp/dp_err.txt; then
            if [ "$src" != "$target" ]; then
                docker tag "$src" "$target"
                docker rmi "$src" > /dev/null 2>&1 || true
            fi
            info "已就绪：$target"
            return 0
        else
            echo -e "  ${RED}✗ 失败，尝试下一个源...${NC}"
            grep -iE 'error|timeout|denied|not found|unknown' /tmp/dp_err.txt | tail -1 | sed 's/^/    /' || true
        fi
    done

    fail "所有来源均失败：$target"
    FAILED_IMAGES+=("$target")
    return 1
}

# ── 特殊：非 docker.io 镜像的拉取函数 ────────────────────────
# 用于 gcr.io / ghcr.io / quay.io 等已被墙的 registry
# 华为云 DDN 支持多个 registry 的中转
pull_image_other() {
    local target="$1"     # 完整原始镜像名，如 ghcr.io/open-webui/open-webui:main
    local dockerhub_alt="$2"  # Docker Hub 上的替代镜像（可选）

    echo -e "\n▶ ${BOLD}${target}${NC}"

    if docker image inspect "$target" > /dev/null 2>&1; then
        info "本地已存在，跳过"
        return 0
    fi

    local -a sources=()

    # 如果有 Docker Hub 替代镜像，先从各中转站拉取替代镜像
    if [ -n "$dockerhub_alt" ]; then
        for mirror in "${MIRRORS[@]}"; do
            sources+=("${mirror}/${dockerhub_alt}")
        done
        sources+=("${HUAWEI}/${dockerhub_alt}")
        sources+=("${dockerhub_alt}")  # 原始 Docker Hub
    fi

    # 华为云 DDN 对 gcr.io/ghcr.io/quay.io 的中转格式：
    # swr.cn-north-4.myhuaweicloud.com/ddn-k8s/<registry>/<path>:<tag>
    # 例：ghcr.io/open-webui/open-webui:main
    #  -> swr.../ddn-k8s/ghcr.io/open-webui/open-webui:main
    local huawei_base="swr.cn-north-4.myhuaweicloud.com/ddn-k8s"
    sources+=("${huawei_base}/${target}")

    # dockerpull.cn 也支持多 registry 中转
    sources+=("dockerpull.cn/${target}")

    # 最后尝试原始地址
    sources+=("$target")

    local tag_target="$target"
    # 如果有替代镜像，最终 tag 成替代镜像名（compose 文件里用的是替代名）
    # 调用方式：pull_image_other 原始名 替代名  => tag 成替代名
    if [ -n "$dockerhub_alt" ]; then
        tag_target="$dockerhub_alt"
    fi

    for src in "${sources[@]}"; do
        echo -e "  尝试 ${BOLD}${src}${NC} ..."
        # 直接拉取并显示实时进度；失败时捕获错误信息
        if docker pull "$src" 2>/tmp/dp_err.txt; then
            if [ "$src" != "$tag_target" ]; then
                docker tag "$src" "$tag_target"
                docker rmi "$src" > /dev/null 2>&1 || true
            fi
            info "已就绪：$tag_target"
            return 0
        else
            echo -e "  ${RED}✗ 失败，尝试下一个源...${NC}"
            grep -iE 'error|timeout|denied|not found|unknown' /tmp/dp_err.txt | tail -1 | sed 's/^/    /' || true
        fi
    done

    fail "所有来源均失败：$target"
    FAILED_IMAGES+=("$target")
    return 1
}

# ══════════════════════════════════════════════════════════════
# 核心服务镜像（docker-compose.yml）
# ══════════════════════════════════════════════════════════════
pull_core_images() {

    section "数据库层"
    pull_image "mysql:8.0"
    pull_image "redis:7.2-alpine"
    pull_image "mongo:6.0"
    pull_image "influxdb:2.7"

    section "搜索 / 日志"
    pull_image "elasticsearch:8.12.0"
    pull_image "kibana:8.12.0"

    section "对象存储"
    pull_image "minio/minio:latest"

    section "消息队列"
    pull_image "rabbitmq:3.12-management-alpine"

    section "代码管理（体积较大，请耐心等待 ~2GB）"
    pull_image "gitlab/gitlab-ce:16.9.1-ce.0"

    section "CI/CD"
    pull_image "jenkins/jenkins:lts-jdk17"

    section "监控体系"
    pull_image "prom/prometheus:latest"
    pull_image "grafana/grafana:latest"
    pull_image "prom/node-exporter:latest"
    # cadvisor 原地址 gcr.io 被墙，使用 Docker Hub 替代
    pull_image "zcube/cadvisor:latest"

    section "测试报告"
    pull_image "frankescobar/allure-docker-service:latest"
    pull_image "frankescobar/allure-docker-service-ui:latest"

    section "反向代理"
    pull_image "nginx:alpine"
}

# ══════════════════════════════════════════════════════════════
# 大模型服务镜像（docker-compose.llm.yml）
# ══════════════════════════════════════════════════════════════
pull_llm_images() {

    section "Ollama 本地推理"
    pull_image "ollama/ollama:latest"

    section "Open WebUI（原 ghcr.io，已切换 Docker Hub 替代）"
    # 原：ghcr.io/open-webui/open-webui:main（被墙）
    # 已在 compose 文件改为 openwebui/open-webui:main
    pull_image "openwebui/open-webui:main"

    section "LiteLLM 模型网关（原 ghcr.io，已切换 Docker Hub 替代）"
    # 原：ghcr.io/berriai/litellm（被墙）
    # 已在 compose 文件改为 litellm/litellm:latest
    pull_image "litellm/litellm:latest"

    section "Milvus 向量数据库"
    pull_image "milvusdb/milvus:v2.4.0"

    section "Etcd（Milvus 依赖，原 quay.io，已切换 bitnami 替代）"
    # 原：quay.io/coreos/etcd（不稳定）
    # 已在 compose 文件改为 bitnami/etcd:3.5
    pull_image "bitnami/etcd:3.5"

    section "Milvus 管理界面 Attu"
    pull_image "zilliz/attu:latest"
}

# ══════════════════════════════════════════════════════════════
# 主流程
# ══════════════════════════════════════════════════════════════

echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   座舱实验室 - Docker 镜像批量拉取工具        ║"
if [ "$USE_ACR" = "true" ]; then
echo "║   模式: $(printf '%-37s' "ACR（阿里云）+ ${MODE}")║"
else
echo "║   模式: $(printf '%-37s' "中转站 + ${MODE}")║"
fi
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

if [ "$USE_ACR" = "true" ]; then
    # ── ACR 模式：先检查配置，再登录 ──────────────────────────
    if [ -z "$ACR_NAMESPACE" ] || [ -z "$ACR_USERNAME" ] || [ -z "$ACR_PASSWORD" ]; then
        echo -e "${RED}错误：ACR 模式需要设置以下环境变量：${NC}"
        echo "  export ACR_REGISTRY=registry.cn-hangzhou.aliyuncs.com"
        echo "  export ACR_NAMESPACE=你的命名空间"
        echo "  export ACR_USERNAME=你的阿里云账号"
        echo "  export ACR_PASSWORD=你的ACR密码"
        echo ""
        echo "或者直接修改脚本顶部的 ACR_* 变量"
        exit 1
    fi
    echo "ACR 地址：${ACR_REGISTRY}/${ACR_NAMESPACE}"
    echo -n "正在登录 ACR ... "
    if echo "$ACR_PASSWORD" | docker login "$ACR_REGISTRY" -u "$ACR_USERNAME" --password-stdin > /dev/null 2>&1; then
        echo -e "${GREEN}登录成功${NC}"
    else
        echo -e "${RED}登录失败，请检查账号密码${NC}"
        exit 1
    fi
else
    # ── 中转站模式：显示源列表 ─────────────────────────────────
    echo "镜像中转源优先级："
    for i in "${!MIRRORS[@]}"; do
        echo "  $((i+1)). ${MIRRORS[$i]}"
    done
    echo "  $((${#MIRRORS[@]}+1)). ${HUAWEI}（华为云DDN）"
fi
echo ""

case "$MODE" in
    core)
        echo -e "${YELLOW}仅拉取核心服务镜像...${NC}"
        pull_core_images
        ;;
    llm)
        echo -e "${YELLOW}仅拉取大模型服务镜像...${NC}"
        pull_llm_images
        ;;
    all|*)
        echo -e "${YELLOW}拉取全部镜像（核心 + LLM）...${NC}"
        pull_core_images
        pull_llm_images
        ;;
esac

# ── 汇总报告 ──────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════${NC}"
if [ ${#FAILED_IMAGES[@]} -eq 0 ]; then
    echo -e "${GREEN}${BOLD}✅ 所有镜像拉取完成！${NC}"
    echo ""
    case "$MODE" in
        core) echo "下一步，启动核心服务：" ;;
        llm)  echo "下一步，启动LLM服务：" ;;
        *)    echo "下一步，启动全部服务：" ;;
    esac
    echo "  cd /opt/lab-deploy && bash deploy.sh ${MODE}"
else
    echo -e "${YELLOW}${BOLD}⚠️  以下镜像拉取失败（${#FAILED_IMAGES[@]} 个）：${NC}"
    for img in "${FAILED_IMAGES[@]}"; do
        echo "   - $img"
    done
    echo ""
    warn "建议处理方式："
    echo "  1. 重新运行此脚本（已成功的镜像会自动跳过）："
    echo "     sudo bash pull_all_images.sh ${MODE}"
    echo ""
    echo "  2. 手动单独拉取失败的镜像（在有网络的机器上 save/load）："
    echo "     docker save <image> | gzip > image.tar.gz"
    echo "     docker load < image.tar.gz"
    echo ""
    echo "  3. 若有代理，临时为 Docker 设置代理后重试："
    echo "     sudo mkdir -p /etc/systemd/system/docker.service.d"
    echo "     echo -e '[Service]\nEnvironment=HTTP_PROXY=http://代理IP:端口' \\"
    echo "       | sudo tee /etc/systemd/system/docker.service.d/proxy.conf"
    echo "     sudo systemctl daemon-reload && sudo systemctl restart docker"
fi
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BOLD}当前已有镜像列表：${NC}"
docker images --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}" \
    | grep -v REPOSITORY | sort
echo ""  