#!/bin/bash
# -*- coding: utf-8 -*-
# 座舱自动化测试实验室 - 一键部署脚本
# 用法：sudo bash deploy.sh [core|llm|all|down|status]

set -e
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEPLOY_DIR"

# 确保 data 目录存在
DATA_ROOT=$(grep DATA_ROOT .env | cut -d= -f2 | tr -d ' ')
DATA_ROOT=${DATA_ROOT:-/data}
info "数据目录：${DATA_ROOT}"
for d in mysql redis mongodb elasticsearch minio gitlab jenkins harbor \
          grafana prometheus rabbitmq influxdb milvus ollama allure nginx; do
    mkdir -p "${DATA_ROOT}/${d}"
done
mkdir -p "${DATA_ROOT}/nginx/{conf,html,ssl,logs}"

CMD="${1:-core}"

case "$CMD" in

  core)
    info "启动核心服务..."
    docker compose --env-file .env up -d
    info "✅ 核心服务已启动"
    docker compose --env-file .env ps
    ;;

  llm)
    info "启动大模型服务..."
    # 先确保 lab-net 网络存在
    docker network inspect testlab_lab-net >/dev/null 2>&1 \
      || docker network create testlab_lab-net

    docker compose \
      -f docker-compose.yml \
      -f docker-compose.llm.yml \
      --env-file .env \
      up -d ollama open-webui litellm milvus-etcd milvus attu

    info "拉取常用大模型（首次需要一段时间）..."
    docker exec lab-ollama ollama pull deepseek-coder:6.7b || warn "拉取 deepseek-coder 失败"
    docker exec lab-ollama ollama pull qwen2.5:7b          || warn "拉取 qwen2.5:7b 失败"
    docker exec lab-ollama ollama pull nomic-embed-text    || warn "拉取 embedding 模型失败"

    info "✅ 大模型服务已启动"
    ;;

  all)
    info "启动所有服务（核心 + 大模型）..."
    bash "$0" core
    bash "$0" llm
    ;;

  down)
    warn "停止所有服务..."
    docker compose \
      -f docker-compose.yml \
      -f docker-compose.llm.yml \
      --env-file .env \
      down
    info "✅ 所有服务已停止"
    ;;

  status)
    docker compose \
      -f docker-compose.yml \
      -f docker-compose.llm.yml \
      --env-file .env \
      ps
    ;;

  logs)
    SVC="${2:-}"
    docker compose \
      -f docker-compose.yml \
      -f docker-compose.llm.yml \
      --env-file .env \
      logs -f --tail=100 ${SVC}
    ;;

  *)
    echo "用法：bash deploy.sh [core|llm|all|down|status|logs <服务名>]"
    exit 1
    ;;
esac
