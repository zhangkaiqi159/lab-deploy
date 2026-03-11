# 座舱自动化测试实验室 - 基础设施部署手册

## 目录结构

```
lab-deploy/
├── .env                          # 全局环境变量（密码/端口等）
├── docker-compose.yml            # 核心服务（阶段一/二）
├── docker-compose.llm.yml        # 大模型服务（阶段三）
├── deploy.sh                     # 一键部署脚本
├── init_ubuntu.sh                # Ubuntu 系统初始化
├── install_docker.sh             # Docker 安装配置
├── config/
│   ├── nginx/
│   │   ├── nginx.conf            # Nginx 主配置
│   │   ├── conf.d/lab.conf       # 各服务反向代理
│   │   └── html/index.html       # 导航首页
│   ├── prometheus/
│   │   └── prometheus.yml        # 监控采集配置
│   ├── litellm/
│   │   └── config.yaml           # 大模型路由配置
│   └── mysql/
│       └── my.cnf                # MySQL 优化配置
└── README.md
```

---

## 第一步：系统初始化

> 推荐系统：Ubuntu 22.04 LTS
> 最低配置：16C 32G 内存，500G SSD

```bash
# 1. 修改 init_ubuntu.sh 中的代理地址（如无代理可注释掉代理部分）
vim init_ubuntu.sh

# 2. 执行初始化
sudo bash init_ubuntu.sh

# 3. 重启
sudo reboot
```

---

## 第二步：安装 Docker

```bash
# 修改 install_docker.sh 中的代理地址
vim install_docker.sh

sudo bash install_docker.sh

# 验证
docker --version
docker compose version
```

---

## 第三步：修改配置

```bash
# 复制部署目录到服务器
cp -r lab-deploy /opt/lab-deploy
cd /opt/lab-deploy

# !! 重要：修改 .env 文件，至少修改以下内容：
#   - 所有密码（*_PASSWORD）
#   - SERVER_IP（改成服务器实际 IP）
#   - LAB_DOMAIN（改成你的内网域名，或直接用 IP）
vim .env
```

---

## 第四步：一键启动

### 4.1 启动核心服务（阶段一 + 阶段二）

```bash
bash /opt/lab-deploy/deploy.sh core
```

包含：
- MySQL 8 / Redis 7 / MongoDB 6 / InfluxDB 2
- Elasticsearch 8 / Kibana
- MinIO / RabbitMQ
- GitLab CE / Jenkins
- Prometheus / Grafana / Node Exporter
- Allure 报告服务
- Nginx 统一入口

### 4.2 启动大模型服务（阶段三，需要大内存/GPU）

```bash
bash /opt/lab-deploy/deploy.sh llm
```

包含：
- Ollama（本地推理）+ 自动拉取 deepseek-coder/qwen2.5/nomic-embed-text
- Open WebUI（对话界面）
- LiteLLM（模型 API 网关）
- Milvus（向量数据库）+ Attu（管理界面）

### 4.3 一次启动全部

```bash
bash /opt/lab-deploy/deploy.sh all
```

---

## 第五步：配置客户端访问

在你本机（或公司内网 DNS）添加以下 hosts 解析：

```
192.168.1.100  git.lab.internal
192.168.1.100  ci.lab.internal
192.168.1.100  monitor.lab.internal
192.168.1.100  log.lab.internal
192.168.1.100  minio.lab.internal
192.168.1.100  allure.lab.internal
192.168.1.100  llm.lab.internal
192.168.1.100  mq.lab.internal
```

---

## 各服务访问地址

| 服务 | 地址 | 默认账号 |
|------|------|----------|
| 导航首页 | http://192.168.1.100 | - |
| GitLab | http://git.lab.internal | root / 见 .env |
| Jenkins | http://ci.lab.internal | admin / 见初始化日志 |
| Grafana | http://monitor.lab.internal | admin / 见 .env |
| Kibana | http://log.lab.internal | elastic / 见 .env |
| MinIO 控制台 | http://minio.lab.internal | 见 .env |
| Allure 报告 | http://allure.lab.internal | - |
| RabbitMQ | http://mq.lab.internal | 见 .env |
| Open WebUI | http://llm.lab.internal | 首次注册 |
| Prometheus | http://192.168.1.100:9090 | - |
| InfluxDB | http://192.168.1.100:8086 | 见 .env |
| Milvus Attu | http://192.168.1.100:8000 | - |
| LiteLLM API | http://192.168.1.100:4000/v1 | masterkey 见 .env |

---

## 常用运维命令

```bash
# 查看所有服务状态
bash deploy.sh status

# 查看某个服务日志（如 gitlab）
bash deploy.sh logs gitlab

# 停止所有服务
bash deploy.sh down

# 重启某个服务
docker compose --env-file .env restart jenkins

# 进入容器调试
docker exec -it lab-mysql mysql -u root -p

# 备份 MySQL
docker exec lab-mysql mysqldump -u root -p${MYSQL_ROOT_PASSWORD} --all-databases > backup.sql

# GPU 模式（有 NVIDIA GPU 时）
# 取消注释 docker-compose.llm.yml 中 ollama 的 deploy.resources 部分
# 并安装 nvidia-container-toolkit（详见 install_docker.sh 注释）
```

---

## 注意事项

1. **密码安全**：`.env` 文件不要上传到 GitLab，建议加入 `.gitignore`
2. **磁盘规划**：`/data` 目录建议单独挂载 SSD 分区，至少 500G
3. **GitLab 启动慢**：首次启动约需 3~5 分钟，请耐心等待
4. **大模型资源**：无 GPU 时 Ollama 仅使用 CPU，7B 模型推理较慢但可用
5. **端口冲突**：若 80/443 已被占用，修改 `.env` 中的 `NGINX_HTTP_PORT`
